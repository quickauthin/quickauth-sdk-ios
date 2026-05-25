//
//  ContentView.swift
//

import SwiftUI
import QuickAuth

struct ContentView: View {

    @State private var phone: String = "+919876543210"
    @State private var jwt: String = ""
    @State private var error: String = ""

    // Headless-mode state
    @State private var sessionId: String = ""
    @State private var code: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                Text("QuickAuth iOS SDK")
                    .font(.title2.bold())

                // -------- Component mode --------
                GroupBox("Component mode") {
                    VStack(spacing: 12) {
                        TextField("Phone (E.164)", text: $phone)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.phonePad)

                        QuickAuthLoginButton(
                            phone: phone,
                            onSuccess: { token in jwt = token; error = "" },
                            onError:   { err in error = err.localizedDescription }
                        )

                        Button("Login with WhatsApp") {
                            QuickAuth.shared.auth.startWhatsAppLogin(
                                businessNumber: "+919574980048",
                                returnURL: URL(string: "https://app.example.com/wa-return")
                            )
                        }
                    }.padding(.vertical, 4)
                }

                // -------- Headless mode --------
                // The headless flow drives the UI through `onAuthEvent`,
                // configured at app launch. Buttons here just kick the
                // state machine; events update `sessionId` / `jwt` / `error`.
                GroupBox("Headless mode") {
                    VStack(spacing: 12) {
                        Button("1. Send OTP") {
                            Task {
                                do {
                                    try await QuickAuth.shared.auth.initiate(phone: phone)
                                    error = ""
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                        QuickAuthOtpField(code: $code)
                        Button("2. Verify") {
                            Task {
                                do {
                                    try await QuickAuth.shared.auth.submitOtp(code)
                                    error = ""
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                        .disabled(code.count < 6)
                    }.padding(.vertical, 4)
                }

                if !jwt.isEmpty {
                    Text("JWT: \(jwt)").font(.footnote).foregroundColor(.green)
                }
                if !error.isEmpty {
                    Text(error).font(.footnote).foregroundColor(.red)
                }
            }
            .padding(20)
        }
    }
}
