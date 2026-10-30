import Foundation
#if canImport(XCTest)
import XCTest
#else
import Testing
#endif
@testable import LocaleShiftCore

final class ResourceTests: CoreTestBase {
    #if !canImport(XCTest)
    @Test
    #endif
    func testXcodeHostedTestRunnerCanUseSwiftPackageResources() {
        let runner = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
        XCTAssertFalse(CoreResources.isPackagedExecutable(runner))
        XCTAssertNotNil(CoreResources.bundle.url(forResource: "timezone-links", withExtension: "json"))
        XCTAssertNotNil(CoreResources.bundle.url(forResource: "capital-timezones", withExtension: "json"))
    }

    #if !canImport(XCTest)
    @Test
    #endif
    func testInstalledExecutablesKeepMissingResourceProtectionWhenAppIsRenamed() {
        let contents = URL(fileURLWithPath: "/Applications/Renamed.app/Contents")
        XCTAssertTrue(CoreResources.isPackagedExecutable(contents.appendingPathComponent("MacOS/LocaleShift")))
        XCTAssertTrue(CoreResources.isPackagedExecutable(contents.appendingPathComponent("MacOS/LocaleShiftUserAgent")))
        XCTAssertTrue(CoreResources.isPackagedExecutable(contents.appendingPathComponent("Library/LaunchServices/LocaleShiftTimezoneService")))
        XCTAssertFalse(CoreResources.isPackagedExecutable(contents.appendingPathComponent("Developer/usr/bin/LocaleShift")))
    }

    private func appFixture() throws -> (Bundle, URL, URL) {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("LocaleShift.app")
        addTeardownBlock { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let contents = app.appendingPathComponent("Contents")
        let resource = contents.appendingPathComponent("Resources/LocaleShift_LocaleShiftCore.bundle")
        try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        let mainInfo: [String: String] = ["CFBundleIdentifier": "test.localeshift.app", "CFBundlePackageType": "APPL", "CFBundleExecutable": "LocaleShift"]
        try PropertyListSerialization.data(fromPropertyList: mainInfo, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.localeshift.resources", "CFBundlePackageType": "BNDL"], format: .xml, options: 0).write(to: resource.appendingPathComponent("Info.plist"))
        return (Bundle(url: app)!, contents, resource)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testPackagedAppUsesContentsResourcesBeforeSwiftPMFallback() throws {
        let (app, contents, resource) = try appFixture()
        let resolved = CoreResources.resolve(mainBundle: app, executableURL: contents.appendingPathComponent("MacOS/LocaleShift"))
        XCTAssertEqual(resolved?.bundleURL.standardizedFileURL.path, resource.standardizedFileURL.path)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testUnbundledHelperFindsContainingAppResources() throws {
        let (_, contents, resource) = try appFixture()
        let executable = contents.appendingPathComponent("Library/LaunchServices/LocaleShiftTimezoneService")
        let resolved = CoreResources.resolve(mainBundle: Bundle.main, executableURL: executable)
        XCTAssertEqual(resolved?.bundleURL.standardizedFileURL.path, resource.standardizedFileURL.path)
    }
    #if !canImport(XCTest)
    @Test
    #endif
    func testMacOSHelperFindsContainingAppResources() throws {
        let (_, contents, resource) = try appFixture()
        let executable = contents.appendingPathComponent("MacOS/LocaleShiftUserAgent")
        let resolved = CoreResources.resolve(mainBundle: Bundle.main, executableURL: executable)
        XCTAssertEqual(resolved?.bundleURL.standardizedFileURL.path, resource.standardizedFileURL.path)
    }

}
