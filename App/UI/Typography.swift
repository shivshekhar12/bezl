import AppKit
import CoreText
import SwiftUI

/// Bezl's typeface: Figtree (SIL Open Font License, bundled in Resources/Fonts).
/// A free geometric sans close in feel to Spotify's proprietary typeface, which can't be shipped.
enum BezlFont {
    static let family = "Figtree"

    /// Registers the bundled font for this process (no install, no admin rights).
    static func register() {
        guard let url = Bundle.main.url(forResource: "Figtree", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static var isAvailable: Bool { NSFont(name: family, size: 12) != nil }
}

extension Font {
    /// Figtree at a fixed size (falls back to the system font if it failed to load).
    static func bezl(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        BezlFont.isAvailable ? .custom(BezlFont.family, fixedSize: size).weight(weight)
                             : .system(size: size, weight: weight)
    }

    // Semantic sizes matching the macOS text styles used across the UI.
    static var bezlTitle2: Font { bezl(22, .bold) }
    static var bezlTitle3: Font { bezl(20, .semibold) }
    static var bezlHeadline: Font { bezl(13.5, .bold) }
    static var bezlSubheadline: Font { bezl(11.5) }
    static var bezlCallout: Font { bezl(12.5) }
    static var bezlCaption: Font { bezl(11.5) }
    static var bezlCaption2: Font { bezl(10.5) }
}
