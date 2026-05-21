//
//  QuickAuthOtpField.swift
//  6-cell OTP input view with system one-time-code autofill.
//

import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

@available(iOS 14.0, *)
public struct QuickAuthOtpField: View {

    @Binding public var code: String
    public var digitCount: Int = 6
    public var onCodeFilled: ((String) -> Void)? = nil

    public init(
        code: Binding<String>,
        digitCount: Int = 6,
        onCodeFilled: ((String) -> Void)? = nil
    ) {
        self._code = code
        self.digitCount = digitCount
        self.onCodeFilled = onCodeFilled
    }

    public var body: some View {
        ZStack {
            #if canImport(UIKit)
            // Hidden text field that drives the input + receives system OTP autofill.
            // Wrapped UITextField gives us reliable focus on iOS 14 without @FocusState.
            OTPHiddenField(text: $code, digitCount: digitCount, onCodeFilled: onCodeFilled)
                .frame(height: 1)
                .opacity(0.02)
            #endif

            HStack(spacing: 8) {
                ForEach(0..<digitCount, id: \.self) { idx in
                    cell(for: idx)
                }
            }
        }
    }

    private func cell(for index: Int) -> some View {
        let chars = Array(code)
        let char = index < chars.count ? String(chars[index]) : ""
        let isCursor = index == chars.count
        return Text(char)
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .frame(width: 44, height: 52)
            .background(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isCursor ? Color.qaAccent : Color.qaMist, lineWidth: isCursor ? 2 : 1)
            )
            .foregroundColor(.qaInk)
    }
}

#if canImport(UIKit)
@available(iOS 14.0, *)
private struct OTPHiddenField: UIViewRepresentable {
    @Binding var text: String
    let digitCount: Int
    let onCodeFilled: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        if #available(iOS 12.0, *) { tf.textContentType = .oneTimeCode }
        tf.keyboardType = .numberPad
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        DispatchQueue.main.async { tf.becomeFirstResponder() }
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text { uiView.text = text }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: OTPHiddenField
        init(_ parent: OTPHiddenField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            let digits = (field.text ?? "").filter { $0.isNumber }
            let trimmed = String(digits.prefix(parent.digitCount))
            if trimmed != field.text { field.text = trimmed }
            parent.text = trimmed
            if trimmed.count == parent.digitCount {
                parent.onCodeFilled?(trimmed)
            }
        }
    }
}
#endif
