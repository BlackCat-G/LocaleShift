import AppKit

/// Keep the standard close shortcut local to our ordinary windows. A window
/// reopened from a status-item popover must not depend solely on menu routing.
final class LocaleShiftWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown, modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w",
           isKeyWindow, attachedSheet == nil, NSApp.modalWindow == nil {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
