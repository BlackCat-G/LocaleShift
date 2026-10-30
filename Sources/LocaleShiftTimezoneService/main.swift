import Foundation
import OSLog
import Darwin
import LocaleShiftCore
import LocaleShiftSystem

let logger = Logger(subsystem: RuntimePaths.rootID, category: "service")

final class RootEndpoint: NSObject, TimezoneServiceProtocol {
    let uid: UInt32
    let process: ProcessIdentity
    let queue: DispatchQueue
    let store: MachineLeaseStore
    init(uid: UInt32, process: ProcessIdentity, queue: DispatchQueue, store: MachineLeaseStore) { self.uid = uid; self.process = process; self.queue = queue; self.store = store }
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        queue.async {
            let response: RootReply
            do {
                guard request.count <= 65_536 else { throw CoreError(.invalidTarget) }
                let command = try JSONDecoder().decode(RootRequest.self, from: request)
                response = self.store.perform(command, callerUID: self.uid, callerProcess: self.process)
            } catch {
                response = RootReply(available: false, actualTimeZone: NativePreferences.actualTimeZone(),
                    error: error as? CoreError ?? CoreError(.invalidTarget))
            }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
final class RootListener: NSObject, NSXPCListenerDelegate {
    let listener = NSXPCListener(machServiceName: RuntimePaths.rootID)
    let queue = DispatchQueue(label: "com.localeshift.machine-state")
    let store: MachineLeaseStore
    var timer: DispatchSourceTimer?
    init(store: MachineLeaseStore, requirement: String) {
        self.store = store; super.init()
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = self
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { store.monitor() }; timer.resume(); self.timer = timer
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier >= 500,
              PeerTrust.acceptsPeer(pid: connection.processIdentifier, uid: connection.effectiveUserIdentifier, executables: ["LocaleShift", "LocaleShiftUserAgent"]),
              let process = ProcessInspector.identity(pid: connection.processIdentifier, uid: connection.effectiveUserIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: TimezoneServiceProtocol.self)
        connection.exportedObject = RootEndpoint(uid: connection.effectiveUserIdentifier, process: process, queue: queue, store: store)
        connection.activate(); return true
    }
}

if CommandLine.arguments.contains("--diagnostics") {
    let result: [String: Any] = ["role": "timezone-service", "protocolVersion": RuntimePaths.protocolVersion,
        "trustedSignature": PeerTrust.canModifySystem, "actualTimeZone": NativePreferences.actualTimeZone(),
        "systemWritesPerformed": false]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    exit(0)
}
guard geteuid() == 0,
      let requirement = PeerTrust.listenerRequirement(identifiers: [RuntimePaths.agentID, RuntimePaths.appID]) else {
    logger.error("Trusted signature and root context are required; refusing system writes.")
    exit(78)
}
if CommandLine.arguments.contains("--local-removal-check") {
    guard RuntimePaths.localDevelopment else { exit(78) }
    do {
        guard let process = ProcessInspector.identity(pid: getpid()) else { exit(78) }
        let status = try MachineLeaseStore().perform(RootRequest(.status), callerUID: LocalDevelopmentTrust.authorizedUID ?? 0, callerProcess: process)
        guard status.available, status.ownerSessionID == nil else { exit(78) }
        print("No pending machine recovery responsibility."); exit(0)
    } catch { exit(78) }
}
do {
    let server = RootListener(store: try MachineLeaseStore(), requirement: requirement)
    server.listener.activate()
    RunLoop.main.run()
    withExtendedLifetime(server) {}
} catch {
    logger.error("Machine recovery store could not be opened: \(error.localizedDescription, privacy: .public)")
    exit(78)
}
