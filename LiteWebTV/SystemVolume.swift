import AVFoundation
import MediaPlayer
import UIKit

/// iOS 上 `HTMLMediaElement.volume` 恒为 1。手势调音量时临时挂上 `MPVolumeView`；
/// 常驻在窗口里会吞掉音量键的系统 HUD。
enum SystemVolume {
    static let shared = Controller()

    final class Controller {
        private var volumeView: MPVolumeView?
        private var slider: UISlider?
        private var removalWork: DispatchWorkItem?

        var current: Float {
            AVAudioSession.sharedInstance().outputVolume
        }

        var percent: Int {
            Int((current * 100).rounded())
        }

        func activateSession() {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }

        @discardableResult
        func adjust(by delta: Float) -> Float {
            activateSession()
            attachVolumeView()
            let next = min(1, max(0, current + delta))
            slider?.value = next
            return next
        }

        func endGesture() {
            scheduleDetach(after: 0.8)
        }

        private func attachVolumeView() {
            removalWork?.cancel()
            removalWork = nil
            if volumeView == nil, let window = keyWindow {
                let view = MPVolumeView(frame: CGRect(x: -1200, y: -1200, width: 16, height: 16))
                view.alpha = 0.01
                view.isUserInteractionEnabled = false
                window.addSubview(view)
                volumeView = view
            }
            if slider == nil {
                slider = volumeView?.subviews.first { $0 is UISlider } as? UISlider
            }
        }

        private func scheduleDetach(after delay: TimeInterval) {
            removalWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.volumeView?.removeFromSuperview()
                self?.volumeView = nil
                self?.slider = nil
            }
            removalWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private var keyWindow: UIWindow? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }
        }
    }
}
