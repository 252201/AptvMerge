import Foundation

@MainActor
final class CalibrationPreviewService {
    var onLog: ((String) -> Void)?

    private var httpProcess: Process?
    private var videoProcess: Process?
    private var audioProcess: Process?
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

    func start(video: StreamSource, audio: StreamSource) async throws -> (videoURL: String, audioURL: String) {
        await stop()
        try prepareDirectories()
        isStopping = false

        try startHTTPServer()
        try startPreview(source: video, outputDirectory: videoDirectory, name: "cal-video")
        try startPreview(source: audio, outputDirectory: audioDirectory, name: "cal-audio")

        try await waitForPlaylist(videoDirectory.appendingPathComponent("index.m3u8"), process: { self.videoProcess }, name: "视频源预览")
        try await waitForPlaylist(audioDirectory.appendingPathComponent("index.m3u8"), process: { self.audioProcess }, name: "音频源预览")

        return (
            videoURL: "http://127.0.0.1:\(port)/video/index.m3u8",
            audioURL: "http://127.0.0.1:\(port)/audio/index.m3u8"
        )
    }

    func stop() async {
        isStopping = true
        await stopProcess(videoProcess, name: "cal-video")
        await stopProcess(audioProcess, name: "cal-audio")
        await stopProcess(httpProcess, name: "cal-http")
        videoProcess = nil
        audioProcess = nil
        httpProcess = nil
        isStopping = false
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try cleanDirectory(videoDirectory)
        try cleanDirectory(audioDirectory)
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
            "-tag:v", "hvc1",
            "-c:a", "aac",
            "-b:a", "128k",
            "-f", "hls",
            "-hls_segment_type", "fmp4",
            "-hls_fmp4_init_filename", "init.mp4",
            "-hls_time", "2",
            "-hls_list_size", "20",
            "-hls_delete_threshold", "20",
            "-hls_flags", "delete_segments",
            "-hls_allow_cache", "0",
            "-hls_segment_filename", outputDirectory.appendingPathComponent("seg_%05d.m4s").path,
            outputDirectory.appendingPathComponent("index.m3u8").path
        ]

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
        if processName == "cal-http",
           line.contains("\"GET /"),
           line.contains("HTTP/1.1\" 200") {
            return true
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
        guard process.isRunning else { return }
        ignoredTerminationPIDs.insert(process.processIdentifier)
        log("[\(name)] 正在停止进程")
        process.terminate()

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            process.interrupt()
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
}
