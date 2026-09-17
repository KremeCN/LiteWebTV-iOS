import AVFoundation
import AVKit
import SwiftUI
import UIKit

final class CctvNativePlayer: NSObject {
    let player = AVPlayer()
    var onReady: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    private var itemObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?

    override init() {
        super.init()
        player.allowsExternalPlayback = false
        player.actionAtItemEnd = .none
        if #available(iOS 15.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .pauses
        }
    }

    func play(url: URL) {
        let item = AVPlayerItem(url: url)
        itemObservation?.invalidate()
        sizeObservation?.invalidate()
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    self?.player.play()
                    self?.onReady?()
                    let size = item.presentationSize
                    if size.width > 0, size.height > 0 {
                        self?.onVideoSize?(size)
                    }
                case .failed:
                    let message = item.error?.localizedDescription ?? "原生播放失败"
                    self?.onFailed?(message)
                default:
                    break
                }
            }
        }
        sizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async {
                self?.onVideoSize?(size)
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func stop() {
        itemObservation?.invalidate()
        sizeObservation?.invalidate()
        itemObservation = nil
        sizeObservation = nil
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

struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        controller.view.isUserInteractionEnabled = false
        if #available(iOS 16.0, *) {
            controller.allowsVideoFrameAnalysis = false
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
