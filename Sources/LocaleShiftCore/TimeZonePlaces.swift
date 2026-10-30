import Foundation

public struct TimeZoneSearchResult: Identifiable, Equatable, Sendable {
    public var timeZone: String
    public var city: String
    public var genericName: String
    public var matchedPlaces: String
    public var coverage: String
    public var id: String { timeZone }
    public var title: String { matchedPlaces.isEmpty ? city : matchedPlaces + " · " + city }
}

/// Place names help find an IANA zone; they do not create new zones or merge equal offsets.
public enum TimeZonePlaceSearch {
    private struct Area: Decodable {
        var timeZone: String
        var description: String
        var aliases: [String]?
    }
    private struct Place: Decodable {
        var code: String
        var name: String
        var aliases: [String]
        var areas: [Area]
    }
    private struct DataFile: Decodable { var US: [Place] }
    private static let usPlaces: [Place] = {
        guard let url = CoreResources.bundle.url(forResource: "timezone-places", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(DataFile.self, from: data) else { return [] }
        return file.US
    }()
    public static func results(countryCode: String, zones: [String], query: String, capital: CapitalTimeZone? = nil) -> [TimeZoneSearchResult] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let locale = Locale(identifier: "zh-Hans-CN")
        var matched: [(Place, Area)] = []
        var exactPlaceMatch = false
        if !term.isEmpty && countryCode == "US" {
            let all = usPlaces.flatMap { place in place.areas.map { (place, $0) } }
            func terms(_ item: (Place, Area)) -> [String] { [item.0.name] + item.0.aliases + (item.1.aliases ?? []) }
            let exact = all.filter { terms($0).contains { $0.caseInsensitiveCompare(term) == .orderedSame } }
            exactPlaceMatch = !exact.isEmpty
            matched = exact.isEmpty ? all.filter { terms($0).contains { $0.localizedStandardContains(term) } || $0.1.description.localizedStandardContains(term) } : exact
        }
        return Array(Set(zones)).sorted().compactMap { zone in
            guard let timeZone = TimeZone(identifier: zone) else { return nil }
            let city = ProfileTitle.city(zone)
            let generic = timeZone.localizedName(for: .generic, locale: locale) ?? city + "时间"
            let places = matched.filter { $0.1.timeZone == zone }
            let isCapital = capital?.timeZone == zone && (capital?.city.localizedStandardContains(term) ?? false)
            guard term.isEmpty || !places.isEmpty || (!exactPlaceMatch && (isCapital || city.localizedStandardContains(term)
                    || generic.localizedStandardContains(term) || zone.replacingOccurrences(of: "_", with: " ").localizedStandardContains(term))) else { return nil }
            var seen = Set<String>()
            let names = places.map { $0.0.name }.filter { seen.insert($0).inserted }.joined(separator: "、")
            let coverage = places.map { $0.0.name + "：" + $0.1.description }.joined(separator: "；")
            return TimeZoneSearchResult(timeZone: zone, city: city, genericName: generic, matchedPlaces: names, coverage: coverage)
        }
    }
}
