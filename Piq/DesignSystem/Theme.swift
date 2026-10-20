import SwiftUI

/// Piq's "dark, photo-first" palette. The app runs in dark appearance only. With Increase
/// Contrast on, muted text and hairlines are brighter.
enum Palette {
    /// App background.
    static let ground = Color(hex: 0x0E0E0D)
    /// Panels and sheets.
    static let panel = Color(hex: 0x191817)
    /// Raised surfaces: tiles, chips, toasts.
    static let raised = Color(hex: 0x23211F)
    static let hairline = Color(hex: 0x2F2C29, increasedContrast: 0x4D4944)
    static let hairlineStrong = Color(hex: 0x3A3733, increasedContrast: 0x5E5953)
    static let text = Color(hex: 0xF4F1EB)
    static let textMuted = Color(hex: 0xA9A39A, increasedContrast: 0xCDC7BE)
    /// Text on off-white and solid coral fills.
    static let ink = Color(hex: 0x121110)
    static let coral = Color(hex: 0xFF7A59)
    static let coralLabel = Color(hex: 0xFF9A80)
    static let sky = Color(hex: 0x7CC4FF)
    static let skyLabel = Color(hex: 0x9CD2FF)
}

/// A tinted treatment (Delete coral, Keep sky blue): 12% fill, 50% border, light label.
struct Tint: Sendable {
    let base: Color
    let label: Color

    var fill: Color { base.opacity(0.12) }
    var border: Color { base.opacity(0.5) }

    static let coral = Tint(base: Palette.coral, label: Palette.coralLabel)
    static let sky = Tint(base: Palette.sky, label: Palette.skyLabel)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// `hex`, or `increasedContrast` while Increase Contrast is on.
    init(hex: UInt32, increasedContrast: UInt32) {
        self.init(uiColor: UIColor { traits in
            let value = traits.accessibilityContrast == .high ? increasedContrast : hex
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Bold Text. SwiftUI applies it to the system font only, so the type scale follows it itself:
/// while it is on, every style uses the next heavier face. Views that read a style re-render
/// when it changes.
@MainActor
@Observable
final class BoldTextSetting {
    static let shared = BoldTextSetting()

    /// Follows the system setting; previews and tests can set it.
    var isOn = UIAccessibility.isBoldTextEnabled
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: UIAccessibility.boldTextStatusDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                BoldTextSetting.shared.isOn = UIAccessibility.isBoldTextEnabled
            }
        }
    }
}

/// Bundled typefaces (SIL Open Font License): Bricolage Grotesque for the wordmark, titles and
/// big numbers; Hanken Grotesk for everything else. Hanken's figures are tabular by default, so
/// counters like "38 of 400" don't jitter. Every style scales with Dynamic Type and follows Bold
/// Text (see `BoldTextSetting`).
@MainActor
extension Font {
    enum DisplayWeight {
        case semibold
        case bold
    }

    enum TextWeight {
        case regular
        case medium
        case semibold
        case bold

        /// The face Bold Text uses instead.
        var heavier: TextWeight {
            switch self {
            case .regular, .medium: .semibold
            case .semibold, .bold: .bold
            }
        }
    }

    /// Bricolage Grotesque. From 24pt up it uses the 36pt optical cut, which is tighter and made
    /// for display sizes.
    static func display(_ size: CGFloat, _ weight: DisplayWeight = .semibold, relativeTo style: TextStyle = .title) -> Font {
        let family = size >= 24 ? "BricolageGrotesque36pt" : "BricolageGrotesque"
        let face = weight == .bold || BoldTextSetting.shared.isOn ? "Bold" : "SemiBold"
        return .custom("\(family)-\(face)", size: size, relativeTo: style)
    }

    /// Hanken Grotesk.
    static func text(_ size: CGFloat, _ weight: TextWeight = .regular, relativeTo style: TextStyle = .body) -> Font {
        let face = switch BoldTextSetting.shared.isOn ? weight.heavier : weight {
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "SemiBold"
        case .bold: "Bold"
        }
        return .custom("HankenGrotesk-\(face)", size: size, relativeTo: style)
    }

    // MARK: Type scale

    static var wordmark: Font { display(30, .bold) }
    /// "Which album are we sorting?", "Review".
    static var screenTitle: Font { display(42, relativeTo: .largeTitle) }
    /// Review stats.
    static var statNumber: Font { display(46, relativeTo: .largeTitle) }
    /// Confirm sheet and empty-state titles.
    static var dialogTitle: Font { display(28) }
    /// "Delete" / "Keep" on the swipe overlay.
    static var overlayLabel: Font { display(34, .bold) }
    /// Album name in the top bar.
    static var barTitle: Font { display(18, relativeTo: .headline) }
    /// Subtitles and body copy.
    static var lead: Font { text(17) }
    static var buttonLabel: Font { text(16, .semibold) }
    static var largeButtonLabel: Font { text(18, .semibold) }
    static var tileTitle: Font { text(16, .semibold) }
    /// Counts and secondary lines ("400 photos", "38 of 400").
    static var meta: Font { text(14, .medium, relativeTo: .subheadline) }
    static var hint: Font { text(13, .medium, relativeTo: .footnote) }
    static var statLabel: Font { text(13, .medium, relativeTo: .footnote) }
    static var chip: Font { text(12, .semibold, relativeTo: .caption) }
    static var badge: Font { text(13, .bold, relativeTo: .caption) }
    static var toast: Font { text(15, .semibold, relativeTo: .subheadline) }
}

/// Layout constants from the design (landscape 1194×834), shared across screens.
enum Metrics {
    static let topBarHeight: CGFloat = 76
    static let barPadding: CGFloat = 20
    /// Space a top bar keeps between its center and each side.
    static let topBarSpacing: CGFloat = 12
    /// Horizontal page margin at full width.
    static let pageMargin: CGFloat = 40
    static let hairline: CGFloat = 1
    static let photoCorner: CGFloat = 14
    static let tileCorner: CGFloat = 14
    static let thumbCorner: CGFloat = 12
    static let thumbGap: CGFloat = 12
    static let minTouch: CGFloat = 44
    static let albumCoverHeight: CGFloat = 172
    static let progressWidth: CGFloat = 260
    static let actionButtonHeight: CGFloat = 56
    static let largeButtonHeight: CGFloat = 56

    // Swipe
    /// Drag distance at which a swipe commits and the overlay reaches full strength.
    static let swipeThreshold: CGFloat = 140
    static let maxOverlayOpacity: Double = 0.85
    /// rotation (degrees) = horizontal drag / 28.
    static let tiltDivisor: CGFloat = 28
    static let flyOffDuration: Double = 0.26
    /// The next photo peeking out behind the current one.
    static let stackScale: CGFloat = 0.93
    static let stackOffset: CGFloat = 18
    static let stackOpacity: Double = 0.35

    static let toastDuration: Duration = .milliseconds(2200)

    /// Album grid: 4 columns at full landscape width, 3 in portrait, 2 in narrow Split View.
    static func albumColumns(forWidth width: CGFloat) -> Int {
        width >= 1000 ? 4 : width >= 640 ? 3 : 2
    }

    /// Review grid: 6 columns in landscape, 4 in portrait and Split View, 3 when very narrow.
    static func reviewColumns(forWidth width: CGFloat) -> Int {
        width >= 1000 ? 6 : width >= 480 ? 4 : 3
    }

    /// How far a top bar's leading content moves in from `barPadding` to clear window controls
    /// `windowControlsWidth` wide (iPadOS 26 windows).
    static func topBarLeadingInset(clearing windowControlsWidth: CGFloat) -> CGFloat {
        max(0, windowControlsWidth - barPadding)
    }

    /// Page margin that shrinks in narrow windows.
    static func pageMargin(forWidth width: CGFloat) -> CGFloat {
        width >= 900 ? pageMargin : width >= 500 ? 28 : 16
    }

    /// The largest size with `aspectRatio` (width / height) that fits in `box`.
    static func fit(aspectRatio: CGFloat, in box: CGSize) -> CGSize {
        guard aspectRatio > 0, box.width > 0, box.height > 0 else { return .zero }
        if box.width / box.height > aspectRatio {
            return CGSize(width: (box.height * aspectRatio).rounded(), height: box.height.rounded())
        }
        return CGSize(width: box.width.rounded(), height: (box.width / aspectRatio).rounded())
    }
}

extension SwipeAction {
    var tint: Tint {
        switch self {
        case .delete: .coral
        case .keep: .sky
        }
    }

    /// Solid color for the swipe overlay.
    var overlayColor: Color { tint.base }

    /// ← for actions bound to a left swipe, → for right.
    var keyEquivalent: KeyEquivalent { direction == .left ? .leftArrow : .rightArrow }

    /// "← Delete", "Keep →": the arrow points the way the photo goes.
    var buttonTitle: String { direction == .left ? "← \(title)" : "\(title) →" }
}
