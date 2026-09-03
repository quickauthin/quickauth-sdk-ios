//
//  QuickAuthOTPTextField.swift
//  UIKit equivalent of QuickAuthOtpField — single field with system OTP autofill.
//

#if canImport(UIKit)
import UIKit

public final class QuickAuthOTPTextField: UITextField {

    public var digitCount: Int = 6
    public var onCodeFilled: ((String) -> Void)?

    /// Forward codes the **system** fills in (the "From Messages" keyboard
    /// suggestion) to `QuickAuth.shared.auth.publishAutoReadCode(_:)`, which is
    /// what makes `.otpAutoRead` and `autoSubmit` work on iOS — the OS never
    /// tells the SDK directly. Set `false` to forward it yourself.
    public var forwardsAutofillToQuickAuth: Bool = true

    /// Length before the current edit, so a code that appeared all at once can
    /// be told apart from one the user typed.
    private var previousLength = 0

    public init(digitCount: Int = 6) {
        self.digitCount = digitCount
        super.init(frame: .zero)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        if #available(iOS 12.0, *) { textContentType = .oneTimeCode }
        keyboardType = .numberPad
        font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
        textAlignment = .center
        borderStyle = .roundedRect
        addTarget(self, action: #selector(handleChange), for: .editingChanged)
    }

    @objc private func handleChange() {
        let digits = (text ?? "").filter { $0.isNumber }
        let trimmed = String(digits.prefix(digitCount))
        if trimmed != text { text = trimmed }
        let grew = trimmed.count - previousLength
        previousLength = trimmed.count
        guard trimmed.count == digitCount else { return }

        // Only a jump of more than one digit is the OS (or a paste) filling the
        // field; a typed code arrives a digit at a time and is not an auto-read.
        if forwardsAutofillToQuickAuth, grew > 1, QuickAuth.shared.isInitialized {
            QuickAuth.shared.auth.publishAutoReadCode(trimmed)
        }
        onCodeFilled?(trimmed)
    }
}
#endif
