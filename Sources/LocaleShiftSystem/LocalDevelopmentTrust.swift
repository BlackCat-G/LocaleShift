import Foundation
import Security
import Darwin

/// This trust route is disabled in production. Administrator installation pins
/// an immutable bundle, its three code hashes and one local user in a root-owned file.
public enum LocalDevelopmentTrust {
    public static let installationDirectory = URL(fileURLWithPath: "/Library/Application Support/LocaleShiftLocalDevelopment", isDirectory: true)
    private struct Manifest: Decodable {
        var version: Int
        var build: String
        var uid: UInt32
        var bundle: String
        var hashes: [String: String]
    }
    private static let roles = ["LocaleShift": "app", "LocaleShiftUserAgent": "user-agent", "LocaleShiftTimezoneService": "timezone-service"]
    private struct FileStamp: Equatable {
        var path: String
        var device: Int32
        var inode: UInt64
        var mode: UInt16
        var owner: UInt32
        var group: UInt32
        var size: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        var changedSeconds: Int64
        var changedNanoseconds: Int64
    }
    private struct VerifiedBuild {
        var files: [FileStamp]
        var manifest: Manifest
        var verifiedAt: TimeInterval
    }
    private static let cacheLock = NSLock()
    private static var verifiedBuild: VerifiedBuild?
    private static var fullChecks = 0
    private static var cacheHits = 0
    public struct ValidationMetrics: Encodable {
        public var fullChecks: Int
        public var cacheHits: Int
    }
    public static var validationMetrics: ValidationMetrics {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return ValidationMetrics(fullChecks: fullChecks, cacheHits: cacheHits)
    }

    private static func stamp(_ url: URL, directory: Bool? = nil) -> FileStamp? {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_uid == 0, s.st_mode & 0o022 == 0,
              [S_IFDIR, S_IFREG].contains(s.st_mode & S_IFMT),
              directory == nil || s.st_mode & S_IFMT == (directory! ? S_IFDIR : S_IFREG) else { return nil }
        return FileStamp(path: url.path, device: s.st_dev, inode: s.st_ino, mode: s.st_mode,
            owner: s.st_uid, group: s.st_gid, size: s.st_size,
            modifiedSeconds: Int64(s.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(s.st_mtimespec.tv_nsec),
            changedSeconds: Int64(s.st_ctimespec.tv_sec), changedNanoseconds: Int64(s.st_ctimespec.tv_nsec))
    }
    /// Check every protected file's metadata, including resources and directory parents.
    /// Ordinary users cannot mutate these files. Any change invalidates the sealed-build cache.
    private static func protectedFiles(bundle: URL) -> [FileStamp]? {
        var files: [FileStamp] = []
        var parent = bundle
        while parent.path != "/" {
            guard let value = stamp(parent, directory: true) else { return nil }
            files.append(value); parent.deleteLastPathComponent()
        }
        guard let trust = stamp(installationDirectory.appendingPathComponent("trust.json"), directory: false),
              trust.size <= 16_384 else { return nil }
        files.append(trust)
        var failed = false
        guard let entries = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, _ in failed = true; return false }) else { return nil }
        for case let url as URL in entries {
            guard let value = stamp(url) else { return nil }
            files.append(value)
        }
        return failed ? nil : files.sorted { $0.path < $1.path }
    }

    private static func protectedPath(_ url: URL, directory: Bool) -> Bool {
        var item = stat()
        guard lstat(url.path, &item) == 0, item.st_uid == 0, item.st_mode & 0o022 == 0,
              item.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { return false }
        return true
    }
    private static func load() -> Manifest? {
        guard RuntimePaths.localDevelopment, let build = RuntimePaths.developmentBuild else { return nil }
        let bundle = installationDirectory.appendingPathComponent("Builds/" + build + "/LocaleShift.app", isDirectory: true)
        guard RuntimePaths.applicationBundle.path == bundle.path else { return nil }
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let files = protectedFiles(bundle: bundle) else { verifiedBuild = nil; return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if let verifiedBuild, verifiedBuild.files == files, now - verifiedBuild.verifiedAt < 300 {
            cacheHits += 1
            return verifiedBuild.manifest
        }
        verifiedBuild = nil; fullChecks += 1
        guard let manifest = validate(), let after = protectedFiles(bundle: bundle), after == files else { return nil }
        verifiedBuild = VerifiedBuild(files: files, manifest: manifest, verifiedAt: now)
        return manifest
    }
    private static func validate() -> Manifest? {
        guard RuntimePaths.localDevelopment, let build = RuntimePaths.developmentBuild else { return nil }
        let base = installationDirectory
        let bundle = base.appendingPathComponent("Builds/" + build + "/LocaleShift.app", isDirectory: true)
        // lstat every parent: a root-owned leaf behind a user-controlled symlink is insufficient.
        var parent = bundle
        while parent.path != "/" {
            guard protectedPath(parent, directory: true) else { return nil }
            parent.deleteLastPathComponent()
        }
        let file = base.appendingPathComponent("trust.json")
        guard protectedPath(file, directory: false),
              let data = try? Data(contentsOf: file), data.count <= 16_384,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1, manifest.uid >= 500, manifest.build == build,
              manifest.bundle == bundle.path, RuntimePaths.applicationBundle.path == bundle.path,
              manifest.hashes.count == roles.count else { return nil }
        // The complete sealed bundle and every executable must still match the approved build.
        var app: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &app) == errSecSuccess, let app,
              SecStaticCodeCheckValidity(app, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { return nil }
        for (name, role) in roles {
            let executable = bundle.appendingPathComponent("Contents/MacOS/" + name)
            guard protectedPath(executable, directory: false),
                  let hash = manifest.hashes[name], hash.count == 40,
                  hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                  PeerTrust.validatedCodeHash(executable: executable, identifier: "com.localeshift.localdev." + build + "." + role) == hash else { return nil }
        }
        return manifest
    }
    public static var isInstalled: Bool { load() != nil }
    public static var authorizedUID: UInt32? { load()?.uid }
    public static func requirement(identifiers: [String]) -> String? {
        guard let manifest = load(), getuid() == 0 || getuid() == manifest.uid, !identifiers.isEmpty else { return nil }
        var parts: [String] = []
        for id in identifiers {
            guard let role = roles.first(where: { "com.localeshift.localdev." + manifest.build + "." + $0.value == id }),
                  let hash = manifest.hashes[role.key] else { return nil }
            parts.append("(identifier \"" + id + "\" and cdhash H\"" + hash + "\")")
        }
        return parts.joined(separator: " or ")
    }
    public static func acceptsPeer(pid: Int32, uid: UInt32, executables: [String]) -> Bool {
        guard let manifest = load(), manifest.uid == uid else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return executables.contains { roles[$0] != nil && String(cString: path) == manifest.bundle + "/Contents/MacOS/" + $0 }
    }
}
