import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var editingSource: SourceEditorState?
    @State private var sourcePendingDeletion: StreamSource?
    @State private var isLogPanelVisible = true
    @State private var hostWindow: NSWindow?

    private let sidebarWidth: CGFloat = 340
    private let controlPanelWidth: CGFloat = 900
    private let logPanelWidth: CGFloat = 400
    private let windowMinHeight: CGFloat = 680

    private var visibleWindowWidth: CGFloat {
        sidebarWidth + controlPanelWidth + logPanelWidth
    }

    private var hiddenWindowWidth: CGFloat {
        sidebarWidth + controlPanelWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            sourceSidebar
                .frame(width: sidebarWidth)

            Divider()

            controlPanel
                .frame(width: controlPanelWidth)

            if isLogPanelVisible {
                Divider()

                logPanel
                    .frame(width: logPanelWidth)
            }
        }
        .frame(width: isLogPanelVisible ? visibleWindowWidth : hiddenWindowWidth)
        .frame(minHeight: windowMinHeight)
        .background(WindowAccessor { window in
            hostWindow = window
            updateWindowSizeLimits(for: window)
        })
        .sheet(item: $editingSource) { state in
            SourceEditorView(state: state) { source in
                model.saveSource(source)
            }
        }
        .alert("删除源", isPresented: deleteAlertBinding, presenting: sourcePendingDeletion) { source in
            Button("删除", role: .destructive) {
                model.deleteSource(source)
                sourcePendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                sourcePendingDeletion = nil
            }
        } message: { source in
            Text("确定删除「\(source.name)」吗？")
        }
        .onDisappear {
            model.persistSelection()
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { sourcePendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    sourcePendingDeletion = nil
                }
            }
        )
    }

    private var sourceSidebar: some View {
        VStack(spacing: 0) {
            List {
                sourceSection(
                    title: "视频源",
                    icon: "play.rectangle",
                    sources: model.videoSources,
                    selectedID: $model.selectedVideoID,
                    type: .video
                )

                sourceSection(
                    title: "音频源",
                    icon: "waveform",
                    sources: model.audioSources,
                    selectedID: $model.selectedAudioID,
                    type: .audio
                )
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if model.isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: model.isRunning ? "dot.radiowaves.left.and.right" : "power")
                    }

                    Text(model.statusText)
                }
                .foregroundStyle(model.isRunning ? .green : .secondary)
                .font(.callout.weight(.medium))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    outputURLText

                    Spacer(minLength: 6)

                    Button {
                        model.toggleOutputURLVisibility()
                    } label: {
                        Image(systemName: model.isOutputURLVisible ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.plain)
                    .help(model.isOutputURLVisible ? "隐藏链接" : "显示链接")
                    .disabled(model.outputURL.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var outputURLDisplayText: String {
        if model.outputURL.isEmpty {
            return model.isStarting ? "正在准备链接" : "服务未启动"
        }
        return model.isOutputURLVisible ? model.outputURL : "链接已隐藏"
    }

    @ViewBuilder
    private var outputURLText: some View {
        if model.isOutputURLVisible {
            Text(outputURLDisplayText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            Text(outputURLDisplayText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func sourceSection(
        title: String,
        icon: String,
        sources: [StreamSource],
        selectedID: Binding<UUID?>,
        type: StreamSource.Kind
    ) -> some View {
        Section {
            ForEach(sources) { source in
                SourceRow(
                    source: source,
                    isSelected: selectedID.wrappedValue == source.id,
                    onDelete: {
                        sourcePendingDeletion = source
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedID.wrappedValue = source.id
                    model.persistSelection()
                }
                .contextMenu {
                    Button("编辑") {
                        editingSource = SourceEditorState(source: source)
                    }
                    Button("删除", role: .destructive) {
                        sourcePendingDeletion = source
                    }
                }
            }

            Button {
                editingSource = SourceEditorState(type: type)
            } label: {
                Label("新增\(title)", systemImage: "plus")
            }
            .buttonStyle(.plain)
        } header: {
            Label(title, systemImage: icon)
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    serviceControls
                    InAppPlayerPanel(previewURL: model.previewURL, isRunning: model.isRunning)
                    runtimeSettings
                }
                .padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "tv.and.mediabox")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("APTV Merge")
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text("v\(appVersion)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("本机直播源合流服务")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer()

            Button {
                toggleLogPanel()
            } label: {
                Label(isLogPanelVisible ? "收起日志" : "打开日志", systemImage: isLogPanelVisible ? "sidebar.right" : "sidebar.right")
            }
            .help(isLogPanelVisible ? "收起右侧日志窗口" : "打开右侧日志窗口")

            Button {
                model.copyOutputURL()
            } label: {
                Label("复制链接", systemImage: "doc.on.doc")
            }
            .disabled(model.outputURL.isEmpty)

            Button {
                Task { await model.stopService() }
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .disabled(!model.isRunning && !model.isStarting)

            Button {
                Task { await model.startService() }
            } label: {
                if model.isStarting {
                    Label(model.isRunning ? "重启中" : "启动中", systemImage: "hourglass")
                } else {
                    Label(model.isRunning ? "重启" : "启动", systemImage: model.isRunning ? "arrow.clockwise" : "play.fill")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isStarting)
        }
        .padding(20)
    }

    private func toggleLogPanel() {
        let shouldShowLogPanel = !isLogPanelVisible

        withAnimation(.easeInOut(duration: 0.18)) {
            isLogPanelVisible = shouldShowLogPanel
        }

        resizeWindowForLogPanel(showing: shouldShowLogPanel)
    }

    private func resizeWindowForLogPanel(showing: Bool) {
        guard let window = hostWindow ?? NSApp.keyWindow else { return }

        let targetWidth = showing ? visibleWindowWidth : hiddenWindowWidth
        window.minSize = NSSize(width: targetWidth, height: windowMinHeight)
        window.maxSize = NSSize(width: targetWidth, height: .greatestFiniteMagnitude)

        var frame = window.frame
        frame.size.width = targetWidth
        window.setFrame(frame, display: true, animate: true)
    }

    private func updateWindowSizeLimits(for window: NSWindow?) {
        guard let window else { return }
        let targetWidth = isLogPanelVisible ? visibleWindowWidth : hiddenWindowWidth
        window.minSize = NSSize(width: targetWidth, height: windowMinHeight)
        window.maxSize = NSSize(width: targetWidth, height: .greatestFiniteMagnitude)
    }

    private var serviceControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("当前组合")
                .font(.headline)

            HStack(spacing: 12) {
                SummaryTile(title: "视频", value: model.selectedVideoSource?.name ?? "未选择", systemImage: "play.rectangle")
                SummaryTile(title: "音频", value: model.selectedAudioSource?.name ?? "未选择", systemImage: "waveform")
                SummaryTile(title: "模式", value: modeText, systemImage: "slider.horizontal.3")
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
    }

    private var modeText: String {
        if model.delaySeconds > 0 {
            return "视频延后"
        } else if model.delaySeconds < 0 {
            return "音频延后"
        } else {
            return "零时差合流"
        }
    }

    private var runtimeSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("时差")
                .font(.headline)

            HStack(alignment: .center, spacing: 14) {
                Stepper(value: $model.delaySeconds, in: -120...240, step: 0.5) {
                    TextField("0", value: $model.delaySeconds, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                Text(model.delayDescription)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 180, alignment: .leading)

                Button {
                    Task { await model.applyDelayChange() }
                } label: {
                    Label("应用时差", systemImage: "checkmark.circle")
                }
                .disabled(!model.isRunning)

                Spacer()
            }

            Text("0 秒会跳过缓存层。正数表示视频延后，可动态调整；负数表示音频延后，使用轻量偏移，应用新时差时会短暂重启合流进程。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("日志")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    model.clearLogs()
                } label: {
                    Label("清空", systemImage: "trash")
                }
            }

            ScrollView {
                Text(model.logText.isEmpty ? "暂无日志" : model.logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onWindowChange(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindowChange(nsView.window)
        }
    }
}

private struct SourceRow: View {
    let source: StreamSource
    let isSelected: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .green : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.callout.weight(.medium))
                Text(source.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("删除源")
        }
        .padding(.vertical, 4)
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    ContentView()
}
