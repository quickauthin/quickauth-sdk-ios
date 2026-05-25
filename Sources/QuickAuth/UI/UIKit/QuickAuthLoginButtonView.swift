//
//  QuickAuthLoginButtonView.swift
//  UIKit equivalent of QuickAuthLoginButton.
//

#if canImport(UIKit)
import UIKit

public final class QuickAuthLoginButtonView: UIButton {

    public var phone: String = ""
    public var channel: OTPChannel = .auto
    public var onSuccess: ((String) -> Void)?
    public var onError: ((Error) -> Void)?

    /// The view controller used to present the OTP entry sheet.
    public weak var presenter: UIViewController?

    public init(phone: String) {
        super.init(frame: .zero)
        self.phone = phone
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = UIColor(red: 0x00/255.0, green: 0xC6/255.0, blue: 0x37/255.0, alpha: 1)
        setTitleColor(.white, for: .normal)
        setTitle("[Q]  Continue", for: .normal)
        titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        layer.cornerRadius = 10
        contentEdgeInsets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @objc private func handleTap() {
        isEnabled = false
        // Install a transient event handler that drives the UIAlert flow,
        // preserving any pre-existing handler the host app has set.
        let previousHandler = QuickAuth.shared.authEventHandler
        QuickAuth.shared.setAuthEventHandler({ [weak self] event in
            previousHandler?(event)
            guard let self = self else { return }
            switch event {
            case .otpSent:
                Task { @MainActor in
                    self.isEnabled = true
                    self.presentOTPEntry()
                }
            case .verified(let requestId, _):
                Task { @MainActor in self.onSuccess?(requestId) }
                QuickAuth.shared.setAuthEventHandler(previousHandler)
            case .otpFailed(let message):
                Task { @MainActor in
                    self.onError?(NSError(domain: "QuickAuth", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: message]))
                }
            case .error(_, let message):
                Task { @MainActor in
                    self.isEnabled = true
                    self.onError?(NSError(domain: "QuickAuth", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: message]))
                }
                QuickAuth.shared.setAuthEventHandler(previousHandler)
            case .otpAutoRead:
                break
            }
        })
        Task { @MainActor in
            do {
                try await QuickAuth.shared.auth.initiate(phone: phone, channel: channel)
            } catch {
                self.isEnabled = true
                self.onError?(error)
                QuickAuth.shared.setAuthEventHandler(previousHandler)
            }
        }
    }

    private func presentOTPEntry() {
        guard let presenter = presenter ?? Self.topViewController() else { return }
        let alert = UIAlertController(
            title: "Enter OTP",
            message: "Sent to \(phone)",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            if #available(iOS 12.0, *) { tf.textContentType = .oneTimeCode }
            tf.keyboardType = .numberPad
            tf.placeholder = "123456"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Verify", style: .default) { _ in
            guard let code = alert.textFields?.first?.text, code.count >= 4 else { return }
            Task { @MainActor in
                try? await QuickAuth.shared.auth.submitOtp(code)
            }
        })
        presenter.present(alert, animated: true)
    }

    private static func topViewController(base: UIViewController? = {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .rootViewController
    }()) -> UIViewController? {
        if let nav = base as? UINavigationController { return topViewController(base: nav.visibleViewController) }
        if let tab = base as? UITabBarController, let sel = tab.selectedViewController {
            return topViewController(base: sel)
        }
        if let presented = base?.presentedViewController { return topViewController(base: presented) }
        return base
    }
}
#endif
