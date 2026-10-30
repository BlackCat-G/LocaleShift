import Foundation
import AppKit
import Carbon

extension Services {
    /// Requests the normal system restart event. Does not use reboot(2), a shell or force quit.
    public static func requestNormalRestart() throws {
        var systemProcess = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
        let target = NSAppleEventDescriptor(descriptorType: DescType(typeProcessSerialNumber), bytes: &systemProcess, length: MemoryLayout<ProcessSerialNumber>.size)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAERestart),
            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        _ = try event.sendEvent(options: [.noReply], timeout: 30)
    }
}
