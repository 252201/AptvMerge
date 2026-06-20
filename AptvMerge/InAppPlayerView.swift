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

struct NativePlayerView: NSViewRepresentable {
    let urlString: String
    var userAgent: String = ""
    var delaySeconds: Double = 0
    var isMuted: Bool = false

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
        let roundedDelay = (delaySeconds * 10).rounded() / 10
        let signature = "\(urlString)|\(userAgent)|\(roundedDelay)|\(isMuted)"
        guard context.coordinator.currentSignature != signature else { return }
        context.coordinator.currentSignature = signature
        context.coordinator.pendingPlayTask?.cancel()

        guard let url = URL(string: urlString) else {
            nsView.player?.pause()
            nsView.player = nil
            return
        }

        let player: AVPlayer
        if userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            player = AVPlayer(url: url)
        } else {
            let asset = AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]]
            )
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        player.isMuted = isMuted
        nsView.player = player

        if roundedDelay > 0 {
            let task = Task { [weak player, weak coordinator = context.coordinator] in
                try? await Task.sleep(for: .milliseconds(Int(roundedDelay * 1000)))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard coordinator?.currentSignature == signature else { return }
                    player?.play()
                }
            }
            context.coordinator.pendingPlayTask = task
        } else {
            player.play()
        }
    }

    final class Coordinator {
        var currentSignature = ""
        var pendingPlayTask: Task<Void, Never>?
    }
}
