import Foundation
import Observation
import PVEKit
import SwiftUI

/// User preferences (Settings › 通用 / 外观 / 安全), stored in the app's own `UserDefaults`.
/// Demo mode uses a throw-away suite so screenshots never change real settings.
@MainActor
@Observable
final class AppSettings {
    enum AutoRefresh: Int, CaseIterable, Identifiable {
        case seconds5 = 5
        case seconds10 = 10
        case seconds30 = 30
        case seconds60 = 60
        case off = 0

        var id: Int { rawValue }

        /// nil when automatic refresh is off.
        var interval: Duration? {
            self == .off ? nil : .seconds(rawValue)
        }

        var title: String {
            switch self {
            case .off: return String(localized: "关闭")
            default: return String(localized: "\(rawValue) 秒")
            }
        }
    }

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        var title: String {
            switch self {
            case .system: return String(localized: "跟随系统")
            case .light: return String(localized: "浅色")
            case .dark: return String(localized: "深色")
            }
        }
    }

    private enum Key {
        static let autoRefresh = "settings.autoRefresh"
        static let chartTimeframe = "settings.chartTimeframe"
        static let theme = "settings.theme"
        static let accent = "settings.accent"
        static let faceID = "settings.faceIDLock"
        static let confirmDangerous = "settings.confirmDangerousActions"
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after the accent changes (the widget variant mirrors it into the App Group).
    @ObservationIgnored var onAccentChange: ((AccentPreset) -> Void)?

    var autoRefresh: AutoRefresh {
        didSet { defaults.set(autoRefresh.rawValue, forKey: Key.autoRefresh) }
    }

    var chartTimeframe: RRDTimeframe {
        didSet { defaults.set(chartTimeframe.rawValue, forKey: Key.chartTimeframe) }
    }

    var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    var accent: AccentPreset {
        didSet {
            defaults.set(accent.rawValue, forKey: Key.accent)
            onAccentChange?(accent)
        }
    }

    /// Face ID / passcode lock on cold launch and after more than 5 minutes in the background.
    var faceIDLock: Bool {
        didSet { defaults.set(faceIDLock, forKey: Key.faceID) }
    }

    /// Confirm shutdown, reboot, force stop and suspend. (Snapshot rollback and delete always ask.)
    var confirmDangerousActions: Bool {
        didSet { defaults.set(confirmDangerousActions, forKey: Key.confirmDangerous) }
    }

    init(defaults: UserDefaults? = nil) {
        let store: UserDefaults
        if let defaults {
            store = defaults
        } else if DemoMode.isEnabled {
            let name = "org.sketchain.chelate.demo-settings"
            UserDefaults().removePersistentDomain(forName: name)
            store = UserDefaults(suiteName: name) ?? .standard
        } else {
            store = .standard
        }
        self.defaults = store
        autoRefresh = AutoRefresh(rawValue: store.object(forKey: Key.autoRefresh) as? Int ?? AutoRefresh.seconds10.rawValue) ?? .seconds10
        chartTimeframe = store.string(forKey: Key.chartTimeframe).flatMap(RRDTimeframe.init(rawValue:)) ?? .hour
        theme = store.string(forKey: Key.theme).flatMap(Theme.init(rawValue:)) ?? .system
        accent = store.string(forKey: Key.accent).flatMap(AccentPreset.init(rawValue:)) ?? .orange
        faceIDLock = store.object(forKey: Key.faceID) as? Bool ?? false
        confirmDangerousActions = store.object(forKey: Key.confirmDangerous) as? Bool ?? true
    }

    /// Whether a power action needs a confirmation dialog.
    func needsConfirmation(_ action: PowerAction) -> Bool {
        guard confirmDangerousActions else { return false }
        switch action {
        case .shutdown, .reboot, .stop, .suspend: return true
        case .start, .resume: return false
        }
    }
}

extension RRDTimeframe {
    var title: String {
        switch self {
        case .hour: return String(localized: "时")
        case .day: return String(localized: "天")
        case .week: return String(localized: "周")
        case .month: return String(localized: "月")
        case .year: return String(localized: "年")
        }
    }
}
