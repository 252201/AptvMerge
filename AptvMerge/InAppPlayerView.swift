import AVKit
import SwiftUI

struct InAppPlayerPanel: View {
    let previewURL: String
    let isRunning: Bool
    var title: String = "内置播放"
    var subtitle: String?
    var userAgent: String = ""
    var rewritesLocalhost: Bool = true
    var emptyText: String = "服务启动后自动播放"
    var onClose: (() -> Void)?

    private var playbackURL: String {
        guard rewritesLocalhost else { return previewURL }
        guard var components = URLComponents(string: previewURL) else { return previewURL }
        components.host = "127.0.0.1"
        return components.url?.absoluteString ?? previewURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isRunning, !previewURL.isEmpty {
                    Label("播放中", systemImage: "play.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("关闭单独播放")
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black)

                if isRunning, !previewURL.isEmpty {
                    NativePlayerView(urlString: playbackURL, userAgent: userAgent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.hierarchical)
                        Text(isRunning ? "内置播放流准备中" : emptyText)
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
            context.coordinator.stopPlayer(on: nsView)
            return
        }

        context.coordinator.stopPlayer(on: nsView)
        context.coordinator.pendingPlayTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard context.coordinator.currentSignature == signature else { return }
            context.coordinator.startPlayer(
                on: nsView,
                url: url,
                userAgent: userAgent,
                isMuted: isMuted
            )
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.pendingPlayTask?.cancel()
        coordinator.stopPlayer(on: nsView)
    }

    final class Coordinator {
        var currentSignature = ""
        var pendingPlayTask: Task<Void, Never>?
        private var currentPlayer: AVPlayer?

        @MainActor
        func startPlayer(on view: AVPlayerView, url: URL, userAgent: String, isMuted: Bool) {
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
            currentPlayer = player
            view.player = player
            player.play()
        }

        @MainActor
        func stopPlayer(on view: AVPlayerView) {
            currentPlayer?.pause()
            currentPlayer?.replaceCurrentItem(with: nil)
            currentPlayer = nil
            view.player?.pause()
            view.player?.replaceCurrentItem(with: nil)
            view.player = nil
        }
    }
}
