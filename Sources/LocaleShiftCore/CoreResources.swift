import Foundation

/// SwiftPM's generated accessor does not know the signed application's Contents/Resources layout.
enum CoreResources {
    static let bundle: Bundle = {
        if let packaged = resolve(mainBundle: .main, executableURL: Bundle.main.executableURL) { return packaged }
        // A broken installed app must report unavailable data rather than invoke Bundle.module's fatal fallback.
        if isPackagedExecutable(Bundle.main.executableURL) { return .main }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return .main
        #endif
    }()

    /// Xcode's command-line test runner also lives beneath an .app directory.
    /// Only our executables in an application's supported helper layouts are installed products.
    static func isPackagedExecutable(_ executableURL: URL?) -> Bool {
        guard let executableURL else { return false }
        let components = executableURL.standardizedFileURL.pathComponents
        guard let contents = components.lastIndex(of: "Contents"), contents > 0,
              components[contents - 1].hasSuffix(".app") else { return false }
        let relative = Array(components.dropFirst(contents + 1))
        let executables = ["LocaleShift", "LocaleShiftUserAgent", "LocaleShiftTimezoneService"]
        return executables.contains { relative == ["MacOS", $0] || relative == ["Library", "LaunchServices", $0] }
    }

    static func resolve(mainBundle: Bundle, executableURL: URL?) -> Bundle? {
        var candidates: [URL] = []
        if let resources = mainBundle.resourceURL { candidates.append(resources) }
        if let executableURL {
            let parent = executableURL.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(parent.appendingPathComponent("Resources", isDirectory: true))
            candidates.append(parent.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true))
        }
        for candidate in candidates {
            let url = candidate.appendingPathComponent("LocaleShift_LocaleShiftCore.bundle", isDirectory: true).standardizedFileURL
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }
}
