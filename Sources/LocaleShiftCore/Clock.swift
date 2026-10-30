import Foundation

public struct ClockReading: Equatable, Sendable {
    public var timeZone: String
    public var city: String
    public var dateText: String
    public var timeText: String
}
public struct DualClockSnapshot: Equatable, Sendable {
    public var instant: Date
    public var baseline: ClockReading
    public var target: ClockReading
    /// Target UTC offset minus baseline UTC offset, including DST at this exact instant.
    public var offsetMinutes: Int
    public var relativeDayDifference: Int
    public var differenceText: String {
        if offsetMinutes == 0 { return "目标地区与系统默认地区时间相同" }
        let minutes = abs(offsetMinutes)
        let amount = (minutes / 60 > 0 ? "\(minutes / 60) 小时" : "") + (minutes % 60 > 0 ? "\(minutes % 60) 分钟" : "")
        return "目标地区比系统默认地区\(offsetMinutes > 0 ? "快" : "慢") \(amount)"
    }
}
public enum DualClock {
    public static func snapshot(instant: Date, baselineZone: String, targetZone: String, locale: Locale = Locale(identifier: "zh-Hans-CN")) throws -> DualClockSnapshot {
        let baseName = try IdentifierNormalizer.timeZone(baselineZone), targetName = try IdentifierNormalizer.timeZone(targetZone)
        guard let base = TimeZone(identifier: baseName), let target = TimeZone(identifier: targetName) else { throw CoreError(.invalidTarget) }
        func reading(_ zone: TimeZone) -> ClockReading {
            let date = DateFormatter(); date.locale = locale; date.calendar = Calendar(identifier: .gregorian); date.timeZone = zone; date.dateFormat = "yyyy-MM-dd"
            let time = DateFormatter(); time.locale = locale; time.timeZone = zone; time.dateFormat = "HH:mm:ss"
            return ClockReading(timeZone: zone.identifier, city: ProfileTitle.city(zone.identifier), dateText: date.string(from: instant), timeText: time.string(from: instant))
        }
        func day(_ zone: TimeZone) -> Date {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let components = calendar.dateComponents([.year, .month, .day], from: instant)
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            return utc.date(from: components)!
        }
        return DualClockSnapshot(instant: instant, baseline: reading(base), target: reading(target), offsetMinutes: (target.secondsFromGMT(for: instant) - base.secondsFromGMT(for: instant)) / 60, relativeDayDifference: Int(day(target).timeIntervalSince(day(base)) / 86400))
    }
}
