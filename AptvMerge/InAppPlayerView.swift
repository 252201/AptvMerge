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
    var delayRefreshToken: Double = 0
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
        let signature = "\(urlString)|\(userAgent)|\(isMuted)"
        let roundedDelayToken = (delayRefreshToken * 10).rounded() / 10
        if context.coordinator.currentSignature == signature {
            context.coordinator.refreshLiveEdgeIfNeeded(on: nsView, delayToken: roundedDelayToken)
            return
        }

        context.coordinator.currentSignature = signature
        context.coordinator.currentDelayToken = roundedDelayToken
        context.coordinator.pendingPlayTask?.cancel()
        context.coordinator.pendingSeekTask?.cancel()
        context.coordinator.pendingAutoPlayTask?.cancel()

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
        coordinator.pendingSeekTask?.cancel()
        coordinator.pendingAutoPlayTask?.cancel()
        coordinator.stopPlayer(on: nsView)
    }

    final class Coordinator {
        var currentSignature = ""
        var currentDelayToken: Double?
        var pendingPlayTask: Task<Void, Never>?
        var pendingSeekTask: Task<Void, Never>?
        var pendingAutoPlayTask: Task<Void, Never>?
        private var currentPlayer: AVPlayer?

        @MainActor
        func startPlayer(on view: AVPlayerView, url: URL, userAgent: String, isMuted: Bool) {
            let asset: AVURLAsset
            if userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                asset = AVURLAsset(url: url)
            } else {
                asset = AVURLAsset(
                    url: url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": userAgent]]
                )
            }

            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 0
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            player.isMuted = isMuted
            currentPlayer = player
            view.player = player
            player.play()
            scheduleAutoPlayNudges(on: view, player: player)
        }

        @MainActor
        private func scheduleAutoPlayNudges(on view: AVPlayerView, player: AVPlayer) {
            pendingAutoPlayTask?.cancel()
            pendingAutoPlayTask = Task { @MainActor in
                let delays: [UInt64] = [
                    150_000_000,
                    350_000_000,
                    700_000_000,
                    1_200_000_000,
                    2_000_000_000
                ]

                for delay in delays {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                    guard self.currentPlayer === player, view.player === player else { return }

                    if player.rate == 0 {
                        self.seekToLiveEdge(on: view)
                    } else {
                        player.play()
                    }
                }
            }
        }

        @MainActor
        func refreshLiveEdgeIfNeeded(on view: AVPlayerView, delayToken: Double) {
            guard currentDelayToken != delayToken else { return }
            currentDelayToken = delayToken
            pendingSeekTask?.cancel()
            pendingSeekTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                seekToLiveEdge(on: view)
            }
        }

        @MainActor
        private func seekToLiveEdge(on view: AVPlayerView) {
            guard let player = currentPlayer ?? view.player,
                  let item = player.currentItem
            else { return }

            let ranges = item.seekableTimeRanges
            guard let rangeValue = ranges.last?.timeRangeValue else {
                player.play()
                return
            }

            let liveEdge = CMTimeRangeGetEnd(rangeValue)
            guard liveEdge.isValid, liveEdge.isNumeric else {
                player.play()
                return
            }

            let target = CMTimeSubtract(liveEdge, CMTime(seconds: 0.15, preferredTimescale: 600))
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.play()
            }
        }

        @MainActor
        func stopPlayer(on view: AVPlayerView) {
            pendingSeekTask?.cancel()
            pendingAutoPlayTask?.cancel()
            currentPlayer?.pause()
            currentPlayer?.replaceCurrentItem(with: nil)
            currentPlayer = nil
            view.player?.pause()
            view.player?.replaceCurrentItem(with: nil)
            view.player = nil
        }
    }
}
