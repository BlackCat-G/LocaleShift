import SwiftUI

enum SettingsResult: Equatable {
    case applied, restored
    var title: String { self == .applied ? "设置已切换" : "已恢复系统默认" }
    var detail: String {
        self == .applied
            ? "系统语言偏好已保存。部分应用需**退出并重新打开**，界面语言才会更新。"
            : "语言顺序、地区和时区已恢复。部分应用需**重新打开**，界面语言才会更新。"
    }
}

/// Kept outside the card's scrolling details so the result and next step stay visible.
struct SettingsResultBanner: View {
    let result: SettingsResult
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(result.title).font(.system(size: 17, weight: .semibold))
                Text(LocalizedStringKey(result.detail)).font(AppType.body).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.25), lineWidth: 1))
            .accessibilityElement(children: .combine)
    }
}
