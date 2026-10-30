import Foundation
import Security
import Darwin

public enum PeerTrust {
    public static var canModifySystem: Bool {
        if RuntimePaths.localDevelopment {
            guard let uid = LocalDevelopmentTrust.authorizedUID else { return false }
            return getuid() == 0 || getuid() == uid
        }
        return ownTeamIdentifier != nil
    }
    public static func listenerRequirement(identifiers: [String]) -> String? {
        if RuntimePaths.localDevelopment { return LocalDevelopmentTrust.requirement(identifiers: identifiers) }
        return productionRequirement(identifiers: identifiers)
    }
    public static func acceptsPeer(pid: Int32, uid: UInt32, executables: [String]) -> Bool {
        !RuntimePaths.localDevelopment || LocalDevelopmentTrust.acceptsPeer(pid: pid, uid: uid, executables: executables)
    }
    public static func validatedCodeHash(executable: URL, identifier: String) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == identifier,
              let hash = values[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    private static func signingInfo(_ code: SecCode) -> [String: Any]? {
        var result: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }
    public static var ownTeamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return signingInfo(code)?[kSecCodeInfoTeamIdentifier as String] as? String
    }
    private static func quoted(_ value: String) -> String? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else { return nil }
        return "\"" + value + "\""
    }
    public static func productionRequirement(identifiers: [String]) -> String? {
        guard let team = ownTeamIdentifier, let teamString = quoted(team), !identifiers.isEmpty else { return nil }
        let ids = identifiers.compactMap(quoted)
        guard ids.count == identifiers.count else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = " + teamString +
            " and (" + ids.map { "identifier " + $0 }.joined(separator: " or ") + ")"
    }
    /// Exact local code hash is usable for non-privileged development IPC only.
    /// A root service without a trusted Team ID remains read-only.
    public static func developmentRequirement(executable: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
    }
    public static func requirement(for id: String, executable: String, privileged: Bool) -> String? {
        if RuntimePaths.localDevelopment { return listenerRequirement(identifiers: [id]) }
        if let production = productionRequirement(identifiers: [id]) { return production }
        if privileged { return nil }
        return developmentRequirement(executable: RuntimePaths.executable(executable))
    }
}
