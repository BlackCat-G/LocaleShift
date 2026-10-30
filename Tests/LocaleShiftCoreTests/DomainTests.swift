import Foundation
#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
@testable import LocaleShiftCore

final class DomainTests: CoreTestBase {
    #if !canImport(XCTest)
    @Test
    #endif
    func testLanguagesCanonicalizedAndOrderedWithoutLosingOthers() throws {
        XCTAssertEqual(IdentifierNormalizer.language("en_US"), "en-US")
        XCTAssertEqual(IdentifierNormalizer.language("zh-CN"), "zh-Hans-CN")
        XCTAssertEqual(IdentifierNormalizer.orderedLanguages(target: "en_US", existing: ["ja", "en-US", "zh-CN", "ja"]), ["en-US", "ja", "zh-Hans-CN"])
        XCTAssertEqual(IdentifierNormalizer.region("en_US@calendar=buddhist;numbers=thai", countryCode: "JP"), "en_JP@calendar=buddhist;numbers=thai")
        XCTAssertEqual(try IdentifierNormalizer.timeZone("US/Eastern"), "America/New_York")
        XCTAssertNotEqual(try IdentifierNormalizer.timeZone("Asia/Shanghai"), try IdentifierNormalizer.timeZone("Asia/Singapore"))
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testProcessIdentityRequiresAllComponents() {
        let a = ProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1, bootID: "a")
        XCTAssertNotEqual(a, ProcessIdentity(pid: 42, startSeconds: 101, startMicroseconds: 1, bootID: "a"))
        XCTAssertNotEqual(a, ProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1, bootID: "b"))
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testClockUsesSameInstantAndFractionalDirectedOffsets() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-07-01T22:45:00Z")!
        let clock = try DualClock.snapshot(instant: instant, baselineZone: "Asia/Shanghai", targetZone: "America/New_York")
        XCTAssertEqual(clock.offsetMinutes, -720)
        XCTAssertEqual(clock.relativeDayDifference, -1)
        XCTAssertEqual(clock.baseline.dateText, "2026-07-02")
        XCTAssertEqual(clock.target.dateText, "2026-07-01")
        let fractional = try DualClock.snapshot(instant: instant, baselineZone: "Asia/Kolkata", targetZone: "Asia/Kathmandu")
        XCTAssertEqual(fractional.offsetMinutes, 15)
        XCTAssertTrue(fractional.differenceText.contains("快"))
        let winter = try DualClock.snapshot(instant: ISO8601DateFormatter().date(from: "2026-01-01T22:45:00Z")!, baselineZone: "Asia/Shanghai", targetZone: "America/New_York")
        XCTAssertEqual(winter.offsetMinutes, -780)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testCatalogDefaultsToCapitalAndUsesOnlySupportedLanguages() throws {
        let catalog = RegionCatalog(supportedLanguages: ["en-US", "zh-Hans-CN", "ja"])
        let us = catalog.recommendation(countryCode: "US", currentLanguages: ["zh-CN"])
        XCTAssertFalse(us.requiresCitySelection)
        XCTAssertEqual(us.selectedTimeZone, "America/New_York")
        XCTAssertEqual(us.capital?.city, "华盛顿")
        XCTAssertEqual(us.language, "en-US")
        let jp = catalog.recommendation(countryCode: "JP", currentLanguages: ["en-US"])
        XCTAssertEqual(jp.selectedTimeZone, "Asia/Tokyo")
        let unknown = catalog.recommendation(countryCode: "ZZ", currentLanguages: ["zh-CN", "en-US"])
        XCTAssertTrue(unknown.preservesCurrentLanguage)
        XCTAssertEqual(unknown.language, "zh-Hans-CN")
        XCTAssertEqual(catalog.recommendation(countryCode: "AU", currentLanguages: []).selectedTimeZone, "Australia/Sydney")
        XCTAssertEqual(catalog.recommendation(countryCode: "CA", currentLanguages: []).selectedTimeZone, "America/Toronto")
        XCTAssertEqual(catalog.recommendation(countryCode: "CN", currentLanguages: []).selectedTimeZone, "Asia/Shanghai")
        let noCapital = catalog.recommendation(countryCode: "AQ", currentLanguages: [])
        XCTAssertNil(noCapital.selectedTimeZone)
        XCTAssertTrue(noCapital.requiresCitySelection)
        for region in catalog.regions {
            let result = catalog.recommendation(countryCode: region.countryCode, currentLanguages: [])
            if let capital = result.capital {
                XCTAssertTrue(region.timeZones.contains(capital.timeZone))
                XCTAssertNotNil(TimeZone(identifier: capital.timeZone))
            }
        }
        XCTAssertGreaterThan(catalog.regions.count, 200)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testStateSearchPreservesRegionsAndSplitTimezoneChoices() throws {
        let catalog = RegionCatalog(supportedLanguages: ["en-US"])
        let zones = catalog.regions.first { $0.countryCode == "US" }!.timeZones
        func find(_ text: String) -> Set<String> { Set(TimeZonePlaceSearch.results(countryCode: "US", zones: zones, query: text).map(\.timeZone)) }
        for term in ["弗吉尼亚州", "佛吉尼亚", "Virginia", "VA", "Ashburn"] { XCTAssertEqual(find(term), ["America/New_York"]) }
        XCTAssertEqual(find("FL"), ["America/New_York", "America/Chicago"])
        XCTAssertEqual(find("Texas"), ["America/Chicago", "America/Denver"])
        XCTAssertEqual(find("Dallas"), ["America/Chicago"])
        XCTAssertEqual(find("Arlington"), ["America/Chicago", "America/New_York"])
        XCTAssertEqual(find("Washington"), ["America/Los_Angeles", "America/New_York"])
        XCTAssertEqual(find("Washington DC"), ["America/New_York"])
        XCTAssertFalse(find("IN").contains("America/Menominee"))
        XCTAssertTrue(find("not-a-place-zzzz").isEmpty)
        XCTAssertEqual(ProfileTitle.city("America/Anchorage"), "安克雷奇")
        XCTAssertEqual(ProfileTitle.city("America/Toronto"), "多伦多")
        let url = CoreResources.bundle.url(forResource: "timezone-places", withExtension: "json")!
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let places = data["US"] as! [[String: Any]]
        XCTAssertEqual(Set(places.compactMap { $0["code"] as? String }).count, 51)
        for place in places {
            for area in place["areas"] as! [[String: Any]] { XCTAssertTrue(zones.contains(area["timeZone"] as! String)) }
        }
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testShippedIANALinksNormalizeAliasesButKeepDistinctZones() throws {
        XCTAssertEqual(try IdentifierNormalizer.timeZone("US/Alaska"), "America/Anchorage")
        XCTAssertEqual(try IdentifierNormalizer.timeZone("Canada/Eastern"), "America/Toronto")
        XCTAssertEqual(try IdentifierNormalizer.timeZone("Australia/ACT"), "Australia/Sydney")
        XCTAssertNotEqual(try IdentifierNormalizer.timeZone("America/Toronto"), try IdentifierNormalizer.timeZone("America/New_York"))
        XCTAssertNotEqual(try IdentifierNormalizer.timeZone("Asia/Shanghai"), try IdentifierNormalizer.timeZone("Asia/Singapore"))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testLocalizedCityKeepsDistinctIANALocations() {
        XCTAssertEqual(ProfileTitle.city("America/Detroit"), "底特律")
        XCTAssertNotEqual(ProfileTitle.city("America/Detroit"), ProfileTitle.city("America/Indiana/Indianapolis"))
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testSettingsRejectInvalidInputWhilePreservingLegalVariantsAndKeywords() throws {
        for language in ["nonsense!", "en--US", "en-US-u", "en-US-u-ca-u-nu", "en/US"] {
            XCTAssertThrowsError(try SystemSettings(languages: [language], region: "en_US", timeZone: "Asia/Shanghai").validated())
        }
        for region in ["garbage", "garbage_US", "en_ZZ", "en_US@calendar", "en_US@calendar="] {
            XCTAssertThrowsError(try SystemSettings(languages: ["en-US"], region: region, timeZone: "Asia/Shanghai").validated())
        }
        let exact = SystemSettings(languages: ["zh-CN", "sr-Latn-RS", "de-CH-1901", "sl-rozaj-biske", "en-US-u-ca-buddhist", "x-private"], region: "en_US_POSIX@calendar=buddhist;numbers=thai", timeZone: "Asia/Shanghai")
        XCTAssertEqual(try exact.validated(), exact)
    }

}
