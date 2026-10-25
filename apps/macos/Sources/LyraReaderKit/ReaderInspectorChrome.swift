import AppKit
import SwiftUI

/// The metrics every right-hand tool inspector shares.
///
/// Content Edit and Fill & Sign used to repeat the same scaffolding - a 16 pt header inset, a
/// 22 pt section spacing, a 16 pt body/footer inset and a 292 pt column - in two files. Keeping
/// the numbers here means a tool's options are content, not a third copy of the host.
public enum ReaderInspectorMetrics {
    /// The column width. It is the same number the row's trailing inset and the transition use.
    public static var width: CGFloat { ReaderChrome.editingPanelWidthPt }
    public static let horizontalPadding: CGFloat = 16
    public static let headerVerticalPadding: CGFloat = 9
    public static let bodySpacing: CGFloat = 22
    public static let bodyPadding: CGFloat = 16
    public static let footerSpacing: CGFloat = 8
    public static let emptyStateSpacing: CGFloat = 12
    public static let emptyStateVerticalPadding: CGFloat = 34
    public static let titleSize: CGFloat = 13
}

/// The one right-hand inspector host.
///
/// Both tool inspectors use it: a title (and optional subtitle), a close button, a scrolling body
/// whose content is the armed tool's options, and a footer. The host owns the column width,
/// padding, section spacing, separators, background, leading edge and disabled state; the
/// inspector files own only their options. This is the inspector counterpart of
/// ``ReaderSecondaryRow``: no inspector brings its own scaffold or metrics.
struct ReaderInspectorHost<Body: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    let closeAccessibilityLabel: String
    var closeHelp: String? = nil
    let close: () -> Void
    let marker: ReaderChromeMarkerView.Kind
    var isBusy: Bool = false
    @ViewBuilder var bodyContent: () -> Body
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: ReaderInspectorMetrics.titleSize, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(LyraReaderTheme.textSecondary)
                    }
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(LyraReaderToolStyle())
                    .accessibilityLabel(closeAccessibilityLabel)
                    .help(closeHelp ?? closeAccessibilityLabel)
            }
            .padding(.horizontal, ReaderInspectorMetrics.horizontalPadding)
            .padding(.vertical, ReaderInspectorMetrics.headerVerticalPadding)
            Divider().overlay(LyraReaderTheme.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: ReaderInspectorMetrics.bodySpacing) {
                    bodyContent()
                }
                .padding(ReaderInspectorMetrics.bodyPadding)
            }
            Divider().overlay(LyraReaderTheme.separator)
            footer()
                .padding(ReaderInspectorMetrics.bodyPadding)
        }
        .frame(width: ReaderInspectorMetrics.width)
        .frame(maxHeight: .infinity)
        .background(ReaderChromeMarkerHost(kind: marker))
        .background(LyraReaderTheme.panelBg)
        .overlay(alignment: .leading) { LyraReaderTheme.separator.frame(width: 1) }
        .foregroundStyle(LyraReaderTheme.textPrimary)
        .textFieldStyle(ReaderPanelFieldStyle())
        .buttonStyle(ReaderPanelButtonStyle())
        .disabled(isBusy)
    }
}

/// The inspector footer's vertical rhythm, shared by both inspectors.
struct ReaderInspectorFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: ReaderInspectorMetrics.footerSpacing) {
            content()
        }
    }
}

/// The "nothing selected / choose a tool" state both inspectors show before a tool has options.
struct ReaderInspectorEmptyState: View {
    let icon: String
    let message: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: ReaderInspectorMetrics.emptyStateSpacing) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(LyraReaderTheme.iconSecondary)
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(LyraReaderTheme.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, ReaderInspectorMetrics.emptyStateVerticalPadding)
    }
}
