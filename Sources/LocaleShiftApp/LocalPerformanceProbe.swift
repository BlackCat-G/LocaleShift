import AppKit
import SwiftUI
import LocaleShiftCore
import LocaleShiftSystem

struct LocalPerformanceReport: Encodable {
    var navigationUpdates: Int
    var maximumTickGapMilliseconds: Double
    var p95TickGapMilliseconds: Double
    var maximumLayoutMilliseconds: Double
    var windowWasVisible: Bool
}

/// Read-only local acceptance: actual SwiftUI views and background service checks,
/// rendered in an unordered window. No button that changes settings is invoked.
enum LocalPerformanceProbe {
    @MainActor static func run(iterations: Int = 120, switchPages: Bool = true) async throws -> LocalPerformanceReport {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !model.registrationLoaded {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CoreError(.transientUnavailable) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        model.managementPage = "偏好设置"
        let host = NSHostingView(rootView: ManagementView(model: model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: AppLayout.mainSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = NSRect(origin: .zero, size: AppLayout.mainSize)
        defer { window.contentView = nil }
        var gaps: [Double] = [], layoutMaximum = 0.0
        var previous = ProcessInfo.processInfo.systemUptime
        for index in 0..<iterations {
            try await Task.sleep(nanoseconds: 16_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            gaps.append((now - previous) * 1_000)
            previous = now
            if switchPages { model.managementPage = index.isMultiple(of: 2) ? "偏好设置" : "已保存的设置" }
            let start = ProcessInfo.processInfo.systemUptime
            host.layoutSubtreeIfNeeded()
            layoutMaximum = max(layoutMaximum, (ProcessInfo.processInfo.systemUptime - start) * 1_000)
            if index.isMultiple(of: switchPages ? 20 : 300) { Task { await model.refresh() } }
            guard !window.isVisible else { throw CoreError(.invalidTarget, detail: "Performance window must remain hidden.") }
        }
        let sorted = gaps.sorted()
        return LocalPerformanceReport(navigationUpdates: gaps.count, maximumTickGapMilliseconds: sorted.last ?? 0,
            p95TickGapMilliseconds: sorted[Int(Double(sorted.count - 1) * 0.95)],
            maximumLayoutMilliseconds: layoutMaximum, windowWasVisible: window.isVisible)
    }
}
