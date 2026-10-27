import AppKit
import SwiftUI

/// One resolved button font: the size and weight a label actually applies.
public struct ReaderResolvedTypography: Equatable {
    public let size: CGFloat
    public let weight: Font.Weight

    public init(size: CGFloat, weight: Font.Weight) {
        self.size = size
        self.weight = weight
    }
}

/// The typography of a toolbar button, shared by the primary toolbar and every secondary row.
///
/// The sizes are deliberately swapped relative to the first implementation: the primary toolbar
/// keeps the larger 14 pt label the rows used to render, at medium weight; the rows use the
/// primary toolbar's old 12 pt at regular weight. Icons are 14 pt medium everywhere - the
/// primary toolbar's SF Symbol size and the annotation row's existing icon scale.
///
/// A label must apply these through ``ReaderToolbarLabel``/``ReaderToolbarFont`` *inside* the
/// button style. The rows used to set a font on the `HStack` around their buttons, which the
/// style's font overrode, so they drifted to the icon size (14 pt) while the main toolbar kept
/// its 12 pt labels.
public enum ReaderToolbarTypography {
    /// The primary toolbar's button-label size and weight.
    public static let mainLabelSize: CGFloat = 14
    public static let mainLabelWeight: Font.Weight = .medium

    /// Every secondary sub-toolbar row's label size and weight.
    public static let rowLabelSize: CGFloat = 12
    public static let rowLabelWeight: Font.Weight = .regular

    /// The point size of a toolbar icon. The annotation row and the primary toolbar's SF
    /// Symbols both resolved at this size before the change; all rows keep it.
    public static let iconSize: CGFloat = 14
    public static let iconWeight: Font.Weight = .medium

    /// The square every secondary-row icon occupies.
    ///
    /// SF Symbols at 14 pt have different intrinsic boxes, and the Interleaf / Translation
    /// vectors bring their own 24 pt view box. Left intrinsic, those boxes differ and make one
    /// glyph read smaller than its neighbours. Every row icon is given this one square instead,
    /// so the item's icon height and vertical centre no longer depend on the glyph.
    public static let iconFrameSize: CGFloat = 18

    /// Gap between a button's icon and its text, and the label's own horizontal padding.
    public static let labelIconSpacing: CGFloat = 5
    public static let labelHorizontalPadding: CGFloat = 7

    public static var mainLabelFont: Font {
        .system(size: mainLabelSize, weight: mainLabelWeight)
    }

    public static var rowLabelFont: Font {
        .system(size: rowLabelSize, weight: rowLabelWeight)
    }

    public static var iconFont: Font {
        .system(size: iconSize, weight: iconWeight)
    }
}

/// Applies one of the two label fonts and reports it to the checks.
///
/// The report is what makes the typography a measured contract instead of a comment: the main
/// toolbar and every row host the same probe, and the check compares the resolved values.
struct ReaderToolbarFont: ViewModifier {
    enum Role: String {
        case main
        case row

        var size: CGFloat {
            switch self {
            case .main: ReaderToolbarTypography.mainLabelSize
            case .row: ReaderToolbarTypography.rowLabelSize
            }
        }

        var weight: Font.Weight {
            switch self {
            case .main: ReaderToolbarTypography.mainLabelWeight
            case .row: ReaderToolbarTypography.rowLabelWeight
            }
        }
    }

    let id: String
    let role: Role
    @Environment(\.readerTypographyProbe) private var probe

    func body(content: Content) -> some View {
        content
            .font(.system(size: role.size, weight: role.weight))
            .onAppear {
                probe?.report(id, ReaderResolvedTypography(size: role.size, weight: role.weight))
            }
    }
}

/// One secondary-row icon: the shared symbol configuration in the shared square frame.
///
/// Applying this in one place is what keeps an SF Symbol and a custom vector glyph on the same
/// baseline. The frame reader reports the square, not the symbol's intrinsic bounds, so the
/// checks can prove every item in every row has the same icon height and vertical centre.
struct ReaderToolbarIcon: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content
            .font(ReaderToolbarTypography.iconFont)
            .symbolRenderingMode(.monochrome)
            .frame(width: ReaderToolbarTypography.iconFrameSize,
                   height: ReaderToolbarTypography.iconFrameSize)
            .background(AnnotationToolbarFrameReader(id: id))
    }
}

/// One toolbar button's text and icon, shared by all five rows.
///
/// `Label` gives the icon the text's font (12 pt row label), which would make a row icon smaller
/// than the annotation row's 14 pt icon; the two are laid out explicitly instead. Every icon goes
/// through ``ReaderToolbarIcon`` so its height does not depend on the glyph. The frame readers
/// let the checks compare the actual rendered label height and icon box with the main toolbar.
struct ReaderToolbarLabel<Icon: View>: View {
    let title: String
    var id: String
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: ReaderToolbarTypography.labelIconSpacing) {
            icon()
                .modifier(ReaderToolbarIcon(id: "\(id).icon"))
            Text(title)
                .modifier(ReaderToolbarFont(id: "\(id).label", role: .row))
                .background(AnnotationToolbarFrameReader(id: "\(id).label"))
        }
        .padding(.horizontal, ReaderToolbarTypography.labelHorizontalPadding)
    }
}

/// A probe-only sample rendered with each role's typography.
///
/// It draws the same string and symbol in the main toolbar and in each row host, so the checks
/// compare the *resolved* text size and icon box rather than a token: a host that resolves a
/// different font or symbol size reports a different frame. Invisible and zero-impact in the
/// app; only built when a frame probe is installed by the checks.
struct ReaderTypographySample: View {
    let role: ReaderToolbarFont.Role
    @Environment(\.annotationToolbarFrameProbe) private var probe

    var body: some View {
        if probe != nil {
            HStack(spacing: 0) {
                Text("Lyra")
                    .modifier(ReaderToolbarFont(id: "typography.font", role: role))
                    .fixedSize()
                    .background(AnnotationToolbarFrameReader(id: "typography.label"))
                Image(systemName: "highlighter")
                    .font(ReaderToolbarTypography.iconFont)
                    .fixedSize()
                    .background(AnnotationToolbarFrameReader(id: "typography.icon"))
            }
            .fixedSize()
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }
}
