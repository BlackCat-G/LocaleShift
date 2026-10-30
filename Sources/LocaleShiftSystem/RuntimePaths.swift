import Foundation

public enum RuntimePaths {
    public static var localDevelopment: Bool {
        #if LOCALESHIFT_LOCAL_DEVELOPMENT
        return true
        #else
        return false
        #endif
    }
    public static let developmentBuild: String? = {
        guard localDevelopment,
              let info = NSDictionary(contentsOf: applicationBundle.appendingPathComponent("Contents/Info.plist")),
              let value = info["LocaleShiftDevelopmentBuild"] as? String,
              value.count == 32, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }()
    private static var prefix: String { localDevelopment ? "com.localeshift.localdev." + (developmentBuild ?? "invalid") : "com.localeshift" }
    public static var appID: String { prefix + ".app" }
    public static var agentID: String { prefix + ".user-agent" }
    public static var rootID: String { prefix + ".timezone-service" }
    public static let protocolVersion = 1
    public static let applicationBundle: URL = {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])).standardizedFileURL
        if executable.deletingLastPathComponent().lastPathComponent == "MacOS" {
            return executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return Bundle.main.bundleURL
    }()
    public static var userData: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(localDevelopment ? "LocaleShiftLocalDevelopment" : "LocaleShift", isDirectory: true)
    }
    public static var machineData: URL { URL(fileURLWithPath: localDevelopment ? "/Library/Application Support/LocaleShiftLocalDevelopment/State" : "/Library/Application Support/LocaleShift", isDirectory: true) }
    public static func executable(_ name: String) -> URL {
        applicationBundle.appendingPathComponent("Contents/MacOS/" + name)
    }
}
