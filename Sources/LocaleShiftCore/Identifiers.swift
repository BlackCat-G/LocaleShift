import Foundation

public enum IdentifierNormalizer {
    public static func language(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        let aliases = ["zh-cn": "zh-Hans-CN", "zh-sg": "zh-Hans-SG", "zh-tw": "zh-Hant-TW", "zh-hk": "zh-Hant-HK", "iw": "he", "in": "id", "ji": "yi"]
        if let alias = aliases[clean.lowercased()] { return alias }
        return clean.split(separator: "-").enumerated().map { index, part in
            let text = String(part)
            if index == 0 { return text.lowercased() }
            if text.count == 4 { return text.prefix(1).uppercased() + text.dropFirst().lowercased() }
            if text.count == 2 || text.count == 3 && text.allSatisfy(\.isNumber) { return text.uppercased() }
            return text.lowercased()
        }.joined(separator: "-")
    }
    public static func orderedLanguages(target: String, existing: [String]) -> [String] {
        var seen = Set<String>()
        return ([target] + existing).map(language).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    public static func canonicalRegion(_ value: String) -> String {
        let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
        let rawBase = parts.first ?? value
        let base = rawBase.count == 2 ? rawBase.uppercased() : Locale.identifier(.icu, from: rawBase.replacingOccurrences(of: "-", with: "_"))
        guard parts.count == 2 else { return base }
        return base + "@" + parts[1].split(separator: ";").map(String.init).sorted().joined(separator: ";")
    }
    public static func region(_ actual: String, countryCode: String) -> String {
        let segments = actual.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let identifier = String(segments.first ?? "")
        var components = Locale.Components(identifier: identifier)
        components.languageComponents.region = Locale.Region(countryCode.uppercased())
        let base = Locale(components: components).identifier
        return base + (segments.count > 1 ? "@" + segments[1] : "")
    }
    public static func applyingRegion(_ target: String, preserving actual: String) -> String {
        let targetBase = String(target.split(separator: "@", maxSplits: 1).first ?? "")
        let actualKeywords = actual.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        // Country-only selectors retain the current locale's language and independent formatting keywords.
        let base = targetBase.count == 2 ? region(actual, countryCode: targetBase).split(separator: "@", maxSplits: 1).first.map(String.init) ?? targetBase : targetBase
        return base + (actualKeywords.count > 1 ? "@" + actualKeywords[1] : "")
    }
    public static func countryCode(_ region: String) -> String {
        if region.count == 2 { return region.uppercased() }
        return Locale(identifier: region).region?.identifier ?? region
    }
    /// Validate BCP 47 structure without narrowing variants/extensions to the UI language list.
    public static func isValidLanguage(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        guard !text.contains("--"), !text.hasPrefix("-"), !text.hasSuffix("-") else { return false }
        let grandfathered: Set<String> = ["en-gb-oed", "i-ami", "i-bnn", "i-default", "i-enochian", "i-hak", "i-klingon", "i-lux", "i-mingo", "i-navajo", "i-pwn", "i-tao", "i-tay", "i-tsu", "sgn-be-fr", "sgn-be-nl", "sgn-ch-de", "art-lojban", "cel-gaulish", "no-bok", "no-nyn", "zh-guoyu", "zh-hakka", "zh-min", "zh-min-nan", "zh-xiang"]
        if grandfathered.contains(text.lowercased()) { return true }
        let parts = language(text).lowercased().split(separator: "-").map(String.init)
        func alpha(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { (97...122).contains($0) } }
        func alnum(_ s: String) -> Bool { !s.isEmpty && s.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) } }
        guard let first = parts.first else { return false }
        if first == "x" { return parts.count > 1 && parts.dropFirst().allSatisfy { (1...8).contains($0.count) && alnum($0) } }
        guard (2...8).contains(first.count), alpha(first) else { return false }
        var i = 1
        if first.count <= 3 { var count = 0; while i < parts.count && parts[i].count == 3 && alpha(parts[i]) && count < 3 { i += 1; count += 1 } }
        if i < parts.count && parts[i].count == 4 && alpha(parts[i]) { i += 1 }
        if i < parts.count && ((parts[i].count == 2 && alpha(parts[i])) || (parts[i].count == 3 && parts[i].utf8.allSatisfy { (48...57).contains($0) })) { i += 1 }
        var variants = Set<String>(), extensions = Set<String>()
        while i < parts.count {
            let part = parts[i]
            if ((5...8).contains(part.count) || (part.count == 4 && part.first?.isNumber == true)) && alnum(part) {
                guard variants.insert(part).inserted else { return false }; i += 1; continue
            }
            break
        }
        while i < parts.count {
            let key = parts[i]
            guard key.count == 1, alnum(key), extensions.insert(key).inserted else { return false }; i += 1
            let start = i
            let range = key == "x" ? 1...8 : 2...8
            while i < parts.count && range.contains(parts[i].count) && alnum(parts[i]) { i += 1 }
            guard i > start else { return false }
            if key == "x" { return i == parts.count }
        }
        return true
    }
    public static func isValidRegion(_ raw: String) -> Bool {
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let base = parts.first, !base.isEmpty,
              base.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else { return false }
        let knownRegions = Set(Locale.Region.isoRegions.map { $0.identifier.uppercased() })
        let code = countryCode(base).uppercased()
        guard knownRegions.contains(code), code != "ZZ" else { return false }
        if base.count != 2 {
            guard let languageCode = Locale(identifier: base).language.languageCode?.identifier,
                  Set(Locale.LanguageCode.isoLanguageCodes.map { $0.identifier }).contains(languageCode) else { return false }
        }
        if parts.count == 2 {
            for keyword in parts[1].split(separator: ";", omittingEmptySubsequences: false) {
                let item = keyword.split(separator: "=", omittingEmptySubsequences: false)
                guard item.count == 2, !item[0].isEmpty, !item[1].isEmpty,
                      item[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }),
                      item[1].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [95,45,47,43].contains($0) }) else { return false }
            }
        }
        return true
    }
    private struct TimezoneLinkData: Decodable { var version: String; var source: String; var links: [String: String] }
    private static let timezoneLinks: [String: String]? = {
        guard let url = CoreResources.bundle.url(forResource: "timezone-links", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(TimezoneLinkData.self, from: data) else { return nil }
        return catalog.links
    }()
    public static func timeZone(_ value: String) throws -> String {
        guard let aliases = timezoneLinks else { throw CoreError(.dataCorrupt, detail: "随包时区别名数据不可读取。") }
        var result = value
        var visited = Set<String>()
        while let next = aliases[result] {
            guard visited.insert(result).inserted else { throw CoreError(.dataCorrupt, detail: "随包时区别名数据存在循环。") }
            result = next
        }
        guard TimeZone(identifier: result) != nil else { throw CoreError(.invalidTarget, detail: "未知时区：\(value)", field: .timeZone) }
        return result
    }
}
public enum ProfileTitle {
    public static func city(_ timeZone: String) -> String {
        let cities = ["Asia/Shanghai": "上海", "Asia/Tokyo": "东京", "Asia/Hong_Kong": "香港", "Asia/Taipei": "台北", "Asia/Singapore": "新加坡", "Asia/Seoul": "首尔", "America/New_York": "纽约", "America/Los_Angeles": "洛杉矶", "America/Chicago": "芝加哥", "America/Denver": "丹佛", "Europe/London": "伦敦", "Europe/Paris": "巴黎", "Europe/Berlin": "柏林", "Australia/Sydney": "悉尼", "Asia/Kolkata": "加尔各答", "Asia/Kathmandu": "加德满都"]
        if let city = cities[timeZone] { return city }
        if let zone = TimeZone(identifier: timeZone) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh-Hans-CN")
            formatter.timeZone = zone
            formatter.dateFormat = "VVV" // Unicode CLDR localized exemplar city.
            let localized = formatter.string(from: Date())
            if !localized.isEmpty && localized != "未知城市" && localized != "Unknown City" { return localized }
        }
        return timeZone.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? timeZone
    }
    public static func make(region: String, timeZone: String) -> String {
        let code = IdentifierNormalizer.countryCode(region)
        let name = Locale(identifier: "zh-Hans-CN").localizedString(forRegionCode: code) ?? code
        return "\(name)设置（\(city(timeZone))）"
    }
}
