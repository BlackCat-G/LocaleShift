import AppKit
import Foundation

enum AppBranding {
    private static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("LocaleShift_LocaleShiftApp.bundle"),
           let packaged = Bundle(url: url) { return packaged }
        // Installed apps must never fall back to a developer's build directory.
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        return .module
    }()

    static var statusIconURL: URL? { resources.url(forResource: "StatusIconTemplate", withExtension: "png") }

    static func makeStatusIcon() -> NSImage? {
        guard let url = statusIconURL, let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 19, height: 18)
        image.isTemplate = true
        return image
    }
}
