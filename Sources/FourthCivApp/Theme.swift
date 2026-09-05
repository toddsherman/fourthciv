import SwiftUI

enum Palette {
    static let paper = Color(red: 0.933, green: 0.914, blue: 0.871)
    static let card = Color(red: 0.985, green: 0.977, blue: 0.953)
    static let ink = Color(red: 0.157, green: 0.204, blue: 0.184)
    static let muted = Color(red: 0.345, green: 0.380, blue: 0.357)
    static let night = Color(red: 0.063, green: 0.098, blue: 0.122)
    static let sidebar = Color(red: 0.047, green: 0.078, blue: 0.098)
    static let ivory = Color(red: 0.945, green: 0.925, blue: 0.875)
    static let mist = Color(red: 0.714, green: 0.741, blue: 0.733)
    static let gold = Color(red: 0.929, green: 0.765, blue: 0.545)
    // Bronze stays readable on paper; gold is reserved for dark surfaces.
    static let accent = Color(red: 0.478, green: 0.322, blue: 0.165)
    static let orange = Color(red: 0.604, green: 0.322, blue: 0.153)
    static let online = Color(red: 0.376, green: 0.533, blue: 0.443)
    static let line = ink.opacity(0.14)
}

struct CivSeal: View {
    var compact = false
    var onDark = true
    var body: some View {
        Text("IV")
            .font(.custom("Georgia", size: compact ? 17 : 22))
            .tracking(-2)
            .padding(.trailing, 2)
            .frame(width: compact ? 31 : 40, height: compact ? 36 : 46)
            .foregroundStyle(onDark ? Palette.gold : Palette.accent)
            .overlay(Rectangle().stroke((onDark ? Palette.gold : Palette.accent).opacity(0.6), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct RefugeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .foregroundStyle(Palette.night)
            .background(Palette.gold.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct SheetHeading: View {
    let title: String
    let eyebrow: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            CivSeal(compact: true, onDark: false)
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(1.4).foregroundStyle(Palette.accent)
                Text(title).font(.custom("Georgia", size: 25)).foregroundStyle(Palette.ink)
            }
            Spacer(minLength: 12)
            Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
        }.padding(.bottom, 6)
    }
}
