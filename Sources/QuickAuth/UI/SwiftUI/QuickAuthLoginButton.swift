//
//  QuickAuthLoginButton.swift
//  Pre-built SwiftUI button that runs the full OTP flow.
//

import SwiftUI

@available(iOS 14.0, *)
public struct QuickAuthLoginButton: View {

    public enum Style {
        case primary
        case secondary
    }

    public let phone: String
    public let onSuccess: (String) -> Void
    public let onError: (Error) -> Void
    public var style: Style = .primary
    public var text: String = "Continue"
    public var channel: OTPChannel = .auto

    @State private var loading = false
    @State private var presentingOTP = false
    @State private var code: String = ""
    @State private var verifying = false
    @State private var errorText: String?

    public init(
        phone: String,
        onSuccess: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void,
        style: Style = .primary,
        text: String = "Continue",
        channel: OTPChannel = .auto
    ) {
        self.phone = phone
        self.onSuccess = onSuccess
        self.onError = onError
        self.style = style
        self.text = text
        self.channel = channel
    }

    public var body: some View {
        Button(action: startFlow) {
            HStack(spacing: 8) {
                QuickAuthBadge()
                Text(text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                if loading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(style == .primary ? Color.qaAccent : Color.qaInk)
            .cornerRadius(10)
            .opacity(loading ? 0.85 : 1.0)
        }
        .disabled(loading)
        .sheet(isPresented: $presentingOTP) { otpSheet }
    }

    private var otpSheet: some View {
        VStack(spacing: 16) {
            Text("Enter the 6-digit code")
                .font(.system(size: 18, weight: .semibold))
            Text("Sent to \(phone)")
                .font(.system(size: 14))
                .foregroundColor(.qaMuted)

            QuickAuthOtpField(code: $code, digitCount: 6, onCodeFilled: { _ in verify() })
                .padding(.vertical, 8)

            if let errorText = errorText {
                Text(errorText)
                    .font(.system(size: 13))
                    .foregroundColor(.red)
            }

            Button(action: verify) {
                Text(verifying ? "Verifying..." : "Verify")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.qaAccent)
                    .cornerRadius(10)
            }
            .disabled(verifying || code.count < 6)

            Spacer()
        }
        .padding(20)
    }

    // MARK: - Flow

    private func startFlow() {
        loading = true
        errorText = nil
        // Install a transient event handler that drives the sheet. We
        // restore any pre-existing handler when the flow terminates so
        // QuickAuthLoginButton composes cleanly with apps that already
        // listen on `onAuthEvent`.
        let previousHandler = QuickAuth.shared.authEventHandler
        QuickAuth.shared.setAuthEventHandler({ event in
            previousHandler?(event)
            switch event {
            case .otpSent:
                Task { @MainActor in
                    self.loading = false
                    self.presentingOTP = true
                }
            case .verified(let requestId, _):
                Task { @MainActor in
                    self.verifying = false
                    self.loading = false
                    self.presentingOTP = false
                    self.code = ""
                    self.onSuccess(requestId)
                }
                QuickAuth.shared.setAuthEventHandler(previousHandler)
            case .otpFailed(let message):
                Task { @MainActor in
                    self.verifying = false
                    self.errorText = message
                }
            case .error(_, let message):
                Task { @MainActor in
                    self.verifying = false
                    self.loading = false
                    self.errorText = message
                }
                QuickAuth.shared.setAuthEventHandler(previousHandler)
            case .otpAutoRead:
                break
            }
        })
        Task {
            do {
                try await QuickAuth.shared.auth.initiate(phone: phone, channel: channel)
            } catch {
                await MainActor.run {
                    self.loading = false
                    self.onError(error)
                }
                QuickAuth.shared.setAuthEventHandler(previousHandler)
            }
        }
    }

    private func verify() {
        guard code.count == 6 else { return }
        verifying = true
        errorText = nil
        Task {
            do {
                try await QuickAuth.shared.auth.submitOtp(code)
            } catch {
                await MainActor.run {
                    self.verifying = false
                    self.errorText = (error as? LocalizedError)?.errorDescription ?? "Verification failed"
                }
            }
        }
    }
}
