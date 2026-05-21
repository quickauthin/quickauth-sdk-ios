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
                GroupBox("Headless mode") {
                    VStack(spacing: 12) {
                        Button("1. Send OTP") {
                            Task {
                                do {
                                    let s = try await QuickAuth.shared.auth.startOTP(phone: phone)
                                    sessionId = s.sessionId
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
                                    let r = try await QuickAuth.shared.auth.verifyOTP(
                                        sessionId: sessionId, code: code)
                                    jwt = r.jwt; error = ""
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                        .disabled(sessionId.isEmpty || code.count < 6)
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
