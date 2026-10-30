import Foundation
import LocaleShiftCore

public enum VerifiedCapabilities {
    /// A deployment target is not a compatibility claim. Expand only after system acceptance.
    public static var current: EngineCapabilities {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let verified = version.majorVersion == 27 && version.minorVersion == 0 && version.patchVersion == 1
        #else
        let verified = false
        #endif
        return EngineCapabilities(languageWrite: verified, regionWrite: verified, timeZoneWrite: verified,
            backgroundRecovery: verified, restartContinuation: false)
    }
}
