import AVKit
import SwiftUI

struct InAppPlayerPanel: View {
    let previewURL: String
    let isRunning: Bool

    private var playbackURL: String {
        guard var components = URLComponents(string: previewURL) else { return previewURL }
        components.host = "127.0.0.1"
        return components.url?.absoluteString ?? previewURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("内置播放")
                    .font(.headline)
                Spacer()
                if isRunning, !previewURL.isEmpty {
                    Label("播放中", systemImage: "play.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black)

                if isRunning, !previewURL.isEmpty {
                    NativePlayerView(urlString: playbackURL)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.hierarchical)
                        Text(isRunning ? "内置播放流准备中" : "服务启动后自动播放")
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(minHeight: 260)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }
}

private struct NativePlayerView: NSViewRepresentable {
    let urlString: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        guard context.coordinator.currentURLString != urlString else { return }
        context.coordinator.currentURLString = urlString

        guard let url = URL(string: urlString) else {
            nsView.player?.pause()
            nsView.player = nil
            return
        }

        let player = AVPlayer(url: url)
        nsView.player = player
        player.play()
    }

    final class Coordinator {
        var currentURLString = ""
    }
}
