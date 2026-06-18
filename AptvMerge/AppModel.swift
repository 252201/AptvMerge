import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [StreamSource]
    @Published var selectedVideoID: UUID?
    @Published var selectedAudioID: UUID?
    @Published var delaySeconds: Double
    @Published var isRunning = false
    @Published var statusText = "已停止"
    @Published var outputURL = ""
    @Published var logs: [String] = []

    private let store = SourceStore()
    private let service = MergeService()

    init() {
        let loadedSources = store.loadSources()
        sources = loadedSources
        selectedVideoID = store.loadSelectedID(key: "selectedVideoID") ?? loadedSources.first(where: { $0.kind == .video })?.id
        selectedAudioID = store.loadSelectedID(key: "selectedAudioID") ?? loadedSources.first(where: { $0.kind == .audio })?.id
        delaySeconds = UserDefaults.standard.object(forKey: "delaySeconds") as? Double ?? 0

        service.onLog = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }
        service.onStateChange = { [weak self] running, status, url in
            Task { @MainActor in
                self?.isRunning = running
                self?.statusText = status
                self?.outputURL = url
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

    private var formattedDelay: String {
        delaySeconds.formatted(.number.precision(.fractionLength(0...1)))
    }

    func startService() async {
        guard let video = selectedVideoSource, let audio = selectedAudioSource else {
            appendLog("请选择视频源和音频源")
            return
        }

        persistSelection()
        UserDefaults.standard.set(delaySeconds, forKey: "delaySeconds")

        do {
            try await service.start(video: video, audio: audio, delaySeconds: delaySeconds)
        } catch {
            appendLog("启动失败: \(error.localizedDescription)")
            isRunning = false
            statusText = "启动失败"
        }
    }

    func stopService() async {
        await service.stop()
    }

    func applyDelayChange() async {
        UserDefaults.standard.set(delaySeconds, forKey: "delaySeconds")
        guard isRunning else { return }
        guard let video = selectedVideoSource, let audio = selectedAudioSource else {
            appendLog("请选择视频源和音频源")
            return
        }
        appendLog("应用新时差: \(delayDescription)")
        do {
            try await service.updateDelay(video: video, audio: audio, delaySeconds: delaySeconds)
        } catch {
            appendLog("应用时差失败: \(error.localizedDescription)")
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

    func copyOutputURL() {
        guard !outputURL.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputURL, forType: .string)
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 600 {
            logs.removeFirst(logs.count - 600)
        }
    }
}
