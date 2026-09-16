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
        private var outputObservation: NSKeyValueObservation?
        private var gesturing = false
        private var lastWriteAt = Date.distantPast
        /// 最近一次写入（或硬件键同步）的音量。`outputVolume` 滞后，不能当手势累加起点。
        private var lastSet: Float?

        var current: Float {
            lastSet ?? AVAudioSession.sharedInstance().outputVolume
        }

        var percent: Int {
            Int((current * 100).rounded())
        }

        func activateSession() {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
            if outputObservation == nil {
                outputObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
                    DispatchQueue.main.async {
                        self?.outputVolumeChanged(session.outputVolume)
                    }
                }
            }
        }

        /// 手指落在右侧时提前挂上滑块，避免进入音量手势的前几帧写不进去。
        func prepare() {
            removalWork?.cancel()
            removalWork = nil
            attachVolumeView()
            scheduleDetach(after: 2.0)
        }

        @discardableResult
        func beginGesture() -> Float {
            gesturing = true
            removalWork?.cancel()
            removalWork = nil
            attachVolumeView()
            let start = lastSet ?? AVAudioSession.sharedInstance().outputVolume
            lastSet = start
            apply(start)
            return start
        }

        @discardableResult
        func adjust(by delta: Float) -> Float {
            if !gesturing {
                _ = beginGesture()
            }
            let next = min(1, max(0, (lastSet ?? AVAudioSession.sharedInstance().outputVolume) + delta))
            lastSet = next
            apply(next)
            return next
        }

        func endGesture() {
            gesturing = false
            if let lastSet {
                apply(lastSet)
            }
            // 滑块提交是异步的；等系统音量跟上后再拆，避免改动被丢掉。
            scheduleDetach(after: 1.5)
        }

        private func apply(_ value: Float) {
            lastWriteAt = Date()
            attachVolumeView()
            write(value)
            if slider == nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.attachVolumeView()
                    self.write(self.lastSet ?? value)
                }
            }
        }

        private func write(_ value: Float) {
            guard let slider else { return }
            // 直接改 `.value` 才会动系统音量；`sendActions` 容易闪 HUD、打断播放。
            if abs(slider.value - value) > 0.001 {
                slider.value = value
            }
        }

        private func attachVolumeView() {
            removalWork?.cancel()
            removalWork = nil
            if volumeView == nil, let window = hostWindow {
                let view = MPVolumeView(frame: CGRect(x: -1200, y: -1200, width: 120, height: 120))
                view.alpha = 0.01
                view.isHidden = false
                view.isUserInteractionEnabled = false
                window.addSubview(view)
                window.layoutIfNeeded()
                volumeView = view
            }
            volumeView?.layoutIfNeeded()
            if slider == nil {
                slider = findSlider(in: volumeView)
            }
        }

        private func findSlider(in root: UIView?) -> UISlider? {
            guard let root else { return nil }
            if let slider = root as? UISlider { return slider }
            for child in root.subviews {
                if let slider = findSlider(in: child) { return slider }
            }
            return nil
        }

        private func outputVolumeChanged(_ value: Float) {
            if gesturing { return }
            if Date().timeIntervalSince(lastWriteAt) < 1.5 {
                if let lastSet, abs(value - lastSet) < 0.03 {
                    scheduleDetach(after: 0.2)
                }
                return
            }
            lastSet = value
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

        private var hostWindow: UIWindow? {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden })
        }
    }
}
