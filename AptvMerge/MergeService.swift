import Foundation

@MainActor
final class MergeService {
    var onLog: ((String) -> Void)?
    var onStateChange: ((Bool, String, String, String) -> Void)?

    private var httpProcess: Process?
    private var bufferProcess: Process?
    private var audioRelayProcess: Process?
    private var readerProcess: Process?
    private var mergeProcess: Process?
    private var previewProcess: Process?
    private var healthMonitorTask: Task<Void, Never>?
    private var outputURL = ""
    private var previewOutputURL = ""
    private var currentDelaySeconds: Double = 0
    private var isStopping = false
    private var ignoredTerminationPIDs = Set<Int32>()

    private let port = 8080

    private var runtimeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AptvMerge/Runtime", isDirectory: true)
    }

    private var hlsDirectory: URL {
        runtimeDirectory.appendingPathComponent("hls", isDirectory: true)
    }

    private var bufferDirectory: URL {
        runtimeDirectory.appendingPathComponent("video-buffer", isDirectory: true)
    }

    private var audioRelayDirectory: URL {
        runtimeDirectory.appendingPathComponent("audio-relay", isDirectory: true)
    }

    private var audioRelayPlaylistURL: URL {
        audioRelayDirectory.appendingPathComponent("index.m3u8")
    }

    private var previewDirectory: URL {
        hlsDirectory.appendingPathComponent("preview", isDirectory: true)
    }

    private var delayControlURL: URL {
        runtimeDirectory.appendingPathComponent("delay.txt")
    }

    func start(video: StreamSource, audio: StreamSource, delaySeconds: Double) async throws {
        await stop(notifyState: false)
        try prepareDirectories()
        isStopping = false
        currentDelaySeconds = delaySeconds

        let ip = localIPAddress()
        outputURL = "http://\(ip):\(port)/index.m3u8"
        previewOutputURL = "http://\(ip):\(port)/preview/index.m3u8"

        do {
            try startHTTPServer()

            if delaySeconds > 0 {
                log("启动视频缓存层，视频延后 \(delaySeconds.formatted(.number.precision(.fractionLength(0...2))))s")
                try startVideoBuffer(video: video)
                try await waitForBuffer(delaySeconds: delaySeconds, label: "视频")
                log("启动音频中继，稳定解说音轨")
                try startAudioRelay(audio: audio)
                try await waitForAudioRelayPlaylist()
                try startBufferedVideoMerge(delaySeconds: delaySeconds)
            } else if delaySeconds < 0 {
                let audioDelay = -delaySeconds
                log("启动音频中继，音频延后 \(audioDelay.formatted(.number.precision(.fractionLength(0...2))))s")
                try startAudioRelay(audio: audio)
                try await waitForAudioRelayPlaylist()
                try startAudioRelayOffsetMerge(video: video, delaySeconds: audioDelay)
            } else {
                log("时差为 0，跳过缓存层")
                try startDirectMerge(video: video, audio: audio)
            }

            try await waitForOutputPlaylist()
            try startPreviewStream()
            try await waitForPreviewPlaylist()
            startHealthMonitor()
            onStateChange?(true, "运行中", outputURL, previewOutputURL)
            log("APTV 链接: \(outputURL)")
        } catch {
            await stop()
            throw error
        }
    }

    func startFromCalibration(videoURL: String, audioURL: String, delaySeconds: Double) async throws {
        await stop(notifyState: false)
        try prepareDirectories()
        isStopping = false
        currentDelaySeconds = delaySeconds

        let ip = localIPAddress()
        outputURL = "http://\(ip):\(port)/index.m3u8"
        previewOutputURL = "http://\(ip):\(port)/preview/index.m3u8"

        do {
            try startHTTPServer()
            log("复用校准预览流启动合流，\(formatDelayDescription(delaySeconds))")
            try startCalibrationMerge(videoURL: videoURL, audioURL: audioURL)
            try await waitForOutputPlaylist()
            try startPreviewStream()
            try await waitForPreviewPlaylist()
            startHealthMonitor()
            onStateChange?(true, "运行中", outputURL, previewOutputURL)
            log("APTV 链接: \(outputURL)")
        } catch {
            await stop()
            throw error
        }
    }

    func updateDelay(video: StreamSource, audio: StreamSource, delaySeconds: Double) async throws {
        guard isRunning else {
            try await start(video: video, audio: audio, delaySeconds: delaySeconds)
            return
        }

        if delaySeconds > 0,
           currentDelaySeconds > 0,
           bufferProcess?.isRunning == true,
           audioRelayProcess?.isRunning == true,
           httpProcess?.isRunning == true {
            if bufferedSeconds() < delaySeconds {
                log("等待缓存达到新时差 \(delaySeconds.formatted(.number.precision(.fractionLength(0...2))))s")
                try await waitForBuffer(delaySeconds: delaySeconds, label: "视频")
            }
            log("视频延后模式内切换，正在重启合流进程应用新时差")
            try await restartBufferedVideoMerge(delaySeconds: delaySeconds)
            currentDelaySeconds = delaySeconds
            return
        }

        if delaySeconds < 0,
           currentDelaySeconds < 0,
           httpProcess?.isRunning == true,
           audioRelayProcess?.isRunning == true {
            log("音频延后模式内切换，正在重启合流进程应用新时差")
            try await restartAudioRelayOffsetMerge(video: video, delaySeconds: -delaySeconds)
            currentDelaySeconds = delaySeconds
            return
        }

        log("当前模式需要重启合流进程来应用新时差")
        try await start(video: video, audio: audio, delaySeconds: delaySeconds)
    }

    func stop(notifyState: Bool = true) async {
        isStopping = true
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        await stopProcess(previewProcess, name: "preview")
        await stopProcess(readerProcess, name: "reader")
        await stopProcess(mergeProcess, name: "merge")
        await stopProcess(audioRelayProcess, name: "audio")
        await stopProcess(bufferProcess, name: "buffer")
        await stopProcess(httpProcess, name: "http")
        mergeProcess = nil
        previewProcess = nil
        readerProcess = nil
        audioRelayProcess = nil
        bufferProcess = nil
        httpProcess = nil
        if notifyState {
            onStateChange?(false, "已停止", "", "")
        }
        isStopping = false
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: hlsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bufferDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioRelayDirectory, withIntermediateDirectories: true)
        try cleanDirectory(hlsDirectory)
        try cleanDirectory(bufferDirectory)
        try cleanDirectory(audioRelayDirectory)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
    }

    private func cleanDirectory(_ url: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        for item in contents {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func startHTTPServer() throws {
        let python = try executablePath(candidates: ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "0.0.0.0"]
        process.currentDirectoryURL = hlsDirectory
        attachTerminationHandler(to: process, name: "http")
        try process.run()
        httpProcess = process
        log("HTTP 服务已启动，端口 \(port)")
    }

    private func startVideoBuffer(video: StreamSource) throws {
        let ffmpeg = try ffmpegPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "12000000",
            "-thread_queue_size", "2048",
            "-i", video.url,
            "-map", "0:v:0",
            "-an",
            "-c:v", "copy",
            "-f", "hls",
            "-hls_time", "1",
            "-hls_list_size", "360",
            "-hls_delete_threshold", "360",
            "-hls_flags", "delete_segments",
            "-hls_allow_cache", "0",
            "-hls_segment_filename", bufferDirectory.appendingPathComponent("vid_%05d.ts").path,
            bufferDirectory.appendingPathComponent("index.m3u8").path
        ]
        attachLogging(to: process, name: "buffer")
        attachTerminationHandler(to: process, name: "buffer")
        try process.run()
        bufferProcess = process
    }

    private func startAudioBuffer(audio: StreamSource) throws {
        let ffmpeg = try ffmpegPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = audioBufferArguments(audio: audio)
        attachLogging(to: process, name: "buffer")
        attachTerminationHandler(to: process, name: "buffer")
        try process.run()
        bufferProcess = process
    }

    private func startAudioRelay(audio: StreamSource) throws {
        let ffmpeg = try ffmpegPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = audioRelayArguments(audio: audio)
        attachLogging(to: process, name: "audio")
        attachTerminationHandler(to: process, name: "audio")
        try process.run()
        audioRelayProcess = process
    }

    private func startDirectMerge(video: StreamSource, audio: StreamSource) throws {
        let ffmpeg = try ffmpegPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = directMergeArguments(video: video, audio: audio)
        attachLogging(to: process, name: "merge")
        attachTerminationHandler(to: process, name: "merge")
        try process.run()
        mergeProcess = process
    }

    private func startAudioOffsetMerge(video: StreamSource, audio: StreamSource, delaySeconds: Double) throws {
        let ffmpeg = try ffmpegPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = audioOffsetMergeArguments(video: video, audio: audio, delaySeconds: delaySeconds)
        attachLogging(to: process, name: "merge")
        attachTerminationHandler(to: process, name: "merge")
        try process.run()
        mergeProcess = process
    }

    private func startAudioRelayOffsetMerge(video: StreamSource, delaySeconds: Double) throws {
        let ffmpeg = try ffmpegPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = audioRelayOffsetMergeArguments(video: video, delaySeconds: delaySeconds)
        attachLogging(to: process, name: "merge")
        attachTerminationHandler(to: process, name: "merge")
        try process.run()
        mergeProcess = process
    }

    private func startCalibrationMerge(videoURL: String, audioURL: String) throws {
        let ffmpeg = try ffmpegPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = calibrationMergeArguments(videoURL: videoURL, audioURL: audioURL)
        attachLogging(to: process, name: "merge")
        attachTerminationHandler(to: process, name: "merge")
        try process.run()
        mergeProcess = process
    }

    private func restartAudioRelayOffsetMerge(video: StreamSource, delaySeconds: Double) async throws {
        isStopping = true
        await stopProcess(previewProcess, name: "preview")
        await stopProcess(mergeProcess, name: "merge")
        previewProcess = nil
        mergeProcess = nil
        isStopping = false

        try cleanDirectory(hlsDirectory)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        try startAudioRelayOffsetMerge(video: video, delaySeconds: delaySeconds)
        try await waitForOutputPlaylist()
        try startPreviewStream()
        try await waitForPreviewPlaylist()
        startHealthMonitor()
        onStateChange?(true, "运行中", outputURL, previewOutputURL)
        log("已应用音频延后: \(delaySeconds.formatted(.number.precision(.fractionLength(0...2))))s")
    }

    private func startBufferedVideoMerge(delaySeconds: Double) throws {
        let python = try executablePath(candidates: ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"])
        let ffmpeg = try ffmpegPath()
        let pipe = Pipe()
        try writeDelayControl(delaySeconds)

        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: python)
        reader.arguments = ["-c", delayedReaderScript, bufferDirectory.path, delayControlURL.path, "\(delaySeconds)", "vid"]
        reader.standardOutput = pipe
        attachLogging(to: reader, name: "reader", captureStandardOutput: false)
        attachTerminationHandler(to: reader, name: "reader")

        let merge = Process()
        merge.executableURL = URL(fileURLWithPath: ffmpeg)
        merge.arguments = bufferedVideoMergeArguments(audioPlaylist: audioRelayPlaylistURL)
        merge.standardInput = pipe
        attachLogging(to: merge, name: "merge")
        attachTerminationHandler(to: merge, name: "merge")

        try reader.run()
        try merge.run()
        readerProcess = reader
        mergeProcess = merge
    }

    private func restartBufferedVideoMerge(delaySeconds: Double) async throws {
        isStopping = true
        await stopProcess(previewProcess, name: "preview")
        await stopProcess(readerProcess, name: "reader")
        await stopProcess(mergeProcess, name: "merge")
        previewProcess = nil
        mergeProcess = nil
        readerProcess = nil
        isStopping = false

        try cleanDirectory(hlsDirectory)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        try startBufferedVideoMerge(delaySeconds: delaySeconds)
        try await waitForOutputPlaylist()
        try startPreviewStream()
        try await waitForPreviewPlaylist()
        startHealthMonitor()
        onStateChange?(true, "运行中", outputURL, previewOutputURL)
        log("已应用视频延后: \(delaySeconds.formatted(.number.precision(.fractionLength(0...2))))s")
    }

    private func startBufferedAudioMerge(video: StreamSource, delaySeconds: Double) throws {
        let python = try executablePath(candidates: ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"])
        let ffmpeg = try ffmpegPath()
        let pipe = Pipe()
        try writeDelayControl(delaySeconds)

        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: python)
        reader.arguments = ["-c", delayedReaderScript, bufferDirectory.path, delayControlURL.path, "\(delaySeconds)", "aud"]
        reader.standardOutput = pipe
        attachLogging(to: reader, name: "reader", captureStandardOutput: false)
        attachTerminationHandler(to: reader, name: "reader")

        let merge = Process()
        merge.executableURL = URL(fileURLWithPath: ffmpeg)
        merge.arguments = bufferedAudioMergeArguments(video: video)
        merge.standardInput = pipe
        attachLogging(to: merge, name: "merge")
        attachTerminationHandler(to: merge, name: "merge")

        try reader.run()
        try merge.run()
        readerProcess = reader
        mergeProcess = merge
    }

    private func directMergeArguments(video: StreamSource, audio: StreamSource) -> [String] {
        var args = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats",
            "-fflags", "+genpts",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "12000000",
            "-thread_queue_size", "2048",
            "-i", video.url
        ]

        if !audio.userAgent.isEmpty {
            args += ["-user_agent", audio.userAgent]
        }

        args += [
            "-fflags", "+genpts",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "12000000",
            "-thread_queue_size", "2048",
            "-i", audio.url,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "128k"
        ]
        args += hlsOutputArguments()
        return args
    }

    private func calibrationMergeArguments(videoURL: String, audioURL: String) -> [String] {
        var args = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats",
            "-fflags", "+genpts"
        ]

        args += [
            "-protocol_whitelist", "file,http,https,tcp,tls,crypto",
            "-allowed_extensions", "ALL",
            "-thread_queue_size", "4096",
            "-live_start_index", "0",
            "-i", videoURL,
            "-fflags", "+genpts"
        ]

        args += [
            "-protocol_whitelist", "file,http,https,tcp,tls,crypto",
            "-allowed_extensions", "ALL",
            "-thread_queue_size", "4096",
            "-live_start_index", "0",
            "-i", audioURL,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "copy",
            "-tag:v", "hvc1",
            "-filter:a", "aresample=async=1:first_pts=0",
            "-c:a", "aac",
            "-b:a", "128k"
        ]
        args += hlsOutputArguments()
        return args
    }

    private func audioOffsetMergeArguments(video: StreamSource, audio: StreamSource, delaySeconds: Double) -> [String] {
        let delayMilliseconds = max(0, Int((delaySeconds * 1000).rounded()))
        var args = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats",
            "-fflags", "+genpts",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "12000000",
            "-thread_queue_size", "2048",
            "-i", video.url
        ]

        if !audio.userAgent.isEmpty {
            args += ["-user_agent", audio.userAgent]
        }

        args += [
            "-fflags", "+genpts",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "12000000",
            "-thread_queue_size", "2048",
            "-i", audio.url,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "copy",
            "-filter:a", "adelay=\(delayMilliseconds):all=1",
            "-c:a", "aac",
            "-b:a", "128k"
        ]
        args += hlsOutputArguments()
        return args
    }

    private func audioRelayOffsetMergeArguments(video: StreamSource, delaySeconds: Double) -> [String] {
        let delayMilliseconds = max(0, Int((delaySeconds * 1000).rounded()))
        var args = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats",
            "-fflags", "+genpts",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "12000000",
            "-thread_queue_size", "2048",
            "-i", video.url
        ]

        args += [
            "-protocol_whitelist", "file,http,https,tcp,tls,crypto",
            "-allowed_extensions", "ALL",
            "-thread_queue_size", "2048",
            "-i", audioRelayPlaylistURL.path,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "copy",
            "-filter:a", "adelay=\(delayMilliseconds):all=1,aresample=async=1:first_pts=0",
            "-c:a", "aac",
            "-b:a", "128k"
        ]
        args += hlsOutputArguments()
        return args
    }

    private func audioBufferArguments(audio: StreamSource) -> [String] {
        var args = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats"
        ]

        if !audio.userAgent.isEmpty {
            args += ["-user_agent", audio.userAgent]
        }

        args += [
            "-fflags", "+genpts",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "12000000",
            "-thread_queue_size", "2048",
            "-i", audio.url,
            "-map", "0:a:0",
            "-vn",
            "-c:a", "aac",
            "-b:a", "128k",
            "-f", "hls",
            "-hls_time", "1",
            "-hls_list_size", "360",
            "-hls_delete_threshold", "360",
            "-hls_flags", "delete_segments",
            "-hls_allow_cache", "0",
            "-hls_segment_filename", bufferDirectory.appendingPathComponent("aud_%05d.ts").path,
            bufferDirectory.appendingPathComponent("index.m3u8").path
        ]
        return args
    }

    private func audioRelayArguments(audio: StreamSource) -> [String] {
        var args = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats"
        ]

        if !audio.userAgent.isEmpty {
            args += ["-user_agent", audio.userAgent]
        }

        args += [
            "-fflags", "+discardcorrupt+genpts",
            "-err_detect", "ignore_err",
            "-reconnect", "1",
            "-reconnect_at_eof", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "12000000",
            "-thread_queue_size", "2048",
            "-i", audio.url,
            "-map", "0:a:0",
            "-vn",
            "-af", "aresample=async=1:first_pts=0",
            "-c:a", "aac",
            "-b:a", "128k",
            "-f", "hls",
            "-hls_time", "1",
            "-hls_list_size", "40",
            "-hls_delete_threshold", "40",
            "-hls_flags", "delete_segments",
            "-hls_allow_cache", "0",
            "-hls_segment_filename", audioRelayDirectory.appendingPathComponent("aud_%05d.ts").path,
            audioRelayPlaylistURL.path
        ]
        return args
    }

    private func bufferedVideoMergeArguments(audioPlaylist: URL) -> [String] {
        var args = [
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats",
            "-fflags", "+genpts",
            "-thread_queue_size", "4096",
            "-re",
            "-f", "mpegts",
            "-i", "pipe:0"
        ]

        args += [
            "-protocol_whitelist", "file,http,https,tcp,tls,crypto",
            "-allowed_extensions", "ALL",
            "-fflags", "+genpts",
            "-thread_queue_size", "4096",
            "-i", audioPlaylist.path,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "copy",
            "-filter:a", "aresample=async=1:first_pts=0",
            "-c:a", "aac",
            "-b:a", "128k"
        ]
        args += hlsOutputArguments()
        return args
    }

    private func bufferedAudioMergeArguments(video: StreamSource) -> [String] {
        [
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats",
            "-fflags", "+genpts",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "12000000",
            "-thread_queue_size", "2048",
            "-i", video.url,
            "-fflags", "+genpts",
            "-re",
            "-f", "mpegts",
            "-i", "pipe:0",
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "128k"
        ] + hlsOutputArguments()
    }

    private func hlsOutputArguments() -> [String] {
        [
            "-f", "hls",
            "-hls_time", "2",
            "-hls_list_size", "24",
            "-hls_delete_threshold", "24",
            "-hls_flags", "delete_segments",
            "-hls_allow_cache", "0",
            "-hls_segment_filename", hlsDirectory.appendingPathComponent("seg_%05d.ts").path,
            hlsDirectory.appendingPathComponent("index.m3u8").path
        ]
    }

    private func startPreviewStream() throws {
        let ffmpeg = try ffmpegPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats",
            "-fflags", "+genpts",
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "5",
            "-rw_timeout", "12000000",
            "-live_start_index", "-2",
            "-i", "http://127.0.0.1:\(port)/index.m3u8",
            "-map", "0:v:0",
            "-map", "0:a:0",
            "-c", "copy",
            "-tag:v", "hvc1",
            "-bsf:a", "aac_adtstoasc",
            "-f", "hls",
            "-hls_segment_type", "fmp4",
            "-hls_fmp4_init_filename", "init.mp4",
            "-hls_time", "2",
            "-hls_list_size", "12",
            "-hls_delete_threshold", "12",
            "-hls_flags", "delete_segments",
            "-hls_allow_cache", "0",
            "-hls_segment_filename", previewDirectory.appendingPathComponent("prev_%05d.m4s").path,
            previewDirectory.appendingPathComponent("index.m3u8").path
        ]
        attachLogging(to: process, name: "preview")
        attachTerminationHandler(to: process, name: "preview")
        try process.run()
        previewProcess = process
    }

    private func waitForOutputPlaylist() async throws {
        let playlist = hlsDirectory.appendingPathComponent("index.m3u8")
        try await waitForPlaylist(playlist, process: { self.mergeProcess }, timeout: 90, minimumSegments: 2, readyLog: "HLS 输出就绪")
    }

    private func waitForPreviewPlaylist() async throws {
        let playlist = previewDirectory.appendingPathComponent("index.m3u8")
        try await waitForPlaylist(playlist, process: { self.previewProcess }, timeout: 45, minimumSegments: 1, readyLog: "内置播放流就绪")
    }

    private func waitForAudioRelayPlaylist() async throws {
        try await waitForPlaylist(audioRelayPlaylistURL, process: { self.audioRelayProcess }, timeout: 30, minimumSegments: 2, readyLog: "音频中继就绪")
    }

    private func waitForPlaylist(
        _ playlist: URL,
        process: () -> Process?,
        timeout: TimeInterval,
        minimumSegments: Int = 1,
        readyLog: String
    ) async throws {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if mediaSegmentCount(in: playlist) >= minimumSegments {
                log(readyLog)
                return
            }
            if process()?.isRunning != true {
                throw MergeServiceError.mergeExited
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw MergeServiceError.outputTimeout
    }

    private func mediaSegmentCount(in playlist: URL) -> Int {
        guard let text = try? String(contentsOf: playlist) else { return 0 }
        let baseURL = playlist.deletingLastPathComponent()
        return text.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { return false }
            guard !trimmed.contains("://") else { return true }
            return localMediaSegmentExists(String(trimmed), relativeTo: baseURL)
        }.count
    }

    private func localMediaSegmentExists(_ path: String, relativeTo baseURL: URL) -> Bool {
        let segmentURL = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
        guard FileManager.default.fileExists(atPath: segmentURL.path) else { return false }
        guard let values = try? segmentURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize
        else {
            return false
        }
        return fileSize > 0
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) throws {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if FileManager.default.fileExists(atPath: url.path),
               ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0) > 0 {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw MergeServiceError.outputTimeout
    }

    private func waitForBuffer(delaySeconds: Double, label: String) async throws {
        let started = Date()
        var lastPrinted = Date.distantPast
        while Date().timeIntervalSince(started) < max(180, delaySeconds + 120) {
            let current = bufferedSeconds()
            if current >= delaySeconds {
                log("\(label)缓存就绪: \(current.formatted(.number.precision(.fractionLength(1))))s")
                return
            }
            if Date().timeIntervalSince(lastPrinted) > 5 {
                log("缓存中 \(current.formatted(.number.precision(.fractionLength(1))))s / \(delaySeconds.formatted(.number.precision(.fractionLength(1))))s")
                lastPrinted = Date()
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw MergeServiceError.bufferTimeout
    }

    private func bufferedSeconds() -> Double {
        let playlist = bufferDirectory.appendingPathComponent("index.m3u8")
        guard let text = try? String(contentsOf: playlist) else { return 0 }
        return text.split(separator: "\n").reduce(0) { total, line in
            guard line.hasPrefix("#EXTINF:"),
                  let value = line.split(separator: ":").last?.split(separator: ",").first,
                  let seconds = Double(value)
            else {
                return total
            }
            return total + seconds
        }
    }

    private var isRunning: Bool {
        httpProcess?.isRunning == true && mergeProcess?.isRunning == true
    }

    private func writeDelayControl(_ delaySeconds: Double) throws {
        try "\(delaySeconds)\n".write(to: delayControlURL, atomically: true, encoding: .utf8)
    }

    private func attachLogging(to process: Process, name: String, captureStandardOutput: Bool = true) {
        let pipe = Pipe()
        if captureStandardOutput {
            process.standardOutput = pipe
        }
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard !Self.shouldSuppressFFmpegLogLine(trimmed, processName: name) else { continue }
                Task { @MainActor in
                    self?.log("[\(name)] \(trimmed)")
                }
            }
        }
    }

    private nonisolated static func shouldSuppressFFmpegLogLine(_ line: String, processName: String) -> Bool {
        let suppressedPatterns = [
            "Skipping invalid undecodable NALU",
            "non-existing PPS",
            "no frame!",
            "Last message repeated",
            "Stream HEVC is not hvc1",
            "mime type is not rfc8216 compliant",
            "Found duplicated MOOV Atom. Skipped it"
        ]
        if suppressedPatterns.contains(where: { line.contains($0) }) {
            return true
        }

        if processName == "audio" {
            let audioRelayNoisePatterns = [
                "Stream ends prematurely",
                "Will reconnect",
                "PES packet size mismatch",
                "Packet corrupt"
            ]
            if audioRelayNoisePatterns.contains(where: { line.contains($0) }) {
                return true
            }
        }

        if processName == "reader" {
            let readerStopNoisePatterns = [
                "Traceback (most recent call last):",
                "File \"<string>\"",
                "BrokenPipeError",
                "Broken pipe"
            ]
            if readerStopNoisePatterns.contains(where: { line.contains($0) }) {
                return true
            }
        }

        return false
    }

    private func attachTerminationHandler(to process: Process, name: String) {
        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor in
                self?.handleProcessTermination(finishedProcess, name: name)
            }
        }
    }

    private func handleProcessTermination(_ process: Process, name: String) {
        if ignoredTerminationPIDs.remove(process.processIdentifier) != nil {
            return
        }
        guard !isStopping else { return }
        let status = process.terminationStatus
        log("[\(name)] 进程已退出，状态码 \(status)")

        if process == mergeProcess || process == httpProcess {
            healthMonitorTask?.cancel()
            healthMonitorTask = nil
            mergeProcess = process == mergeProcess ? nil : mergeProcess
            httpProcess = process == httpProcess ? nil : httpProcess
            onStateChange?(false, "已停止", "", "")
        }
    }

    private func startHealthMonitor() {
        healthMonitorTask?.cancel()
        let playlist = hlsDirectory.appendingPathComponent("index.m3u8")
        healthMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastSequence = self.mediaSequence(in: playlist)
            var lastAdvanceDate = Date()
            self.log("HLS 健康监控已启动")

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }

                let currentSequence = self.mediaSequence(in: playlist)
                if currentSequence != nil, currentSequence != lastSequence {
                    lastSequence = currentSequence
                    lastAdvanceDate = Date()
                    continue
                }

                let stalledSeconds = Date().timeIntervalSince(lastAdvanceDate)
                if stalledSeconds >= 15 {
                    let count = self.mediaSegmentCount(in: playlist)
                    self.log("HLS 输出可能停滞: \(Int(stalledSeconds))s 未看到新分片，当前完整分片数 \(count)")
                    lastAdvanceDate = Date()
                }
            }
        }
    }

    private func mediaSequence(in playlist: URL) -> Int? {
        guard let text = try? String(contentsOf: playlist) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") else { continue }
            guard let value = trimmed.split(separator: ":").last else { return nil }
            return Int(value)
        }
        return nil
    }

    private func stopProcess(_ process: Process?, name: String) async {
        guard let process else { return }
        guard process.isRunning else {
            log("[\(name)] 进程已退出，状态码 \(process.terminationStatus)")
            return
        }

        ignoredTerminationPIDs.insert(process.processIdentifier)
        log("[\(name)] 正在停止进程")
        process.terminate()

        let terminateDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < terminateDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        if process.isRunning {
            process.interrupt()
            let interruptDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < interruptDeadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        if process.isRunning {
            log("[\(name)] 进程停止超时，可能仍在运行")
        } else {
            log("[\(name)] 进程已退出，状态码 \(process.terminationStatus)")
        }
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    private func formatDelayDescription(_ delay: Double) -> String {
        let formatted = delay.formatted(.number.precision(.fractionLength(0...2)))
        if delay == 0 {
            return "不设置时差"
        } else if delay > 0 {
            return "视频延后 \(formatted)s"
        } else {
            return "音频延后 \(formatted.dropFirst())s"
        }
    }

    private func ffmpegPath() throws -> String {
        try executablePath(candidates: [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg"
        ])
    }

    private func executablePath(candidates: [String]) throws -> String {
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw MergeServiceError.missingExecutable(candidates.joined(separator: ", "))
    }

    private func localIPAddress() -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo 127.0.0.1"]
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : "127.0.0.1"
    }
}

enum MergeServiceError: LocalizedError {
    case missingExecutable(String)
    case bufferTimeout
    case outputTimeout
    case mergeExited

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let paths):
            return "找不到可执行文件: \(paths)"
        case .bufferTimeout:
            return "视频缓存等待超时"
        case .outputTimeout:
            return "等待 HLS 输出超时，请检查源是否可用"
        case .mergeExited:
            return "合流进程提前退出，请查看日志"
        }
    }
}

private let delayedReaderScript = #"""
import glob
import os
import re
import sys
import time

def parse_playlist(buffer_dir, prefix):
    path = os.path.join(buffer_dir, "index.m3u8")
    try:
        lines = [line.strip() for line in open(path, "r", encoding="utf-8")]
    except FileNotFoundError:
        return []
    result = []
    duration = None
    for line in lines:
        if line.startswith("#EXTINF:"):
            duration = float(line.split(":", 1)[1].split(",", 1)[0])
        elif line and not line.startswith("#") and duration is not None:
            match = re.search(rf"{re.escape(prefix)}_(\d+)\.ts", line)
            if match:
                result.append((int(match.group(1)), duration))
            duration = None
    return result

def choose(buffer_dir, prefix, delay):
    segments = parse_playlist(buffer_dir, prefix)
    total = 0.0
    for number, duration in reversed(segments):
        total += duration
        if total >= delay:
            return number, total
    return None, total

def delay_from_segment(buffer_dir, prefix, current):
    total = 0.0
    for number, duration in parse_playlist(buffer_dir, prefix):
        if number >= current:
            total += duration
    return total

def read_delay(path, fallback):
    try:
        value = float(open(path, "r", encoding="utf-8").read().strip())
        return max(0.1, value)
    except Exception:
        return fallback

def align_segment(buffer_dir, prefix, current, delay):
    while True:
        available = delay_from_segment(buffer_dir, prefix, current)
        if available + 0.1 < delay:
            time.sleep(0.2)
            continue
        if available > delay + 4:
            chosen, total = choose(buffer_dir, prefix, delay)
            if chosen is not None and chosen > current:
                return chosen
        return current

def wait_closed(buffer_dir, prefix, number):
    path = os.path.join(buffer_dir, f"{prefix}_{number:05d}.ts")
    next_path = os.path.join(buffer_dir, f"{prefix}_{number + 1:05d}.ts")
    while not (os.path.exists(path) and os.path.exists(next_path)):
        time.sleep(0.2)
    return path

buffer_dir = sys.argv[1]
delay_path = sys.argv[2]
delay = float(sys.argv[3])
prefix = sys.argv[4]
current, total = choose(buffer_dir, prefix, delay)
while current is None:
    time.sleep(0.5)
    delay = read_delay(delay_path, delay)
    current, total = choose(buffer_dir, prefix, delay)

print(f"Starting delayed stream at {prefix}_{current:05d}.ts, delay {total:.3f}s", file=sys.stderr, flush=True)
out = sys.stdout.buffer
while True:
    delay = read_delay(delay_path, delay)
    current = align_segment(buffer_dir, prefix, current, delay)
    path = wait_closed(buffer_dir, prefix, current)
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
            out.flush()
    current += 1
"""#
