import Foundation
import CryptoKit
import Darwin
import LocaleShiftCore

public enum ProcessLiveness { case alive, dead, unknown }

public enum ProcessInspector {
    public static func bootID() -> String? {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, count > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 else { return nil }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
    public static func identity(pid: Int32, uid: uid_t = getuid()) -> ProcessIdentity? {
        guard let boot = bootID() else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == uid else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: Int64(info.pbi_start_tvsec),
            startMicroseconds: Int32(info.pbi_start_tvusec), bootID: boot)
    }
    public static func liveness(_ expected: ProcessIdentity, uid: uid_t) -> ProcessLiveness {
        guard let boot = bootID() else { return .unknown }
        if boot != expected.bootID { return .dead }
        if let actual = identity(pid: expected.pid, uid: uid) { return actual == expected ? .alive : .dead }
        errno = 0
        if kill(expected.pid, 0) == -1 && errno == ESRCH { return .dead }
        return .unknown
    }
}
