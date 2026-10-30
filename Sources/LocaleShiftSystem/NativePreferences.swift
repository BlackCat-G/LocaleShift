import Foundation
import CoreFoundation
import LocaleShiftCore

public enum NativePreferences {
    public static func read() throws -> SystemSettings {
        _ = CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard let languages = CFPreferencesCopyValue("AppleLanguages" as CFString,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
            !languages.isEmpty,
            let region = CFPreferencesCopyValue("AppleLocale" as CFString,
            kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String,
            !region.isEmpty else { throw NativeError.unreadablePreferences }
        NSTimeZone.resetSystemTimeZone()
        return SystemSettings(languages: languages, region: region, timeZone: NSTimeZone.system.identifier)
    }
    /// This method is used by the user service, never by the root helper.
    public static func write(_ field: SettingField, settings: SystemSettings) throws {
        let key: CFString
        let value: CFPropertyList
        switch field {
        case .languages:
            guard !settings.languages.isEmpty else { throw NativeError.unreadablePreferences }
            key = "AppleLanguages" as CFString; value = settings.languages as CFArray
        case .region:
            key = "AppleLocale" as CFString; value = settings.region as CFString
        case .timeZone: throw NativeError.privilegedRouteRequired
        }
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw NativeError.synchronizationFailed
        }
        let actual = try read()
        guard (field == .languages && actual.languages == settings.languages) ||
                (field == .region && actual.region == settings.region) else { throw NativeError.readbackMismatch }
    }
    public static func actualTimeZone() -> String {
        NSTimeZone.resetSystemTimeZone(); return NSTimeZone.system.identifier
    }
    public static func supportedLanguages() -> [String] {
        let resources = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Resources")
        guard let files = try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) else { return [] }
        var values = Set(files.filter { $0.pathExtension == "lproj" && $0.deletingPathExtension().lastPathComponent != "Base" }
            .map { IdentifierNormalizer.language($0.deletingPathExtension().lastPathComponent) })
        for (base, variant) in [("en", "en-US"), ("ja", "ja-JP"), ("ko", "ko-KR")] where values.contains(base) { values.insert(variant) }
        return values.sorted()
    }
    public static func supportsLanguage(_ language: String) -> Bool {
        let normalized = IdentifierNormalizer.language(language)
        let supported = Set(supportedLanguages())
        if supported.contains(normalized) { return true }
        if normalized.hasPrefix("zh-") { return false }
        return supported.contains(normalized.components(separatedBy: "-")[0])
    }
}

public enum NativeError: Error, LocalizedError {
    case unreadablePreferences, synchronizationFailed, readbackMismatch, privilegedRouteRequired
    public var errorDescription: String? {
        switch self {
        case .unreadablePreferences: return "无法读取完整系统语言或地区，请先检查系统设置。"
        case .synchronizationFailed: return "系统偏好未能可靠保存。"
        case .readbackMismatch: return "系统实际设置与目标不同，操作尚未完成。"
        case .privilegedRouteRequired: return "时区修改需要可用的系统辅助服务。"
        }
    }
}
