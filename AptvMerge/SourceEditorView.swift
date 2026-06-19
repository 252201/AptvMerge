import SwiftUI

struct SourceEditorState: Identifiable {
    let id = UUID()
    var source: StreamSource
    var isNew: Bool

    init(type: StreamSource.Kind) {
        self.source = StreamSource(
            id: UUID(),
            name: "",
            url: "",
            kind: type,
            userAgent: "",
            isBuiltIn: false
        )
        self.isNew = true
    }

    init(source: StreamSource) {
        self.source = source
        self.isNew = false
    }
}

struct SourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source: StreamSource
    let isNew: Bool
    let onSave: (StreamSource) -> Void

    init(state: SourceEditorState, onSave: @escaping (StreamSource) -> Void) {
        _source = State(initialValue: state.source)
        isNew = state.isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "新增源" : "编辑源")
                .font(.title3.weight(.semibold))

            Picker("类型", selection: $source.kind) {
                Text("视频源").tag(StreamSource.Kind.video)
                Text("音频源").tag(StreamSource.Kind.audio)
            }
            .pickerStyle(.segmented)
            .disabled(source.isBuiltIn)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("名称")
                    TextField("例如 TSN-1080P", text: $source.name)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("URL")
                    TextField("http://...", text: $source.url)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("User-Agent")
                    TextField("可选，仅部分音频源需要", text: $source.userAgent)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    onSave(source)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
