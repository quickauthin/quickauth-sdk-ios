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
        Task { @MainActor in
            do {
                let session = try await QuickAuth.shared.auth.startOTP(phone: phone, channel: channel)
                self.isEnabled = true
                self.presentOTPEntry(sessionId: session.sessionId)
            } catch {
                self.isEnabled = true
                self.onError?(error)
            }
        }
    }

    private func presentOTPEntry(sessionId: String) {
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
        alert.addAction(UIAlertAction(title: "Verify", style: .default) { [weak self] _ in
            guard let self = self,
                  let code = alert.textFields?.first?.text, code.count >= 4 else { return }
            Task { @MainActor in
                do {
                    let result = try await QuickAuth.shared.auth.verifyOTP(sessionId: sessionId, code: code)
                    self.onSuccess?(result.jwt)
                } catch {
                    self.onError?(error)
                }
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
