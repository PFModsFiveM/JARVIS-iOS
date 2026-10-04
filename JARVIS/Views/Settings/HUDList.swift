import SwiftUI
import UIKit

// MARK: - The list idiom
//
// Every settings surface is a native `List`, and that is a deliberate correction rather than a
// change of taste.
//
// The old Settings page was one hand-built `ScrollView` holding a `VStack` of decorative panels. It
// scrolled only when the drag started on the scroll indicator, and the reason was a pair of
// `.textSelection(.enabled)` modifiers applied to *containers* - a `VStack` of connection-log lines
// and the list of addresses the PC had offered. Selectable text installs a UIKit text interaction on
// every `Text` it covers, and that interaction claims a drag that begins inside it; the enclosing
// scroller never sees the gesture. Those two blocks are full width and grow with use, so on a phone
// that had been connected a few times they covered most of the page, and the only surface left that
// would pan was the indicator itself.
//
// A native `List` owns its pan gesture through UIKit rather than competing with its own children for
// it, enforces one row height and one separator, and gives search, drill-down and keyboard
// avoidance for nothing. The panels remain as a look - HUD panel fill, hairline separators, the one
// cyan - but the scrolling is the system's.
//
// The accompanying rule, and the one that actually prevents the bug returning: selection goes on a
// single `Text` that the owner would want to copy, never on a container. `CopyableValue` below is
// the way to offer a value for copying, and it has a button, which is what people reach for anyway.

extension View {
    /// A `List` dressed as the HUD: no system grouped background, the backdrop behind it, HUD tint.
    func hudList() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(HUDBackdrop().ignoresSafeArea())
            .tint(HUD.accent)
            .foregroundStyle(HUD.text)
    }

    /// Panel fill and hairline separator for one row. Applied by the row types below, so a page
    /// never has to remember it.
    func hudRow() -> some View {
        listRowBackground(HUD.panel.opacity(0.55))
            .listRowSeparatorTint(HUD.line)
    }

    /// A row that *is* a panel: no row fill, no insets, no separator, for a page whose content is
    /// an existing `HUDFrame` rather than a row. The frame draws its own edge, so the list must not
    /// draw a second one round it.
    func hudPanelRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
    }
}

/// A section header in the HUD's type.
struct HUDSectionTitle: View {
    let text: String
    var tint: Color = HUD.accentDeep

    var body: some View {
        HUDLabel(text: text, color: tint)
            .padding(.bottom, 2)
    }
}

/// Explanatory prose under a group. The old page's footnotes, kept word for word where they were
/// already right - they are most of what makes this app explain itself.
struct SettingsNote: View {
    let text: String
    let colour: Color

    init(_ text: String, colour: Color = HUD.dim) {
        self.text = text
        self.colour = colour
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Status
//
// §21. *Configured* and *available right now* are two different facts, and the old page ran them
// together: a phone with a SwitchBot token read the same whether the Hub was reachable or not, and
// a PC address that had been typed in read the same whether anything answered at it. A row says
// which of the two it means.

enum SettingsStatus: Equatable {
    /// Set up, and working at this moment.
    case live(String)
    /// Set up and believed good, but nothing is exercising it right now.
    case ready(String)
    /// Set up, and *not* reachable at this moment. The distinction §21 asks for.
    case configured(String)
    /// Not set up. Nothing is wrong; there is simply nothing there.
    case off(String)
    /// Set up and wants the owner's attention.
    case attention(String)
    /// Set up and failing.
    case fault(String)

    var text: String {
        switch self {
        case .live(let t), .ready(let t), .configured(let t), .off(let t), .attention(let t), .fault(let t): return t
        }
    }

    var colour: Color {
        switch self {
        case .live: return HUD.bright
        case .ready: return HUD.accent
        case .configured: return HUD.dim
        case .off: return HUD.dim
        case .attention: return HUD.amber
        case .fault: return HUD.alert
        }
    }

    /// A filled dot for something live, a hollow one for something merely set up. Shape as well as
    /// colour, so the difference survives a colour-blind eye and a glance.
    var filled: Bool {
        switch self {
        case .live, .attention, .fault: return true
        case .ready, .configured, .off: return false
        }
    }
}

struct StatusDot: View {
    let status: SettingsStatus

    var body: some View {
        Circle()
            .strokeBorder(status.colour, lineWidth: 1.2)
            .background(Circle().fill(status.filled ? status.colour : .clear))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

// MARK: - The six row kinds
//
// §20. One row system, so a toggle looks like a toggle on every page and a row that leads somewhere
// always looks like one. Nothing else in Settings builds its own row.

/// NAVIGATION. Leads to a page. Never does anything by itself.
struct NavigationRow: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var status: SettingsStatus?
    let destination: SettingsDestination

    var body: some View {
        NavigationLink(value: destination) {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(HUD.accent)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(HUD.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(HUD.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let status {
                    HStack(spacing: 6) {
                        StatusDot(status: status)
                        Text(status.text)
                            .font(.caption)
                            .foregroundStyle(status.colour)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .hudRow()
    }
}

/// TOGGLE. One switch, one fact.
struct ToggleRow: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: $isOn)
                .tint(HUD.accent)
                .foregroundStyle(HUD.text)
            if let note {
                Text(note).font(.caption).foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hudRow()
    }
}

/// VALUE. Read-only. A fact about this phone or the PC that the owner may want to read off.
struct ValueRow: View {
    let title: String
    let value: String
    var monospaced: Bool = true

    var body: some View {
        HStack {
            HUDLabel(text: title)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(HUD.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .hudRow()
    }
}

/// STATUS. Live state, named as live or merely configured.
struct StatusRow: View {
    let title: String
    let status: SettingsStatus

    var body: some View {
        HStack {
            HUDLabel(text: title)
            Spacer(minLength: 12)
            StatusDot(status: status)
            Text(status.text)
                .font(.footnote)
                .foregroundStyle(status.colour)
                .multilineTextAlignment(.trailing)
        }
        .hudRow()
    }
}

/// ACTION. Does something now, and can be done again.
struct ActionRow: View {
    let title: String
    var symbol: String?
    var note: String?
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: action) {
                HStack(spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 14)).frame(width: 20)
                    }
                    Text(title)
                    Spacer()
                }
            }
            .foregroundStyle(disabled ? HUD.dim : HUD.accent)
            .disabled(disabled)
            if let note {
                Text(note).font(.caption).foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hudRow()
    }
}

/// DANGER. Cannot be taken back. The one place red is allowed outside the Security Protocol.
struct DangerRow: View {
    let title: String
    var note: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(role: .destructive, action: action) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 14)).frame(width: 20)
                    Text(title)
                    Spacer()
                }
            }
            .foregroundStyle(HUD.alert)
            if let note {
                Text(note).font(.caption).foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hudRow()
    }
}

/// A value the owner may need to get off the phone - an ntfy topic, a key fingerprint, an address.
///
/// Selection is on this one `Text` and nowhere else, and there is a button beside it, because that
/// is what people actually use. Putting `.textSelection(.enabled)` on the enclosing stack is what
/// stopped the old page scrolling; see the note at the top of this file.
struct CopyableValue: View {
    let title: String
    let value: String
    var toast: String?

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HUDLabel(text: title)
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(HUD.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                UIPasteboard.general.string = value
                model.toast = toast ?? "\(title) copied."
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(HUD.accent)
        }
        .hudRow()
    }
}

/// A block of machine-written lines - a connection log, a diagnostic trace.
///
/// Not selectable. The whole block copies with the button, which is both what the owner wants and
/// the reason this page scrolls: a selectable multi-line block inside a scroller takes the drag.
struct LogBlock: View {
    let title: String
    let lines: [String]

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HUDLabel(text: title)
                Spacer()
                Button {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                    model.toast = "\(title) copied."
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(HUD.accent)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(HUD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .hudRow()
    }
}

/// A text box in the HUD's style, for a page that has to take typing.
struct HUDField: View {
    let prompt: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var secure: Bool = false

    var body: some View {
        Group {
            if secure {
                SecureField(prompt, text: $text)
            } else {
                TextField(prompt, text: $text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(keyboard)
        .foregroundStyle(HUD.text)
        .padding(9)
        .background(HUD.background)
        .overlay(Rectangle().stroke(HUD.accent.opacity(0.4), lineWidth: 1))
    }
}
