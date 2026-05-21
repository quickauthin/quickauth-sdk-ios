//
//  QuickAuthOTPTextField.swift
//  UIKit equivalent of QuickAuthOtpField — single field with system OTP autofill.
//

#if canImport(UIKit)
import UIKit

public final class QuickAuthOTPTextField: UITextField {

    public var digitCount: Int = 6
    public var onCodeFilled: ((String) -> Void)?

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
        if trimmed.count == digitCount {
            onCodeFilled?(trimmed)
        }
    }
}
#endif
