//
//  BrandTheme.swift
//  Brand color tokens — mirrors quickauth-website tokens.css.
//

import SwiftUI

public extension Color {
    /// Accent green `#00C637`.
    static let qaAccent = Color(red: 0x00 / 255.0, green: 0xC6 / 255.0, blue: 0x37 / 255.0)
    /// Hover/pressed deeper accent `#00A82F`.
    static let qaAccentDeep = Color(red: 0x00 / 255.0, green: 0xA8 / 255.0, blue: 0x2F / 255.0)
    /// Ink black `#0A0A0A`.
    static let qaInk = Color(red: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0A / 255.0)
    /// Mist/border `#E6E6E6`.
    static let qaMist = Color(red: 0xE6 / 255.0, green: 0xE6 / 255.0, blue: 0xE6 / 255.0)
    /// Subtle text `#6B7280`.
    static let qaMuted = Color(red: 0x6B / 255.0, green: 0x72 / 255.0, blue: 0x80 / 255.0)
}

/// `[Q]` mono badge view used inside the brand button.
public struct QuickAuthBadge: View {
    public init() {}
    public var body: some View {
        Text("[Q]")
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
    }
}
