import Foundation

@MainActor
final class CalibrationPreviewService {
    var onLog: ((String) -> Void)?

    private var httpProcess: Process?
    private var videoProcess: Process?
    private var audioProcess: Process?
    private var videoDelayProcess: Process?
    private var audioDelayProcess: Process?
    private var ignoredTerminationPIDs = Set<Int32>()
    private var isStopping = false

    private let port = 8081

    private var runtimeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AptvMerge/Calibration", isDirectory: true)
    }

    private var videoDirectory: URL {
        runtimeDirectory.appendingPathComponent("video", isDirectory: true)
    }

    private var audioDirectory: URL {
        runtimeDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    private var videoDelayedDirectory: URL {
        runtimeDirectory.appendingPathComponent("video-delayed", isDirectory: true)
    }

    private var audioDelayedDirectory: URL {
        runtimeDirectory.appendingPathComponent("audio-delayed", isDirectory: true)
    }

    private var audioMergeDirectory: URL {
        runtimeDirectory.appendingPathComponent("audio-merge", isDirectory: true)
    }

    private var videoDelayControlURL: URL {
        runtimeDirectory.appendingPathComponent("video-delay.txt")
    }

    private var audioDelayControlURL: URL {
        runtimeDirectory.appendingPathComponent("audio-delay.txt")
    }

    func start(video: StreamSource, audio: StreamSource) async throws -> (videoPreviewURL: String, audioPreviewURL: String, videoMergeURL: String, audioMergeURL: String) {
        await stop()
        try prepareDirectories()
        try updateDelays(videoDelay: 0, audioDelay: 0)
        isStopping = false

        try startHTTPServer()
        try startPreview(source: video, outputDirectory: videoDirectory, name: "cal-video")
        try startPreview(source: audio, outputDirectory: audioDirectory, name: "cal-audio")

        try await waitForSourcePlaylist(
            source: video,
            outputDirectory: videoDirectory,
            playlist: videoDirectory.appendingPathComponent("index.m3u8"),
            process: { self.videoProcess },
            name: "cal-video",
            readyName: "视频源原始预览"
        )
        try await waitForSourcePlaylist(
            source: audio,
            outputDirectory: audioDirectory,
            playlist: audioDirectory.appendingPathComponent("index.m3u8"),
            process: { self.audioProcess },
            name: "cal-audio",
            readyName: "音频源原始预览"
        )
        try await waitForPlaylist(audioMergeDirectory.appendingPathComponent("index.m3u8"), process: { self.audioProcess }, name: "音频合流中继")

        try startDelayedPlaylist(
            sourcePlaylist: videoDirectory.appendingPathComponent("index.m3u8"),
            outputPlaylist: videoDelayedDirectory.appendingPathComponent("index.m3u8"),
            delayControl: videoDelayControlURL,
            sourceSubdirectory: "video",
            name: "cal-video-delay"
        )
        try startDelayedPlaylist(
            sourcePlaylist: audioDirectory.appendingPathComponent("index.m3u8"),
            outputPlaylist: audioDelayedDirectory.appendingPathComponent("index.m3u8"),
            delayControl: audioDelayControlURL,
            sourceSubdirectory: "audio",
            name: "cal-audio-delay"
        )

        try await waitForPlaylist(videoDelayedDirectory.appendingPathComponent("index.m3u8"), process: { self.videoDelayProcess }, name: "视频源预览")
        try await waitForPlaylist(audioDelayedDirectory.appendingPathComponent("index.m3u8"), process: { self.audioDelayProcess }, name: "音频源预览")

        return (
            videoPreviewURL: "http://127.0.0.1:\(port)/video-delayed/index.m3u8",
            audioPreviewURL: "http://127.0.0.1:\(port)/audio-delayed/index.m3u8",
            videoMergeURL: "http://127.0.0.1:\(port)/video/index.m3u8",
            audioMergeURL: "http://127.0.0.1:\(port)/audio-merge/index.m3u8"
        )
    }

    func updateDelays(videoDelay: Double, audioDelay: Double) throws {
        try writeDelay(max(0, videoDelay), to: videoDelayControlURL)
        try writeDelay(max(0, audioDelay), to: audioDelayControlURL)
    }

    func stop() async {
        isStopping = true
        await stopProcess(videoDelayProcess, name: "cal-video-delay")
        await stopProcess(audioDelayProcess, name: "cal-audio-delay")
        await stopProcess(videoProcess, name: "cal-video")
        await stopProcess(audioProcess, name: "cal-audio")
        await stopProcess(httpProcess, name: "cal-http")
        videoProcess = nil
        audioProcess = nil
        videoDelayProcess = nil
        audioDelayProcess = nil
        httpProcess = nil
        isStopping = false
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videoDelayedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDelayedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioMergeDirectory, withIntermediateDirectories: true)
        try cleanDirectory(videoDirectory)
        try cleanDirectory(audioDirectory)
        try cleanDirectory(videoDelayedDirectory)
        try cleanDirectory(audioDelayedDirectory)
        try cleanDirectory(audioMergeDirectory)
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
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        process.currentDirectoryURL = runtimeDirectory
        attachLogging(to: process, name: "cal-http")
        attachTerminationHandler(to: process, name: "cal-http")
        try process.run()
        httpProcess = process
        log("校准预览 HTTP 服务已启动，端口 \(port)")
    }

    private func startPreview(source: StreamSource, outputDirectory: URL, name: String) throws {
        let ffmpeg = try executablePath(candidates: [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg"
        ])

        var args = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "warning",
            "-nostats"
        ]

        if !source.userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-user_agent", source.userAgent]
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
            "-i", source.url,
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "128k",
            "-f", "hls"
        ]

        if name == "cal-audio" {
            args += [
                "-hls_segment_type", "mpegts",
                "-hls_time", "2",
                "-hls_list_size", "180",
                "-hls_delete_threshold", "180",
                "-hls_flags", "delete_segments",
                "-hls_allow_cache", "0",
                "-hls_segment_filename", outputDirectory.appendingPathComponent("seg_%05d.ts").path,
                outputDirectory.appendingPathComponent("index.m3u8").path
            ]
        } else {
            args += [
                "-tag:v", "hvc1",
                "-hls_segment_type", "fmp4",
                "-hls_fmp4_init_filename", "init.mp4",
                "-hls_time", "2",
                "-hls_list_size", "180",
                "-hls_delete_threshold", "180",
                "-hls_flags", "delete_segments",
                "-hls_allow_cache", "0",
                "-hls_segment_filename", outputDirectory.appendingPathComponent("seg_%05d.m4s").path,
                outputDirectory.appendingPathComponent("index.m3u8").path
            ]
        }

        if name == "cal-audio" {
            args += [
                "-map", "0:a:0",
                "-vn",
                "-af", "aresample=async=1:first_pts=0",
                "-c:a", "aac",
                "-b:a", "128k",
                "-f", "hls",
                "-hls_time", "2",
                "-hls_list_size", "180",
                "-hls_delete_threshold", "180",
                "-hls_flags", "delete_segments",
                "-hls_allow_cache", "0",
                "-hls_segment_filename", audioMergeDirectory.appendingPathComponent("aud_%05d.ts").path,
                audioMergeDirectory.appendingPathComponent("index.m3u8").path
            ]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        attachLogging(to: process, name: name)
        attachTerminationHandler(to: process, name: name)
        try process.run()

        if name == "cal-video" {
            videoProcess = process
        } else {
            audioProcess = process
        }
    }

    private func startDelayedPlaylist(
        sourcePlaylist: URL,
        outputPlaylist: URL,
        delayControl: URL,
        sourceSubdirectory: String,
        name: String
    ) throws {
        let python = try executablePath(candidates: ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            "-u",
            "-c",
            delayedPlaylistScript,
            sourcePlaylist.path,
            outputPlaylist.path,
            delayControl.path,
            sourceSubdirectory
        ]
        attachLogging(to: process, name: name)
        attachTerminationHandler(to: process, name: name)
        try process.run()

        if name == "cal-video-delay" {
            videoDelayProcess = process
        } else {
            audioDelayProcess = process
        }
    }

    private func writeDelay(_ delay: Double, to url: URL) throws {
        let text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), delay)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func waitForPlaylist(_ playlist: URL, process: () -> Process?, name: String) async throws {
        let started = Date()
        while Date().timeIntervalSince(started) < 45 {
            if mediaSegmentCount(in: playlist) >= 1 {
                log("\(name)就绪")
                return
            }
            if process()?.isRunning != true {
                throw MergeServiceError.mergeExited
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw MergeServiceError.outputTimeout
    }

    private func waitForSourcePlaylist(
        source: StreamSource,
        outputDirectory: URL,
        playlist: URL,
        process: () -> Process?,
        name: String,
        readyName: String
    ) async throws {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let started = Date()
            while Date().timeIntervalSince(started) < 20 {
                if mediaSegmentCount(in: playlist) >= 1 {
                    log("\(readyName)就绪")
                    return
                }
                if process()?.isRunning != true {
                    break
                }
                try await Task.sleep(for: .milliseconds(500))
            }

            if mediaSegmentCount(in: playlist) >= 1 {
                log("\(readyName)就绪")
                return
            }

            guard attempt < maxAttempts else {
                throw MergeServiceError.mergeExited
            }

            log("[\(name)] 启动未拿到播放列表，正在重试 \(attempt + 1)/\(maxAttempts)")
            await stopProcess(process(), name: name)
            try cleanDirectory(outputDirectory)
            if name == "cal-audio" {
                try cleanDirectory(audioMergeDirectory)
            }
            try startPreview(source: source, outputDirectory: outputDirectory, name: name)
        }
    }

    private func mediaSegmentCount(in playlist: URL) -> Int {
        guard let text = try? String(contentsOf: playlist) else { return 0 }
        return text.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }.count
    }

    private func attachLogging(to process: Process, name: String) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard !Self.shouldSuppressLogLine(trimmed, processName: name) else { continue }
                Task { @MainActor in
                    self?.log("[\(name)] \(trimmed)")
                }
            }
        }
    }

    private nonisolated static func shouldSuppressLogLine(_ line: String, processName: String) -> Bool {
        if processName == "cal-http" {
            if line.contains("\"GET /"),
               line.contains("HTTP/1.1\" 200") {
                return true
            }

            let stoppedClientNoisePatterns = [
                "----------------------------------------",
                "Exception occurred during processing of request",
                "Traceback (most recent call last):",
                "socketserver.py",
                "http/server.py",
                "shutil.py",
                "self.finish_request",
                "self.RequestHandlerClass",
                "super().__init__",
                "self.handle()",
                "self.handle_one_request()",
                "method()",
                "self.copyfile",
                "shutil.copyfileobj",
                "fdst_write(buf)",
                "self._sock.sendall",
                "BrokenPipeError"
            ]
            if stoppedClientNoisePatterns.contains(where: { line.contains($0) }) {
                return true
            }
        }

        if processName == "cal-audio" {
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

        return [
            "Skipping invalid undecodable NALU",
            "non-existing PPS",
            "no frame!",
            "Last message repeated",
            "Stream HEVC is not hvc1",
            "mime type is not rfc8216 compliant",
            "Packet duration:",
            "is out of range"
        ].contains { line.contains($0) }
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
        log("[\(name)] 进程已退出，状态码 \(process.terminationStatus)")
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

    private func executablePath(candidates: [String]) throws -> String {
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw MergeServiceError.missingExecutable(candidates.joined(separator: ", "))
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    private var delayedPlaylistScript: String {
        #"""
        import math
        import os
        import re
        import sys
        import tempfile
        import time

        source_playlist, output_playlist, delay_file, source_subdir = sys.argv[1:5]
        window_segments = 8

        def read_delay():
            try:
                with open(delay_file, "r", encoding="utf-8") as f:
                    return max(0.0, float(f.read().strip() or "0"))
            except Exception:
                return 0.0

        def parse_playlist(text):
            lines = [line.strip() for line in text.splitlines() if line.strip()]
            target_duration = "2"
            media_sequence = 0
            map_uri = None
            segments = []
            pending = []
            duration = 2.0

            for line in lines:
                if line.startswith("#EXT-X-TARGETDURATION:"):
                    target_duration = line.split(":", 1)[1]
                elif line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
                    try:
                        media_sequence = int(line.split(":", 1)[1])
                    except ValueError:
                        media_sequence = 0
                elif line.startswith("#EXT-X-MAP:"):
                    match = re.search(r'URI="([^"]+)"', line)
                    if match:
                        map_uri = match.group(1)
                elif line.startswith("#EXTINF:"):
                    pending = [line]
                    try:
                        duration = float(line.split(":", 1)[1].split(",", 1)[0])
                    except ValueError:
                        duration = 2.0
                elif line.startswith("#"):
                    if pending:
                        pending.append(line)
                elif pending:
                    segments.append((duration, pending, line))
                    pending = []

            return target_duration, media_sequence, map_uri, segments

        def prefixed(uri):
            if "://" in uri or uri.startswith("/"):
                return uri
            return "../" + source_subdir + "/" + uri

        def render(target_duration, media_sequence, map_uri, segments, start_index):
            out = [
                "#EXTM3U",
                "#EXT-X-VERSION:7" if map_uri else "#EXT-X-VERSION:3",
                "#EXT-X-TARGETDURATION:" + str(target_duration),
                "#EXT-X-MEDIA-SEQUENCE:" + str(media_sequence + start_index)
            ]
            if map_uri:
                out.append('#EXT-X-MAP:URI="' + prefixed(map_uri) + '"')
            for _, tags, uri in segments:
                out.extend(tags)
                out.append(prefixed(uri))
            return "\n".join(out) + "\n"

        def write_atomic(text):
            directory = os.path.dirname(output_playlist)
            os.makedirs(directory, exist_ok=True)
            fd, tmp_path = tempfile.mkstemp(prefix=".index.", suffix=".m3u8", dir=directory)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp_path, output_playlist)

        while True:
            try:
                with open(source_playlist, "r", encoding="utf-8") as f:
                    text = f.read()
                target_duration, media_sequence, map_uri, segments = parse_playlist(text)
                if segments:
                    delay = read_delay()
                    available_duration = sum(item[0] for item in segments)
                    live_edge = max(0.0, available_duration - delay)
                    total = 0.0
                    end = 0
                    for index, item in enumerate(segments):
                        total += item[0]
                        if delay <= 0.001 or total <= live_edge:
                            end = index + 1
                    if end <= 0 and delay <= available_duration:
                        end = 1
                    start = max(0, end - window_segments)
                    selected = segments[start:end]
                    if selected:
                        write_atomic(render(target_duration, media_sequence, map_uri, selected, start))
            except Exception as exc:
                print(exc, flush=True)
            time.sleep(0.5)
        """#
    }
}
