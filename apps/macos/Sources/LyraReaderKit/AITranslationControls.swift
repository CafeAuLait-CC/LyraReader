import Foundation
import SwiftUI

/// Display labels do not rewrite the language stored in a task or sent to Rust.
struct AITranslationLanguage: Identifiable {
    let value: String
    let code: String
    var id: String { value }
    static let options: [Self] = [
        Self(value: "English", code: "EN"), Self(value: "Simplified Chinese", code: "SC"),
        Self(value: "Traditional Chinese", code: "TC"), Self(value: "Japanese", code: "JP"),
        Self(value: "Korean", code: "KR"), Self(value: "French", code: "FR"),
        Self(value: "Spanish", code: "ES"), Self(value: "German", code: "DE")
    ]
    static func display(_ value: String) -> Self {
        if let option = options.first(where: { $0.value == value }) { return option }
        let locale = Locale(identifier: value)
        let code: String?
        switch locale.language.languageCode?.identifier {
        case "en": code = "EN"
        case "zh": code = locale.language.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(locale.region?.identifier) ? "TC" : "SC"
        case "ja": code = "JP"
        case "ko": code = "KR"
        case "fr": code = "FR"
        case "es": code = "ES"
        case "de": code = "DE"
        default: code = nil
        }
        if let option = options.first(where: { $0.code == code }) { return option }
        return Self(value: value, code: "…")
    }
}

struct AITranslationLanguagePicker: View {
    @Binding var language: String
    private var selected: AITranslationLanguage { .display(language) }
    private var choices: [AITranslationLanguage] {
        AITranslationLanguage.options.contains { $0.code == selected.code } ? AITranslationLanguage.options : [selected] + AITranslationLanguage.options
    }
    var body: some View {
        LyraReaderMenu(title: aiReadingLabel("Translate to"), items: choices.map { choice in
            LyraReaderMenuItem(aiReadingLabel(choice.value), icon: "character", selected: choice.code == selected.code) {
                language = choice.value
            }
        }) {
            HStack(spacing: 10) {
                Text(selected.code).font(.system(size: 13, weight: .medium).monospaced())
                Image(systemName: "chevron.down").font(.system(size: 11))
            }.frame(minWidth: 48, minHeight: 28)
                .padding(.horizontal, 8)
                .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LyraReaderTheme.controlBorder))
        }.accessibilityHint(aiReadingLabel(selected.value))
            .background(AITranslationControlProbe(id: "language"))
    }
}

/// Keep native Toggle accessibility and keyboard actions while drawing Lyra's checkbox.
struct LyraReadingCheckboxStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    @FocusState private var focused: Bool
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(configuration.isOn ?
                        (hovered && enabled ? LyraReaderTheme.accentHover : LyraReaderTheme.accent) : LyraReaderTheme.fieldBg)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(LyraReaderTheme.onAccent)
                    } else {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(LyraReaderTheme.controlBorder)
                    }
                }.frame(width: 14, height: 14)
                configuration.label.foregroundStyle(enabled ? LyraReaderTheme.textSecondary : LyraReaderTheme.textDisabled)
            }.contentShape(Rectangle()).padding(.vertical, 3)
        }.buttonStyle(.plain).focused($focused).focusEffectDisabled()
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(focused ? LyraReaderTheme.focusRing : .clear, lineWidth: 2).padding(-3))
            .opacity(enabled ? 1 : 0.45).onHover { hovered = $0 }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
            }
    }
}

/// Shared native segmented control for reading scopes and note ordering.
struct LyraReadingSegmentedPicker: View {
    let title: String
    @Binding var selection: Bool
    let first: String
    let second: String
    var firstIcon: String? = nil
    var secondIcon: String? = nil
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight
    @State private var hovered: Bool?
    @FocusState private var focused: Bool?

    var body: some View {
        HStack(spacing: 4) {
            segment(false, title: first, icon: firstIcon)
            segment(true, title: second, icon: secondIcon)
        }.padding(3)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LyraReaderTheme.controlBorder))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
            .accessibilityElement(children: .contain).accessibilityLabel(aiReadingLabel(title))
            .onMoveCommand { direction in
                if direction == .left { choose(false); focused = false }
                if direction == .right { choose(true); focused = true }
            }
    }
    private func choose(_ value: Bool) {
        selection = value
    }
    private func segment(_ value: Bool, title: String, icon: String?) -> some View {
        Button { choose(value) } label: {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon) }
                Text(aiReadingLabel(title)).lineLimit(1).minimumScaleFactor(0.8)
            }.font(.system(size: 13)).padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused, equals: value).focusEffectDisabled()
            .foregroundStyle(!enabled ? LyraReaderTheme.textDisabled : selection == value ? LyraReaderTheme.selectedFg : LyraReaderTheme.textPrimary)
            .background {
                if selection == value {
                    RoundedRectangle(cornerRadius: 6).fill(LyraReaderTheme.selectedBg)
                        .matchedGeometryEffect(id: "highlight", in: highlight).transition(.identity)
                } else if hovered == value && enabled {
                    RoundedRectangle(cornerRadius: 6).fill(LyraReaderTheme.hoverBg)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused == value ? LyraReaderTheme.focusRing : .clear, lineWidth: 2))
            .onHover { hovered = $0 ? value : nil }
            .accessibilityAddTraits(selection == value ? .isSelected : [])
            .background(AITranslationControlProbe(id: "segment-\(title)"))
    }
}
