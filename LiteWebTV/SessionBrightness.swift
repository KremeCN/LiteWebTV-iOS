import UIKit

/// 手势亮度只覆盖本进程在前台的这一次会话；离开前台时恢复系统亮度。
enum SessionBrightness {
    static let shared = Controller()

    final class Controller {
        private var systemValue = UIScreen.main.brightness
        private var sessionValue = UIScreen.main.brightness
        private var didOverride = false
        private var observers: [NSObjectProtocol] = []

        var current: CGFloat { sessionValue }

        func start() {
            systemValue = UIScreen.main.brightness
            sessionValue = systemValue
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.restoreSystem()
                },
                center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.restoreSystem()
                },
                center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.restoreSystem()
                },
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.becameActive()
                },
            ]
        }

        @discardableResult
        func adjust(by delta: CGFloat) -> CGFloat {
            if !didOverride {
                systemValue = UIScreen.main.brightness
                sessionValue = systemValue
            }
            sessionValue = min(1, max(0.01, sessionValue + delta))
            didOverride = true
            apply(sessionValue)
            return sessionValue
        }

        private func becameActive() {
            systemValue = UIScreen.main.brightness
            if didOverride {
                apply(sessionValue)
            } else {
                sessionValue = systemValue
            }
        }

        private func apply(_ value: CGFloat) {
            UIScreen.main.brightness = value
        }

        private func restoreSystem() {
            guard didOverride else { return }
            apply(systemValue)
        }
    }
}
