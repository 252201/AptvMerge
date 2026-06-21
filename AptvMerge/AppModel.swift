import AppKit
import Combine
import Foundation

enum AppRunPhase {
    case stopped
    case calibrating
    case merging
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [StreamSource]
    @Published var selectedVideoID: UUID?
    @Published var selectedAudioID: UUID?
    @Published var delaySeconds: Double
    @Published var videoPreviewDelaySeconds: Double
    @Published var audioPreviewDelaySeconds: Double
    @Published var videoCalibrationPreviewURL = ""
    @Published var audioCalibrationPreviewURL = ""
    private var videoCalibrationMergeURL = ""
    private var audioCalibrationMergeURL = ""
    @Published var phase: AppRunPhase = .stopped
    @Published var isStarting = false
    @Published var isRunning = false
    @Published var statusText = "已停止"
    @Published var outputURL = ""
    @Published var previewURL = ""
    @Published var isOutputURLVisible = false
    @Published var logs: [String] = []

    private let store = SourceStore()
    private let service = MergeService()
    private let calibrationPreviewService = CalibrationPreviewService()
    private var currentLogFileURL: URL?

    private var logsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AptvMerge/logs", isDirectory: true)
    }

    private var currentLogURL: URL {
        logsDirectory.appendingPathComponent("current.log")
    }

    init() {
        let loadedSources = store.loadSources()
        sources = loadedSources
        selectedVideoID = store.loadSelectedID(key: "selectedVideoID") ?? loadedSources.first(where: { $0.kind == .video })?.id
        selectedAudioID = store.loadSelectedID(key: "selectedAudioID") ?? loadedSources.first(where: { $0.kind == .audio })?.id
        let initialDelaySeconds = UserDefaults.standard.object(forKey: "delaySeconds") as? Double ?? 0
        delaySeconds = initialDelaySeconds
        videoPreviewDelaySeconds = 0
        audioPreviewDelaySeconds = 0
        isOutputURLVisible = UserDefaults.standard.object(forKey: "isOutputURLVisible") as? Bool ?? false

        service.onLog = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }
        calibrationPreviewService.onLog = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }
        service.onStateChange = { [weak self] running, status, url, previewURL in
            Task { @MainActor in
                guard let self else { return }
                self.isStarting = false
                self.isRunning = running
                self.phase = running ? .merging : .stopped
                self.statusText = status
                self.outputURL = url
                self.previewURL = previewURL
                if !running {
                    await self.calibrationPreviewService.stop()
                    self.videoCalibrationPreviewURL = ""
                    self.audioCalibrationPreviewURL = ""
                    self.videoCalibrationMergeURL = ""
                    self.audioCalibrationMergeURL = ""
                }
            }
        }
    }

    var videoSources: [StreamSource] {
        sources.filter { $0.kind == .video }
    }

    var audioSources: [StreamSource] {
        sources.filter { $0.kind == .audio }
    }

    var selectedVideoSource: StreamSource? {
        sources.first { $0.id == selectedVideoID && $0.kind == .video }
    }

    var selectedAudioSource: StreamSource? {
        sources.first { $0.id == selectedAudioID && $0.kind == .audio }
    }

    var delayDescription: String {
        if delaySeconds == 0 {
            return "不设置时差"
        } else if delaySeconds > 0 {
            return "视频延后 \(formattedDelay)s"
        } else {
            return "音频延后 \(formattedDelay.dropFirst())s"
        }
    }

    var logText: String {
        logs.joined(separator: "\n")
    }

    var isCalibrating: Bool {
        phase == .calibrating
    }

    var hasActiveSession: Bool {
        isCalibrating || isStarting || isRunning
    }

    var calibrationMergeDelaySeconds: Double {
        videoPreviewDelaySeconds - audioPreviewDelaySeconds
    }

    var calibrationMergeDescription: String {
        formatDelayDescription(calibrationMergeDelaySeconds)
    }

    private var formattedDelay: String {
        delaySeconds.formatted(.number.precision(.fractionLength(0...1)))
    }

    func startService() async {
        guard !isStarting else { return }
        guard let video = selectedVideoSource, let audio = selectedAudioSource else {
            appendLog("请选择视频源和音频源")
            return
        }

        isStarting = true
        statusText = "准备校准"
        outputURL = ""
        previewURL = ""
        videoCalibrationPreviewURL = ""
        audioCalibrationPreviewURL = ""
        videoCalibrationMergeURL = ""
        audioCalibrationMergeURL = ""
        delaySeconds = 0
        videoPreviewDelaySeconds = 0
        audioPreviewDelaySeconds = 0
        startNewLogFile(video: video, audio: audio, modeDescription: "同步校准")
        persistSelection()

        if isRunning {
            await service.stop(notifyState: false)
        }

        isRunning = false
        phase = .calibrating
        statusText = "校准预览准备中"

        do {
            let urls = try await calibrationPreviewService.start(video: video, audio: audio)
            videoCalibrationPreviewURL = urls.videoPreviewURL
            audioCalibrationPreviewURL = urls.audioPreviewURL
            videoCalibrationMergeURL = urls.videoMergeURL
            audioCalibrationMergeURL = urls.audioMergeURL
            isStarting = false
            statusText = "同步校准中"
            appendLog("已打开双源预览，请调整两侧延迟，画面同步后点击确认合并")
        } catch {
            appendLog("校准预览启动失败: \(error.localizedDescription)")
            isStarting = false
            isRunning = false
            phase = .stopped
            statusText = "校准失败"
        }
    }

    func confirmMerge() async {
        guard !isStarting else { return }
        guard let video = selectedVideoSource, let audio = selectedAudioSource else {
            appendLog("请选择视频源和音频源")
            return
        }
        guard !videoCalibrationMergeURL.isEmpty, !audioCalibrationMergeURL.isEmpty else {
            appendLog("校准预览尚未就绪")
            return
        }

        delaySeconds = calibrationMergeDelaySeconds
        UserDefaults.standard.set(delaySeconds, forKey: "delaySeconds")
        persistSelection()

        isStarting = true
        phase = .merging
        statusText = "合并启动中"
        outputURL = ""
        previewURL = ""
        startNewLogFile(video: video, audio: audio, modeDescription: calibrationMergeDescription)

        do {
            appendLog("确认合并：复用当前校准源流，不重新连接远端源")
            appendLog("合流阶段应用校准时差: \(calibrationMergeDescription)")
            try await service.startFromCalibration(
                videoURL: videoCalibrationMergeURL,
                audioURL: audioCalibrationMergeURL,
                delaySeconds: delaySeconds
            )
            videoCalibrationPreviewURL = ""
            audioCalibrationPreviewURL = ""
            videoCalibrationMergeURL = ""
            audioCalibrationMergeURL = ""
        } catch {
            appendLog("启动失败: \(error.localizedDescription)")
            isStarting = false
            isRunning = false
            phase = .calibrating
            statusText = "同步校准中"
            outputURL = ""
            previewURL = ""
        }
    }

    func updateCalibrationDelays() async {
        guard isCalibrating else { return }
        do {
            try calibrationPreviewService.updateDelays(
                videoDelay: videoPreviewDelaySeconds,
                audioDelay: audioPreviewDelaySeconds
            )
        } catch {
            appendLog("更新校准延迟失败: \(error.localizedDescription)")
        }
    }

    func stopService() async {
        isStarting = false
        await service.stop(notifyState: false)
        await calibrationPreviewService.stop()
        phase = .stopped
        isRunning = false
        statusText = "已停止"
        outputURL = ""
        previewURL = ""
        videoCalibrationPreviewURL = ""
        audioCalibrationPreviewURL = ""
        videoCalibrationMergeURL = ""
        audioCalibrationMergeURL = ""
    }

    func applyDelayChange() async {
        guard !isStarting else { return }
        UserDefaults.standard.set(delaySeconds, forKey: "delaySeconds")
        guard isRunning else { return }
        guard let video = selectedVideoSource, let audio = selectedAudioSource else {
            appendLog("请选择视频源和音频源")
            return
        }
        isStarting = true
        statusText = "应用时差中"
        appendLog("应用新时差: \(delayDescription)")
        do {
            try await service.updateDelay(video: video, audio: audio, delaySeconds: delaySeconds)
            isStarting = false
            if isRunning {
                statusText = "运行中"
            }
        } catch {
            isStarting = false
            appendLog("应用时差失败: \(error.localizedDescription)")
            if isRunning {
                statusText = "运行中"
            }
        }
    }

    func saveSource(_ source: StreamSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            var updated = source
            updated.isBuiltIn = sources[index].isBuiltIn
            sources[index] = updated
        } else {
            sources.append(source)
        }
        store.saveSources(sources)

        if source.kind == .video {
            selectedVideoID = source.id
        } else {
            selectedAudioID = source.id
        }
        persistSelection()
    }

    func deleteSource(_ source: StreamSource) {
        sources.removeAll { $0.id == source.id }
        if selectedVideoID == source.id {
            selectedVideoID = videoSources.first?.id
        }
        if selectedAudioID == source.id {
            selectedAudioID = audioSources.first?.id
        }
        store.saveSources(sources)
        persistSelection()
    }

    func persistSelection() {
        store.saveSelectedID(selectedVideoID, key: "selectedVideoID")
        store.saveSelectedID(selectedAudioID, key: "selectedAudioID")
    }

    func clearLogs() {
        logs.removeAll()
    }

    func toggleOutputURLVisibility() {
        isOutputURLVisible.toggle()
        UserDefaults.standard.set(isOutputURLVisible, forKey: "isOutputURLVisible")
    }

    func copyOutputURL() {
        guard !outputURL.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputURL, forType: .string)
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        logs.append(line)
        appendLogLineToFile(line)
        if logs.count > 600 {
            logs.removeFirst(logs.count - 600)
        }
    }

    private func startNewLogFile(video: StreamSource, audio: StreamSource, modeDescription: String? = nil) {
        logs.removeAll()
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let sessionURL = logsDirectory.appendingPathComponent("session-\(fileFormatter.string(from: Date())).log")

        try? Data().write(to: currentLogURL, options: .atomic)
        try? Data().write(to: sessionURL, options: .atomic)
        currentLogFileURL = sessionURL

        appendLog("日志文件: \(currentLogURL.path)")
        appendLog("本次会话备份: \(sessionURL.path)")
        appendLog("视频源: \(video.name)")
        appendLog("音频源: \(audio.name)")
        appendLog("时差: \(modeDescription ?? delayDescription)")
    }

    private func formatDelayDescription(_ delay: Double) -> String {
        let formatted = delay.formatted(.number.precision(.fractionLength(0...1)))
        if delay == 0 {
            return "不设置时差"
        } else if delay > 0 {
            return "视频延后 \(formatted)s"
        } else {
            return "音频延后 \(formatted.dropFirst())s"
        }
    }

    private func appendLogLineToFile(_ line: String) {
        write(line, to: currentLogURL)
        if let currentLogFileURL {
            write(line, to: currentLogFileURL)
        }
    }

    private func write(_ line: String, to url: URL) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
