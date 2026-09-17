import AVFoundation
import SwiftUI
import UIKit

final class CctvNativePlayer: NSObject {
    let player = AVPlayer()
    var onReady: (() -> Void)?
    var onFailed: ((String) -> Void)?
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?

    func play(url: URL) {
        let item = AVPlayerItem(url: url)
        itemObservation?.invalidate()
        statusObservation?.invalidate()
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    self?.player.play()
                    self?.onReady?()
                case .failed:
                    let message = item.error?.localizedDescription ?? "原生播放失败"
                    self?.onFailed?(message)
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func stop() {
        itemObservation?.invalidate()
        statusObservation?.invalidate()
        itemObservation = nil
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func pause() {
        player.pause()
    }

    func togglePause() {
        if player.rate == 0 {
            player.play()
        } else {
            player.pause()
        }
    }

    func resumeIfPaused() {
        if player.rate == 0, player.currentItem != nil {
            player.play()
        }
    }
}

final class NativePlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct NativePlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> NativePlayerUIView {
        let view = NativePlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: NativePlayerUIView, context: Context) {
        uiView.player = player
    }
}
