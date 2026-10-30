import Foundation

/// SwiftPM's generated accessor does not know the signed application's Contents/Resources layout.
enum CoreResources {
    static let bundle: Bundle = {
        if let packaged = resolve(mainBundle: .main, executableURL: Bundle.main.executableURL) { return packaged }
        // A broken installed app must report unavailable data rather than invoke Bundle.module's fatal fallback.
        let executablePath = Bundle.main.executableURL?.pathComponents ?? []
        if Bundle.main.bundleURL.pathExtension == "app" || executablePath.contains(where: { $0.hasSuffix(".app") }) { return .main }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return .main
        #endif
    }()

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
