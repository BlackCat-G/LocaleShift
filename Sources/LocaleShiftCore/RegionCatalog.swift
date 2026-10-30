import Foundation

public struct RegionEntry: Equatable, Identifiable, Sendable {
    public var countryCode: String
    public var name: String
    public var timeZones: [String]
    public var id: String { countryCode }
}
public struct CapitalTimeZone: Codable, Equatable, Sendable {
    public var city: String
    public var timeZone: String
    public var kind: String
}
public struct RegionRecommendation: Equatable, Sendable {
    public var countryCode: String
    public var language: String?
    public var languageCandidates: [String]
    public var timeZones: [String]
    public var preservesCurrentLanguage: Bool
    public var explanation: String
    public var capital: CapitalTimeZone?
    public var selectedTimeZone: String? {
        if let capital, timeZones.contains(capital.timeZone) { return capital.timeZone }
        return timeZones.count == 1 ? timeZones.first : nil
    }
    public var requiresCitySelection: Bool { !timeZones.isEmpty && selectedTimeZone == nil }
    public var timeZoneExplanation: String {
        if let capital, selectedTimeZone == capital.timeZone { return "默认推荐\(capital.kind)\(capital.city)所在时区，可手动更换城市。" }
        if selectedTimeZone != nil { return "该地区只有一个时区，已自动选择。" }
        return "该地区暂无可靠的首都时区推荐，请手动选择城市或时区。"
    }
}
public struct RegionCatalog: Sendable {
    public let supportedLanguages: [String]
    public let regions: [RegionEntry]
    public let dataVersion: String
    private let capitals: [String: CapitalTimeZone]
    public init(supportedLanguages: [String]) {
        self.supportedLanguages = supportedLanguages.map(IdentifierNormalizer.language)
        capitals = CoreResources.bundle.url(forResource: "capital-timezones", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: CapitalTimeZone].self, from: $0) } ?? [:]
        dataVersion = CoreResources.bundle.url(forResource: "tzdb-version", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "unknown"
        let data = CoreResources.bundle.url(forResource: "zone", withExtension: "tab").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        var countries: [String: Set<String>] = [:]
        for line in data.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t")
            guard columns.count >= 3 else { continue }
            for code in columns[0].split(separator: ",") { countries[String(code), default: []].insert(String(columns[2])) }
        }
        let chinese = Locale(identifier: "zh-Hans-CN")
        regions = countries.map { RegionEntry(countryCode: $0.key, name: chinese.localizedString(forRegionCode: $0.key) ?? $0.key, timeZones: $0.value.sorted()) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func recommendation(countryCode: String, currentLanguages: [String]) -> RegionRecommendation {
        let code = countryCode.uppercased()
        // Curated UI-language candidates. Availability always comes from the injected verified system list.
        let candidates: [String: [String]] = ["US": ["en-US", "en"], "GB": ["en-GB", "en"], "AU": ["en-AU", "en-GB", "en"], "CA": ["en-CA", "en", "fr-CA", "fr"], "CN": ["zh-Hans-CN", "zh-Hans"], "TW": ["zh-Hant-TW", "zh-Hant"], "HK": ["zh-Hant-HK", "zh-Hant"], "SG": ["en-SG", "en", "zh-Hans-SG", "zh-Hans"], "JP": ["ja", "ja-JP"], "KR": ["ko", "ko-KR"], "DE": ["de", "de-DE"], "AT": ["de-AT", "de"], "CH": ["de-CH", "de", "fr", "it"], "FR": ["fr", "fr-FR"], "IT": ["it", "it-IT"], "ES": ["es", "es-ES"], "MX": ["es-MX", "es-419", "es"], "BR": ["pt-BR", "pt"], "PT": ["pt-PT", "pt"], "IN": ["hi", "en-IN", "en"], "TH": ["th"], "VN": ["vi"], "ID": ["id"], "MY": ["ms", "en"], "RU": ["ru"], "UA": ["uk"], "PL": ["pl"], "NL": ["nl"], "BE": ["nl", "fr"], "SE": ["sv"], "NO": ["nb", "no"], "DK": ["da"], "FI": ["fi"], "TR": ["tr"], "SA": ["ar"], "AE": ["ar", "en"], "IL": ["he"], "GR": ["el"], "CZ": ["cs"], "HU": ["hu"], "RO": ["ro"], "NZ": ["en-NZ", "en-GB", "en"]]
        let supported = Set(supportedLanguages)
        let available = (candidates[code] ?? []).map(IdentifierNormalizer.language).filter { supported.contains($0) }
        let current = currentLanguages.map(IdentifierNormalizer.language).first { supported.contains($0) }
        let chosen = available.first ?? current
        let zones = regions.first { $0.countryCode == code }?.timeZones ?? []
        let capital = capitals[code].flatMap { zones.contains($0.timeZone) && TimeZone(identifier: $0.timeZone) != nil ? $0 : nil }
        return RegionRecommendation(countryCode: code, language: chosen, languageCandidates: available, timeZones: zones, preservesCurrentLanguage: available.isEmpty, explanation: available.isEmpty ? (current == nil ? "此地区暂无可用系统语言推荐，请从受支持的系统语言中选择。" : "此地区暂无可用系统语言推荐，将保留当前受支持的首选语言。") : "推荐语言来自随包地区数据，并已与此 Mac 支持的系统语言核对。", capital: capital)
    }
}
