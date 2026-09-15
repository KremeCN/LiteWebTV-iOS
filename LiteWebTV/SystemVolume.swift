import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// iOS 上 `HTMLMediaElement.volume` 恒为 1，网页音量手势会闪回 100%。
/// 用隐藏的 `MPVolumeView` 改系统音量。
enum SystemVolume {
    static let shared = Controller()

    final class Controller {
        fileprivate weak var slider: UISlider?

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

        func bind(slider: UISlider?) {
            self.slider = slider
        }

        @discardableResult
        func adjust(by delta: Float) -> Float {
            activateSession()
            let next = min(1, max(0, current + delta))
            if slider == nil {
                slider = volumeView?.subviews.first { $0 is UISlider } as? UISlider
            }
            slider?.value = next
            return next
        }

        private var volumeView: MPVolumeView? {
            slider?.superview as? MPVolumeView
        }
    }
}

/// 必须进窗口层级，`MPVolumeView` 的滑杆才能改系统音量。
final class SystemVolumeHostView: UIView {
    private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        volumeView.alpha = 0.0001
        volumeView.isUserInteractionEnabled = false
        addSubview(volumeView)
        SystemVolume.shared.bind(slider: volumeView.subviews.first { $0 is UISlider } as? UISlider)
        SystemVolume.shared.activateSession()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if SystemVolume.shared.slider == nil {
            SystemVolume.shared.bind(slider: volumeView.subviews.first { $0 is UISlider } as? UISlider)
        }
    }
}

struct HiddenSystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> SystemVolumeHostView {
        SystemVolumeHostView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateUIView(_ uiView: SystemVolumeHostView, context: Context) {}
}
