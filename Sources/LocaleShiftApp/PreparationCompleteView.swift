import SwiftUI

struct PreparationCompleteView: View {
    @ObservedObject var model: AppModel
    var celebrate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var returningToPreview: Bool { model.selectedProfile != nil }
    private var actionTitle: String {
        returningToPreview ? "返回切换预览" : model.profiles.isEmpty ? "添加第一套设置" : "查看已保存的设置"
    }
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.blue.opacity(0.07)).frame(width: 104, height: 104)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 62, weight: .medium)).foregroundStyle(.blue)
                    .accessibilityHidden(true)
                if celebrate && !reduceMotion, let startedAt = model.preparationCompletedAt {
                    PreparationConfetti(startedAt: startedAt)
                }
            }.frame(maxWidth: .infinity).frame(height: 124)
            VStack(spacing: 10) {
                Text("准备完成！").font(.system(size: 26, weight: .semibold))
                Text(returningToPreview ? "可以回到预览，核对后应用这套设置。" : model.profiles.isEmpty ? "恭喜，可以开始添加第一套设置了。" : "恭喜，可以选择一套设置开始使用了。")
                    .font(AppType.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                completionRow("系统默认配置", value: "已保存")
                completionRow("自动时区", value: "已由你确认关闭")
            }.padding(14).background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            VStack(spacing: 12) {
                Button(actionTitle) { model.continueAfterPreparation() }.buttonStyle(PrimaryButton())
                Button("先查看当前设置") { model.continueAfterPreparation(showCurrentSettings: true) }
                    .buttonStyle(.plain).foregroundStyle(.blue).frame(minHeight: 28)
            }
            Text("还没有切换系统设置。应用不会自动检测或更改自动时区开关。")
                .font(AppType.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.bottom, 4)
    }
    private func completionRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(AppType.label)
        }.font(AppType.body)
    }
}

/// A single, short burst inside the success illustration. Absolute elapsed time
/// prevents replay when clocks refresh or the same preparation window is reopened.
struct PreparationConfetti: View {
    let startedAt: Date
    @State private var finished = false
    static let duration: TimeInterval = 2.2
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: finished)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                guard elapsed >= 0, elapsed < Self.duration else { return }
                let colors: [Color] = [.blue, .mint, .orange, .purple]
                for index in 0..<36 {
                    let time = elapsed - Double(index % 6) * 0.025
                    guard time >= 0 else { continue }
                    let seed = Double((index * 17) % 37) / 36
                    let direction = index.isMultiple(of: 2) ? -1.0 : 1.0
                    let x = size.width / 2 + direction * (16 + (45 + seed * 105) * time)
                    let y = size.height * 0.6 - (90 + seed * 85) * time + 140 * time * time
                    var particle = context
                    particle.opacity = min(1, max(0, (Self.duration - time) * 1.5))
                    particle.translateBy(x: x, y: y)
                    particle.rotate(by: .degrees(Double(index * 29) + direction * time * 220))
                    particle.fill(Path(roundedRect: CGRect(x: -2.5, y: -4, width: 5, height: 8), cornerRadius: 1), with: .color(colors[index % colors.count]))
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
            .task(id: startedAt) {
                let remaining = max(0, Self.duration - Date().timeIntervalSince(startedAt))
                if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                if !Task.isCancelled { finished = true }
            }
    }
}
