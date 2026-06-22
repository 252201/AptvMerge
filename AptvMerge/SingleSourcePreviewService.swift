import Foundation

@MainActor
final class SingleSourcePreviewService {
    var onLog: ((String) -> Void)?

    private var httpProcess: Process?
    private var previewProcess: Process?
    private var ignoredTerminationPIDs = Set<Int32>()
    private var isStopping = false

    private let port = 8082

    private var runtimeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AptvMerge/SinglePreview", isDirectory: true)
    }

    private var streamDirectory: URL {
        runtimeDirectory.appendingPathComponent("stream", isDirectory: true)
    }

    private var playlistURL: URL {
        streamDirectory.appendingPathComponent("index.m3u8")
    }

    func start(source: StreamSource) async throws -> String {
        await stop()
        try prepareDirectories()
        isStopping = false

        try startHTTPServer()
        try startPreview(source: source)
        try await waitForPlaylist()

        log("单独播放流就绪")
        return "http://127.0.0.1:\(port)/stream/index.m3u8"
    }

    func stop() async {
        isStopping = true
        await stopProcess(previewProcess, name: "single-preview")
        await stopProcess(httpProcess, name: "single-http")
        previewProcess = nil
        httpProcess = nil
        isStopping = false
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: streamDirectory, withIntermediateDirectories: true)
        try cleanDirectory(streamDirectory)
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
        attachLogging(to: process, name: "single-http")
        attachTerminationHandler(to: process, name: "single-http")
        try process.run()
        httpProcess = process
        log("单独播放 HTTP 服务已启动，端口 \(port)")
    }

    private func startPreview(source: StreamSource) throws {
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
            "-map", "0:v:0?",
            "-map", "0:a:0?",
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "128k",
            "-f", "hls"
        ]

        if source.kind == .audio {
            args += [
                "-hls_segment_type", "mpegts",
                "-hls_time", "2",
                "-hls_list_size", "20",
                "-hls_delete_threshold", "20",
                "-hls_flags", "delete_segments",
                "-hls_allow_cache", "0",
                "-hls_segment_filename", streamDirectory.appendingPathComponent("seg_%05d.ts").path,
                playlistURL.path
            ]
        } else {
            args += [
                "-tag:v", "hvc1",
                "-hls_segment_type", "fmp4",
                "-hls_fmp4_init_filename", "init.mp4",
                "-hls_time", "2",
                "-hls_list_size", "20",
                "-hls_delete_threshold", "20",
                "-hls_flags", "delete_segments",
                "-hls_allow_cache", "0",
                "-hls_segment_filename", streamDirectory.appendingPathComponent("seg_%05d.m4s").path,
                playlistURL.path
            ]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        attachLogging(to: process, name: "single-preview")
        attachTerminationHandler(to: process, name: "single-preview")
        try process.run()
        previewProcess = process
    }

    private func waitForPlaylist() async throws {
        let started = Date()
        while Date().timeIntervalSince(started) < 45 {
            if mediaSegmentCount(in: playlistURL) >= 1 {
                return
            }
            if previewProcess?.isRunning != true {
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
        if processName == "single-http" {
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
                "BrokenPipeError"
            ]
            if stoppedClientNoisePatterns.contains(where: { line.contains($0) }) {
                return true
            }
        }

        let suppressedPatterns = [
            "Skipping invalid undecodable NALU",
            "non-existing PPS",
            "no frame!",
            "Last message repeated",
            "Stream HEVC is not hvc1",
            "mime type is not rfc8216 compliant",
            "Packet duration:",
            "is out of range",
            "Found duplicated MOOV Atom. Skipped it",
            "frame size not set",
            "Stream ends prematurely",
            "Will reconnect",
            "PES packet size mismatch",
            "Packet corrupt"
        ]
        return suppressedPatterns.contains { line.contains($0) }
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
}
