import Foundation

/// Byte sizes in binary units labelled like the PVE web UI (`KiB`, `MiB`, `GiB`, `TiB`).
public enum ByteFormat {
    public static let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]

    /// `0` → `"0"`, `512` → `"512 B"`, `1536` → `"1.50 KiB"`, `13421772800` → `"12.5 GiB"`.
    public static func string(_ bytes: Double) -> String {
        guard bytes.isFinite else { return "–" }
        if bytes == 0 { return "0" }
        let negative = bytes < 0
        var value = abs(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let number: String
        if index == 0 {
            number = String(Int(value.rounded()))
        } else {
            number = trimmed(value)
        }
        return (negative ? "-" : "") + number + " " + units[index]
    }

    /// Three significant digits at most: `1.50`, `12.5`, `512`.
    static func trimmed(_ value: Double) -> String {
        let decimals = value < 10 ? 2 : (value < 100 ? 1 : 0)
        return String(format: "%.\(decimals)f", value)
    }

    /// Axis label for a value that is a multiple of `unit` (1024^k): no superfluous decimals.
    public static func axisLabel(_ bytes: Double, unitIndex: Int) -> String {
        if bytes == 0 { return "0" }
        let unit = pow(1024, Double(unitIndex))
        let value = bytes / unit
        let text: String
        if value.rounded() == value {
            text = String(Int(value))
        } else if (value * 10).rounded() == value * 10 {
            text = String(format: "%.1f", value)
        } else {
            text = String(format: "%.2f", value)
        }
        return text + " " + units[min(unitIndex, units.count - 1)]
    }
}

/// Evenly spaced axis ticks with round step sizes.
public struct NiceScale: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Fractions 0…1 shown as percent; steps are round percentages.
        case fraction
        /// Bytes (or bytes per second); steps are round numbers of a binary unit.
        case bytes
    }

    public var ticks: [Double]
    /// For `.bytes`: the binary unit (power of 1024) used for labels.
    public var unitIndex: Int

    public var upperBound: Double { ticks.last ?? 1 }

    /// Ticks from 0 to at least `maxValue`, roughly `targetCount` intervals.
    public init(maxValue: Double, kind: Kind, targetCount: Int = 4) {
        let target = max(targetCount, 1)
        switch kind {
        case .fraction:
            let maxPercent = max(maxValue.isFinite ? maxValue * 100 : 0, 0)
            let step = NiceScale.niceStep(raw: max(maxPercent, 1) / Double(target))
            ticks = NiceScale.ticks(maxValue: max(maxPercent, step), step: step).map { $0 / 100 }
            unitIndex = 0
        case .bytes:
            let value = max(maxValue.isFinite ? maxValue : 0, 0)
            var index = 0
            var scaled = value
            while scaled >= 1024, index < ByteFormat.units.count - 1 {
                scaled /= 1024
                index += 1
            }
            let unit = pow(1024, Double(index))
            var step = NiceScale.niceStep(raw: max(scaled, 1) / Double(target))
            if index == 0 { step = max(step, 1) } // no fractional bytes
            ticks = NiceScale.ticks(maxValue: max(scaled, step), step: step).map { $0 * unit }
            unitIndex = index
        }
    }

    /// 1, 2, 2.5, 5 × 10ⁿ.
    static func niceStep(raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let exponent = floor(log10(raw))
        let magnitude = pow(10, exponent)
        let fraction = raw / magnitude
        let nice: Double
        if fraction <= 1 { nice = 1 }
        else if fraction <= 2 { nice = 2 }
        else if fraction <= 2.5 { nice = 2.5 }
        else if fraction <= 5 { nice = 5 }
        else { nice = 10 }
        return nice * magnitude
    }

    static func ticks(maxValue: Double, step: Double) -> [Double] {
        let count = Int((maxValue / step - 1e-9).rounded(.up))
        return (0...max(count, 1)).map { Double($0) * step }
    }
}
