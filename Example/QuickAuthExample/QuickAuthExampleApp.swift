//
//  QuickAuthExampleApp.swift
//  Sample SwiftUI app demonstrating both component-mode and headless-mode SDK usage.
//

import SwiftUI
import QuickAuth

@main
struct QuickAuthExampleApp: App {

    init() {
        QuickAuth.shared.initialize(publicKey: "qa_pk_live_replace_me")
        QuickAuth.shared.consent.set(true) // production: prompt the user first.
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    Task {
                        _ = try? await QuickAuth.shared.attribution.captureLaunch(url: url)
                    }
                }
        }
    }
}
