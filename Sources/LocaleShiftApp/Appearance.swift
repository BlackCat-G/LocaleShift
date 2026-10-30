import AppKit
import SwiftUI

/// Shared reading scale. Supporting text remains readable instead of shrinking to fit.
enum AppType {
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 13)
    static let label = Font.system(size: 15, weight: .medium)
    static let emphasis = Font.system(size: 16, weight: .semibold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let sectionTitle = Font.system(size: 22, weight: .semibold)
    static let pageTitle = Font.system(size: 28, weight: .semibold)
}

/// Attach the native gesture directly to the header, including its transparent
/// space. A background NSView can miss SwiftUI hit testing and activation events.
struct WindowHeaderDrag: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents()
        } else {
            content.background(LegacyWindowDragArea())
        }
    }
}

private struct LegacyWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// A readable disclosure indicator with the entire heading as its click target.
struct AppDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label.font(AppType.label)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 28)
            }
        }
    }
}

enum AppLayout {
    static let cardWidth: CGFloat = 420
    static var cardHeight: CGFloat { min(620, max(1, (NSScreen.main?.visibleFrame.height ?? 800) - 70)) }
    static var mainSize: NSSize {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1_440, height: 900)
        return NSSize(width: min(1_000, max(1, available.width - 80)), height: min(760, max(1, available.height - 80)))
    }
    static var mainMinimumSize: NSSize { NSSize(width: min(920, mainSize.width), height: min(680, mainSize.height)) }
    static let onboardingWidth: CGFloat = 460

    static func onboardingHeight(compact: Bool, availableHeight: CGFloat? = nil) -> CGFloat {
        let available = availableHeight ?? NSScreen.main?.visibleFrame.height ?? 800
        return min(compact ? 480 : 560, max(1, available - 100))
    }

    /// Sheets fit inside the actual parent content area, including a comfortable border.
    static func editorSize(in parent: CGSize, defaultEditor: Bool = false) -> CGSize {
        CGSize(width: min(640, max(1, parent.width - 80)),
               height: min(defaultEditor ? 560 : 620, max(1, parent.height - 100)))
    }
}
