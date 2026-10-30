import Foundation
import AppKit
import SwiftUI
import Combine
import Darwin
import LocaleShiftCore
import LocaleShiftSystem

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
    let model = AppModel()
    var status: NSStatusItem?
    var popover = NSPopover()
    var window: NSWindow?
    var onboardingWindow: NSWindow?
    var pendingOnboardingStage: CardRoute?
    var subscriptions = Set<AnyCancellable>()
    var terminationPending = false
    var systemEnding = false
    var workspaceToken: NSObjectProtocol?
    var spaceToken: NSObjectProtocol?
    private var presentedWindows = Set<ObjectIdentifier>()
    private var windowPreview = false
    private var movementObservations: [NSKeyValueObservation] = []
    private var afterPopoverClose: (() -> Void)?
    private weak var requestedKeyWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let quit = NSMenuItem(title: "退出 LocaleShift…", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; appMenu.addItem(quit)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key) }
        mainMenu.addItem(edit)
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "文件")
        let close = NSMenuItem(title: "关闭窗口", action: #selector(closeFrontWindow(_:)), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command]
        close.target = self; fileMenu.addItem(close); fileItem.submenu = fileMenu
        mainMenu.insertItem(fileItem, at: 1)
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowItem.submenu = windowMenu; mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu; NSApp.mainMenu = mainMenu
        // Window-only diagnostics must not look like a second running product.
        // This option cannot change presentation for the actual user data store.
        windowPreview = model.isolated && CommandLine.arguments.contains("--window-preview")
        if !windowPreview {
            status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status?.button?.target = self; status?.button?.action = #selector(statusClicked(_:))
            status?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp]); status?.button?.toolTip = "LocaleShift · 系统默认日期和时间"
            if let image = AppBranding.makeStatusIcon() {
                status?.button?.image = image
                status?.button?.imagePosition = .imageLeading
                status?.button?.imageScaling = .scaleProportionallyDown
            }
            status?.button?.setAccessibilityLabel("LocaleShift")
        }
        popover.behavior = .transient; popover.delegate = self; popover.contentSize = NSSize(width: AppLayout.cardWidth, height: AppLayout.cardHeight)
        popover.contentViewController = NSHostingController(rootView: CardView(model: model))
        model.showManagement = { [weak self] in self?.showManagement(allowActivation: true) }
        model.requestQuit = { NSApp.terminate(nil) }
        model.onboardingFinished = { [weak self] showCard in
            guard let self else { return }
            self.onboardingWindow?.orderOut(nil); self.pendingOnboardingStage = nil
            if let window = self.onboardingWindow { self.presentedWindows.remove(ObjectIdentifier(window)) }
            // Only an explicit, foreground confirmation returning to its preview opens the card.
            if showCard && NSApp.isActive { self.showPopover() }
            self.updateWindowPresentation()
        }
        model.$route.removeDuplicates().sink { [weak self] route in
            guard route == .baseline || route == .guide else { return }
            DispatchQueue.main.async { self?.showOnboarding(stage: route) }
        }.store(in: &subscriptions)
        model.$guideReturned.combineLatest(model.$showGuideSteps, model.$onboardingStage, model.$preparationCompletedAt).sink { [weak self] _, _, _, _ in
            DispatchQueue.main.async { self?.resizeOnboarding() }
        }.store(in: &subscriptions)
        model.$now.combineLatest(model.$clockStyle).sink { [weak self] _, _ in
            guard let self, let button = self.status?.button else { return }
            button.title = (button.image == nil ? "⇄ " : " ") + self.model.clockLabel
        }.store(in: &subscriptions)
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.systemEnding = true } }
        spaceToken = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
        // Launch/login reads state quietly. Only explicit UI actions present windows.
        if CommandLine.arguments.contains("--show-management") { showManagement(allowActivation: true) }
        else if CommandLine.arguments.contains("--show-card") { showPopover(allowActivation: true) }
    }
    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            let settings = NSMenuItem(title: "管理设置…", action: #selector(openManagement), keyEquivalent: ""); settings.target = self; menu.addItem(settings)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出 LocaleShift…", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); quit.target = NSApp; menu.addItem(quit)
            status?.menu = menu; sender.performClick(nil); status?.menu = nil
        } else if model.onboardingVisible && model.preparationCompletedAt != nil {
            showOnboarding(stage: .guide, allowActivation: true)
        } else { if popover.isShown { popover.performClose(nil) } else { showPopover(allowActivation: true) } }
    }
    func showPopover(allowActivation: Bool = false) {
        guard (allowActivation || NSApp.isActive), let button = status?.button else { return }
        if allowActivation && !NSApp.isActive {
            // A menu click must not bring the application's old main/key windows
            // across Spaces. Preserve their flows, but present only the requested card.
            window?.orderOut(nil); onboardingWindow?.orderOut(nil)
            presentedWindows.removeAll()
            requestedKeyWindow = nil
        }
        popover.contentSize = NSSize(width: AppLayout.cardWidth, height: AppLayout.cardHeight)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if allowActivation {
            activateForUserRequest()
        }
        Task { await model.refresh() }
    }
    func showOnboarding(stage: CardRoute, allowActivation: Bool = false) {
        guard NSApp.isActive || allowActivation else {
            pendingOnboardingStage = stage // Resume only after an explicit user request.
            return
        }
        if popover.isShown {
            let activate = allowActivation || NSApp.isActive
            afterPopoverClose = { [weak self] in self?.showOnboarding(stage: stage, allowActivation: activate) }
            popover.performClose(nil)
            return
        }
        // Promote before closing a card: its close delegate must not demote us
        // during the transition to an ordinary window.
        showOrdinaryWindows()
        popover.performClose(nil); model.onboardingStage = stage; model.route = .home
        pendingOnboardingStage = nil; model.onboardingVisible = true
        if onboardingWindow == nil {
            let panel = LocaleShiftWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: AppLayout.onboardingWidth, height: AppLayout.onboardingHeight(compact: false))), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "LocaleShift · 使用前准备"; panel.contentViewController = NSHostingController(rootView: OnboardingWindowView(model: model))
            configureOrdinaryWindow(panel)
            panel.isReleasedWhenClosed = false; panel.delegate = self; panel.center(); onboardingWindow = panel
        }
        resizeOnboarding()
        if let window = onboardingWindow { presentOrdinaryWindow(window, allowActivation: allowActivation) }
    }
    private func resizeOnboarding() {
        guard let onboardingWindow else { return }
        let compact = model.preparationCompletedAt == nil && model.onboardingStage == .guide && model.guideReturned && !model.showGuideSteps
        onboardingWindow.setContentSize(NSSize(width: AppLayout.onboardingWidth, height: AppLayout.onboardingHeight(compact: compact, availableHeight: onboardingWindow.screen?.visibleFrame.height)))
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { traceWindow("closed", window) }
        if notification.object as? NSWindow === requestedKeyWindow { requestedKeyWindow = nil }
        if let window = notification.object as? NSWindow { presentedWindows.remove(ObjectIdentifier(window)) }
        if notification.object as? NSWindow === onboardingWindow { pendingOnboardingStage = nil; model.preparationCompletedAt = nil; model.onboardingVisible = false; model.route = .home; model.selectedProfile = nil; model.preview = nil }
        // Wait for the close to finish before changing application presentation.
        // Closing UI never terminates the app or alters recovery responsibility.
        DispatchQueue.main.async { [weak self] in self?.updateWindowPresentation() }
    }
    func popoverDidClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let continuation = self.afterPopoverClose
            self.afterPopoverClose = nil
            continuation?()
            self.updateWindowPresentation()
        }
    }
    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow { traceWindow("moved", window) }
    }
    private func traceWindow(_ event: String, _ candidate: NSWindow) {
        // Explicit, isolated diagnostics only: record our own geometry, never
        // input events or other applications' windows. No production logging.
        guard windowPreview, candidate === window || candidate === onboardingWindow else { return }
        let frame = candidate.frame
        let value: [String: Any] = ["event": event, "window": candidate === window ? "management" : "preparation",
            "x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height,
            "uptime": ProcessInfo.processInfo.systemUptime, "menuBarItemCreated": status != nil,
            "movable": candidate.isMovable, "backgroundMovable": candidate.isMovableByWindowBackground,
            "activationPolicy": NSApp.activationPolicy().rawValue]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
    }
    private func configureOrdinaryWindow(_ window: NSWindow) {
        window.collectionBehavior = [.primary, .managed, .participatesInCycle, .fullScreenNone, .fullScreenDisallowsTiling]
        window.level = .normal; window.hidesOnDeactivate = false
        // Content dragging belongs to the explicit header gesture. Do not also
        // let AppKit treat the entire hosting view as a draggable background;
        // content hit testing must not redefine the system titlebar's drag area.
        window.isMovable = true; window.isMovableByWindowBackground = false
        if windowPreview {
            for (key, name) in [(\NSWindow.isMovable, "movable"), (\NSWindow.isMovableByWindowBackground, "background-movable")] {
                movementObservations.append(window.observe(key, options: [.old, .new]) { [weak self] candidate, change in
                    guard change.oldValue != change.newValue else { return }
                    let event = name + ":" + String(change.oldValue == true) + "->" + String(change.newValue == true)
                    Task { @MainActor [weak self, weak candidate] in
                        if let candidate { self?.traceWindow(event, candidate) }
                    }
                })
            }
        }
    }
    private func showOrdinaryWindows() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }
    private func updateWindowPresentation() {
        // Stage Manager and Spaces may temporarily hide windows. Only explicit
        // app presentation/close actions change this set, not OS visibility.
        if !presentedWindows.isEmpty { showOrdinaryWindows() }
        else if !popover.isShown, !terminationPending, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    @objc func closeFrontWindow(_ sender: Any?) {
        let target = windowForCloseCommand
        if popover.isShown, target == nil || target === popover.contentViewController?.view.window {
            popover.performClose(sender)
        } else { target?.performClose(sender) }
    }
    private var windowForCloseCommand: NSWindow? {
        if let modal = NSApp.modalWindow { return modal }
        if let key = NSApp.keyWindow, key.isVisible, !key.isMiniaturized { return key }
        // Closing a popover can briefly leave keyWindow unset. Only fall back
        // to one of our explicitly presented, visible ordinary windows.
        let eligible: (NSWindow) -> Bool = {
            self.presentedWindows.contains(ObjectIdentifier($0)) && $0.isVisible && !$0.isMiniaturized
        }
        if let main = NSApp.mainWindow, eligible(main) { return main }
        return NSApp.orderedWindows.first(where: eligible)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeFrontWindow(_:)) { return windowForCloseCommand != nil || popover.isShown }
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening resumes the existing flow, never stacks a menu card over the guide.
        if let stage = pendingOnboardingStage { showOnboarding(stage: stage, allowActivation: true) }
        else if model.onboardingVisible, onboardingWindow != nil { showOnboarding(stage: model.onboardingStage, allowActivation: true) }
        else { showManagement(allowActivation: true) }
        return true
    }
    private func activateForUserRequest() {
        if #available(macOS 14, *) { NSApp.activate() }
        else { _ = NSRunningApplication.current.activate(options: []) }
    }
    private func presentOrdinaryWindow(_ candidate: NSWindow, allowActivation: Bool) {
        presentedWindows.insert(ObjectIdentifier(candidate))
        requestedKeyWindow = candidate
        candidate.orderFront(nil)
        // Let popover dismissal and the accessory-to-regular transition finish
        // before requesting keyboard focus for the ordinary window.
        DispatchQueue.main.async { [weak self, weak candidate] in
            guard let self, let candidate,
                  self.presentedWindows.contains(ObjectIdentifier(candidate)), candidate.isVisible else { return }
            if allowActivation { self.activateForUserRequest() }
            self.focusRequestedWindow()
            self.traceWindow("shown", candidate)
        }
    }
    private func focusRequestedWindow() {
        guard NSApp.isActive, !popover.isShown, let candidate = requestedKeyWindow,
              presentedWindows.contains(ObjectIdentifier(candidate)), candidate.isVisible, !candidate.isMiniaturized else { return }
        candidate.makeMain()
        candidate.makeKeyAndOrderFront(nil)
    }
    @objc func openManagement() { showManagement(allowActivation: true) }
    func showManagement(allowActivation: Bool = false) {
        if popover.isShown {
            afterPopoverClose = { [weak self] in self?.showManagement(allowActivation: allowActivation) }
            popover.performClose(nil)
            return
        }
        showOrdinaryWindows()
        popover.performClose(nil)
        if window == nil {
            let controller = NSHostingController(rootView: ManagementView(model: model))
            let window = LocaleShiftWindow(contentRect: NSRect(origin: .zero, size: AppLayout.mainSize), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "LocaleShift"; window.contentViewController = controller; window.isReleasedWhenClosed = false
            configureOrdinaryWindow(window); window.delegate = self
            window.minSize = AppLayout.mainMinimumSize; window.center(); self.window = window
        }
        if let window { presentOrdinaryWindow(window, allowActivation: allowActivation) }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        // Preserve a different window the user has already explicitly selected.
        if NSApp.keyWindow == nil || NSApp.keyWindow === requestedKeyWindow { focusRequestedWindow() }
        model.returnedToApp()
    }
    func applicationDidResignActive(_ notification: Notification) { popover.performClose(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateCancel }
        guard model.repository != nil else { return .terminateNow }
        let baseline = model.baseline
        // A normal OS logout/restart supplies a quit-reason attribute. Never cancel that flow with our own confirmation.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let attribute = event?.attributeDescriptor(forKeyword: AEKeyword(0x7768793f))?.enumCodeValue
        let parameter = event?.paramDescriptor(forKeyword: AEKeyword(0x7768793f))?.enumCodeValue
        let quitReason = attribute ?? parameter ?? 0
        let operatingSystemQuit = systemEnding || [UInt32(0x71756961), 0x73687574, 0x72657374, 0x726c676f, 0x6c6f676f].contains(quitReason)
        if model.busy {
            if operatingSystemQuit { return .terminateNow } // Durable operation intent and independent services retain duty.
            model.message = "请等待当前操作结束后再退出。"; showPopover(); return .terminateCancel
        }
        let readOnlyWithoutDuty = (model.isolated || model.registrationLoaded && !model.serviceRegistration.trustedSignature || !VerifiedCapabilities.current.canApply) && model.session == nil && !model.recordError && model.history.allSatisfy { $0.completedAt != nil }
        if !operatingSystemQuit {
            let alert = NSAlert(); alert.messageText = "退出 LocaleShift？"
            if readOnlyWithoutDuty {
                alert.informativeText = "当前为只读模式，没有待恢复会话。退出不会修改系统设置。"
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "退出")
            } else if let baseline {
                alert.informativeText = "退出前将恢复保存的系统默认配置：\n\n" + SettingField.allCases.map { "\($0.label)：\($0.value(baseline.settings, model: model))" }.joined(separator: "\n")
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "恢复系统默认并退出")
            } else {
                alert.informativeText = "尚未保存系统默认配置，本次没有通过应用修改系统。"
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "退出")
            }
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        if readOnlyWithoutDuty { return .terminateNow }
        guard let baseline else { return .terminateNow }
        onboardingWindow?.orderOut(nil); model.onboardingVisible = false; model.route = .home
        terminationPending = true; model.busy = true; model.message = "正在恢复系统默认，核验完成后退出…"
        showPopover()
        Task { @MainActor in
            do {
                let actual = try NativePreferences.read()
                if model.session != nil || !actual.matches(baseline.settings) {
                    _ = try await model.perform(UserRequest(.restore, confirmedActual: operatingSystemQuit ? nil : actual))
                }
                guard try NativePreferences.read().matches(baseline.settings) else { throw CoreError(.readbackMismatch) }
                terminationPending = false; model.busy = false; sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminationPending = false; model.busy = false; model.message = "恢复尚未完成：\(error.localizedDescription)"
                // OS logout/restart must proceed; durable journals and services retain recovery duty.
                sender.reply(toApplicationShouldTerminate: operatingSystemQuit)
                if !operatingSystemQuit { showPopover() }
            }
        }
        return .terminateLater
    }
}

#if LOCALESHIFT_LOCAL_DEVELOPMENT
if let index = CommandLine.arguments.firstIndex(of: "--local-command") {
    guard CommandLine.arguments.indices.contains(index + 1) else { exit(64) }
    let command = CommandLine.arguments[index + 1]
    Task {
        do { try await LocalDevelopmentCommands.run(command); exit(0) }
        catch { fputs("Local test: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
    exit(1)
}
#endif
if CommandLine.arguments.contains("--diagnostics") {
    let actual = try NativePreferences.read()
    let statusIcon = AppBranding.makeStatusIcon()
    let result: [String: Any] = ["role": "application", "protocolVersion": RuntimePaths.protocolVersion,
        "actual": try JSONSerialization.jsonObject(with: JSONEncoder().encode(actual)),
        "trustedSignature": PeerTrust.canModifySystem, "localDevelopment": RuntimePaths.localDevelopment,
        "build": RuntimePaths.developmentBuild ?? "production", "bundle": RuntimePaths.applicationBundle.path,
        "foundationBundle": Bundle.main.bundleURL.path, "foundationBundleID": Bundle.main.bundleIdentifier ?? "unknown",
        "supportedLanguages": NativePreferences.supportedLanguages(), "systemWritesPerformed": false,
        "statusIconResource": AppBranding.statusIconURL?.path ?? "unavailable",
        "statusIconAvailable": statusIcon != nil, "statusIconTemplate": statusIcon?.isTemplate == true,
        "appIconAvailable": Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); exit(0)
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
