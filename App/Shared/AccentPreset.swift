import SwiftUI

/// The five accent colour presets (Settings › 外观). Shared with the widget extension, which
/// reads the choice from the App Group mirror.
enum AccentPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case orange, blue, green, purple, pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .orange: return .orange
        case .blue: return .blue
        case .green: return .green
        case .purple: return .purple
        case .pink: return .pink
        }
    }

    var title: String {
        switch self {
        case .orange: return String(localized: "橙")
        case .blue: return String(localized: "蓝")
        case .green: return String(localized: "绿")
        case .purple: return String(localized: "紫")
        case .pink: return String(localized: "粉")
        }
    }

    /// End colour of the home title gradient: pink, or orange when the accent itself is pink.
    var gradientEnd: Color {
        self == .pink ? .orange : .pink
    }
}

extension EnvironmentValues {
    /// The app's accent colour (Settings › 外观 › 强调色). Use it where `Color.accentColor`
    /// would only ever give the asset catalog colour.
    @Entry var chelateAccent: Color = AccentPreset.orange.color
}
