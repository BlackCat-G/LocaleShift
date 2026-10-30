import SwiftUI
import LocaleShiftCore
import LocaleShiftSystem

struct CardView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Label("LocaleShift", systemImage: "arrow.left.arrow.right").font(AppType.label); Spacer(); Text(model.clockLabel).font(AppType.caption).foregroundStyle(.blue).lineLimit(1) }.padding(16)
            if model.route == .home, let notice = model.settingsNotice {
                SettingsResultBanner(result: notice).padding(.horizontal, 12).padding(.bottom, 12)
            }
            Group {
                if model.route == .all { allProfiles.padding(18) }
                else { ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.route {
                    case .home: home
                    case .all: allProfiles
                    case .preview: preview
                    case .baseline: BaselineSetup(model: model)
                    case .guide:
                        if model.preparationCompletedAt != nil { PreparationCompleteView(model: model) }
                        else { guide }
                    }
                    if let message = model.message { Text(message).font(.system(size: 13)).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)) }
                    if model.busy {
                        HStack { ProgressView().controlSize(.small); Text("正在核验设置，请稍候…").font(AppType.caption) }
                        if let operation = model.history.first(where: { $0.completedAt == nil }) { ForEach(operation.steps) { step in Text(step.field.label + "：" + step.state.chinese).font(AppType.caption).foregroundStyle(.secondary) } }
                    }
                }.padding(18).padding(.bottom, 12)
                }.mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
                    }
                }.id(model.route) }
            }.disabled(model.busy).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18)).padding([.horizontal, .bottom], 12)
            if model.route == .home { homeActions.padding(.horizontal, 18).padding(.bottom, 14) }
            if model.route == .preview { previewActions.padding(.horizontal, 18).padding(.bottom, 14) }
        }.frame(width: AppLayout.cardWidth, height: AppLayout.cardHeight).font(AppType.body).background(Color(nsColor: .windowBackgroundColor)).disclosureGroupStyle(AppDisclosureStyle())
            .environment(\.locale, Locale(identifier: "zh-Hans-CN"))
    }
    @ViewBuilder var home: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.statusTitle).font(.system(size: 20, weight: .semibold))
            if model.settingsNotice == nil {
                Text(model.session?.state == .working ? "首选语言已设置" : model.session == nil ? "显示系统实际设置" : "恢复尚未完成，工作切换已暂停").font(AppType.caption).foregroundStyle(.secondary)
            }
        }
        if let actual = model.actual {
            ClockPair(model: model, target: actual.timeZone)
            SettingsFields(model: model, settings: actual)
        }
        if model.recordError {
            RecoveryPanel(model: model)
        } else if model.baseline == nil {
            Text("先保存系统默认配置，以便退出或异常后恢复完整的语言顺序、地区和时区。").font(AppType.body).foregroundStyle(.secondary)

        } else {
            Divider()
            HStack { Text("切换到其他设置").font(.system(size: 15, weight: .semibold)); Spacer(); Button("管理设置") { model.managementPage = "已保存的设置"; model.showManagement?() }.buttonStyle(.plain).foregroundStyle(.blue).font(AppType.caption) }
            if model.profiles.isEmpty { Text("按国家或地区添加设置，语言会自动推荐。").font(AppType.caption).foregroundStyle(.secondary) }
            ForEach(model.recentProfiles) { profile in profileRow(profile, from: .home) }
            if model.session != nil && (model.session?.state != .working || !model.protection.available) {
                RecoveryPanel(model: model)
            }


        }
    }
    var allProfiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.route = .home } label: { Label("返回当前设置", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.blue)
            Text("全部设置（\(model.profiles.count)）").font(AppType.title)
            ScrollView { VStack(spacing: 14) { ForEach(model.profiles) { profile in profileRow(profile, from: .all) } } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Button { model.edit() } label: { Label("添加设置", systemImage: "plus") }.buttonStyle(SecondaryButton())
                Button("恢复系统默认") { model.beginRestore() }.buttonStyle(SecondaryButton())
            }
        }
    }
    func profileRow(_ profile: WorkProfile, from: CardRoute) -> some View {
        Button { model.beginPreview(profile, from: from) } label: {
            HStack(spacing: 10) {
                Text(IdentifierNormalizer.countryCode(profile.region)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.blue).frame(width: 36, height: 36).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) { Text(profile.title).font(AppType.label); Text("系统语言：\(model.languageName(profile.language))").font(.system(size: 13)).foregroundStyle(.secondary) }
                Spacer()
                if model.currentProfile?.id == profile.id { Text("当前").font(AppType.caption).foregroundStyle(.blue) } else { Image(systemName: "chevron.right").font(AppType.caption).foregroundStyle(.secondary) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder var preview: some View {
        if let preview = model.preview {
            Button { model.back() } label: { Label("返回", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.blue)
            Text(model.selectedProfile == nil ? "恢复系统默认" : "切换预览").font(AppType.caption).foregroundStyle(.secondary)
            Text(preview.title).font(AppType.title)
            ClockPair(model: model, target: preview.target.timeZone, isPreview: true)
            ForEach(SettingField.allCases, id: \.self) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(AppType.caption).foregroundStyle(.secondary)
                    Text("当前：" + field.value(preview.actual, model: model)).font(AppType.caption).foregroundStyle(.secondary)
                    Text("目标：" + field.value(preview.target, model: model) + (preview.actual.matches(preview.target, field: field) ? " · 保持不变" : "")).font(AppType.label)
                }
            }
            Text("系统语言会影响应用优先使用的语言，部分应用需要重新打开；地区影响日期、数字和货币格式；时区影响整台 Mac 的系统时钟，包括其他登录用户。").font(AppType.caption).foregroundStyle(.secondary)

            if model.selectedProfile == nil, model.session?.error?.code == .externalChange { Text("检测到外部调整。确认恢复会覆盖预览中显示的当前值。").font(AppType.caption).foregroundStyle(.orange) }
        }
    }
    @ViewBuilder var homeActions: some View {
        VStack(spacing: 10) {
            if model.baseline == nil && !model.recordError {
                Button("确认系统默认配置") { model.baselineCandidate = model.actual; model.route = .baseline }.buttonStyle(PrimaryButton())
                Button("稍后设置，先管理配置") { model.showManagement?() }.buttonStyle(.plain).font(AppType.caption)
            } else {
                if model.baseline != nil {
                    if model.profiles.count > 3 { Button("查看全部 \(model.profiles.count) 套设置") { model.route = .all }.buttonStyle(.plain).font(AppType.caption).foregroundStyle(.blue) }
                    HStack(spacing: 10) {
                        Button { model.edit() } label: { Label("添加设置", systemImage: "plus") }.buttonStyle(SecondaryButton())
                        Button("恢复系统默认") { model.beginRestore() }.buttonStyle(SecondaryButton()).disabled(model.recordError)
                    }
                }
                if model.baseline != nil && !model.preparation.userConfirmed {
                    Button("切换前，还需关闭自动时区 · 继续设置") { model.route = .guide; model.guideOpened = false; model.guideReturned = false; model.showGuideSteps = false }.buttonStyle(.plain).font(AppType.caption).foregroundStyle(.blue)
                }
                HStack { Button("偏好与恢复") { model.managementPage = "偏好设置"; model.showManagement?() }; Spacer(); Button("退出…") { model.requestQuit?() } }.buttonStyle(.plain).font(AppType.caption).foregroundStyle(.secondary)
            }
        }.disabled(model.busy)
    }
    @ViewBuilder var previewActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.selectedProfile != nil, let blocker = model.systemModificationBlocker {
                Text(blocker).font(AppType.caption).foregroundStyle(.secondary)
                Button("暂不能切换系统设置") {}.buttonStyle(SecondaryButton()).disabled(true)
                Button("查看启用说明") { model.managementPage = "偏好设置"; model.showManagement?() }.buttonStyle(.plain).foregroundStyle(.blue)
            } else if model.selectedProfile != nil && (!model.preparation.userConfirmed || model.baseline == nil) {
                Button("继续使用前准备") { model.applyPreview() }.buttonStyle(PrimaryButton())
            } else if !model.protection.available && model.selectedProfile != nil {
                Text(model.protection.message).font(AppType.caption).foregroundStyle(.secondary)
                Button("启用后台恢复") { model.enableProtection() }.buttonStyle(SecondaryButton())
                Button("打开后台项目设置") { Services.openLoginItems() }.buttonStyle(.plain).foregroundStyle(.blue)
            } else {
                Button(model.selectedProfile == nil ? "确认恢复系统默认" : "应用这套设置") { model.applyPreview() }.buttonStyle(PrimaryButton()).disabled(model.busy || model.selectedProfile != nil && model.blocked)
            }
        }.disabled(model.busy)
    }
    @ViewBuilder var guide: some View {
        Text("使用前准备 · 第 2 步，共 2 步").font(AppType.caption).foregroundStyle(.secondary)
        Text(model.guideReturned ? "确认时区设置" : "关闭自动时区").font(AppType.title)
        Text(model.guideReturned ? "如果你已关闭“使用你的当前位置自动设定时区”，无需重复操作，直接继续即可。" : "避免 Mac 根据当前位置，把你选择的时区改回去。").font(AppType.body)
        if model.guideReturned {
            Button("已关闭，继续") { model.confirmPreparation() }.buttonStyle(PrimaryButton()).disabled(model.busy)
            DisclosureGroup("查看操作步骤", isExpanded: $model.showGuideSteps) { VStack(spacing: 12) { guideInstructions.padding(.top, 8); Button("重新打开日期与时间设置") { model.openGuideSettings() }.buttonStyle(SecondaryButton()) } }
            Text("继续后显示准备完成页。仅记录你的确认，不会自动检测或切换系统设置。").font(AppType.caption).foregroundStyle(.secondary)
        } else {
            guideInstructions
            Button("打开日期与时间设置") { model.openGuideSettings() }.buttonStyle(PrimaryButton())
            Button("我已关闭自动时区") { model.confirmPreparation() }.buttonStyle(SecondaryButton()).disabled(model.busy)
        }
        Button("稍后设置") { model.deferOnboarding() }.buttonStyle(.plain).foregroundStyle(.blue).frame(maxWidth: .infinity)
        Text("恢复只还原语言顺序、地区和固定时区，自动时区由你管理。").font(AppType.caption).foregroundStyle(.secondary)
    }
    var guideInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1  打开系统设置 → 通用 → 日期与时间")
            Text("2  关闭“使用你的当前位置自动设定时区”")
            Text("3  保留“自动设定时间与日期”的当前设置")
            Text("英文界面对照：Set time zone automatically using your current location").font(AppType.caption).foregroundStyle(.secondary)
        }.font(AppType.body).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClockPair: View {
    @ObservedObject var model: AppModel
    var target: String
    var isPreview = false
    var body: some View {
        if let zone = model.baseline?.settings.timeZone ?? model.actual?.timeZone,
           let snapshot = try? DualClock.snapshot(instant: model.now, baselineZone: zone, targetZone: target) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    tile("系统默认时间", reading: snapshot.baseline, tinted: false)
                    tile(isPreview ? "目标时间 · 预览" : "当前系统时间", reading: snapshot.target, tinted: true)
                }
                Text(snapshot.differenceText.replacingOccurrences(of: "目标地区", with: snapshot.target.city).replacingOccurrences(of: "系统默认地区", with: snapshot.baseline.city) + (snapshot.relativeDayDifference == 0 ? " · 今天（相对默认地区）" : snapshot.relativeDayDifference > 0 ? " · \(snapshot.relativeDayDifference == 1 ? "明天" : "目标日期晚 \(snapshot.relativeDayDifference) 天")" : " · \(snapshot.relativeDayDifference == -1 ? "昨天" : "目标日期早 \(-snapshot.relativeDayDifference) 天")")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }
    func tile(_ title: String, reading: ClockReading, tinted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13)).foregroundStyle(tinted ? Color.blue : Color.secondary)
            Text(reading.city).font(AppType.label).lineLimit(1)
            Text(String(reading.timeText.prefix(5))).font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
            Text(reading.dateText).font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading).background(tinted ? Color.blue.opacity(0.07) : Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct SettingsFields: View {
    @ObservedObject var model: AppModel
    var settings: SystemSettings
    var body: some View {
        VStack(spacing: 12) {
            row("系统语言", value: settings.languages.map(model.languageName).joined(separator: "、"), meaning: "系统菜单和应用优先使用的语言，按顺序回退")
            row("地区格式", value: model.countryName(settings.region), meaning: "影响日期、数字、货币等显示格式")
            row("系统时区", value: model.timeZoneDescription(settings.timeZone), meaning: "系统时间按该城市的时区显示")
        }
    }
    func row(_ title: String, value: String, meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(AppType.body)
            Text(meaning).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}
extension SettingField {
    var label: String { switch self { case .languages: return "系统语言顺序"; case .region: return "地区格式"; case .timeZone: return "系统时区" } }
    @MainActor func value(_ settings: SystemSettings, model: AppModel) -> String {
        switch self { case .languages: return settings.languages.map(model.languageName).joined(separator: " → "); case .region: return model.countryName(settings.region) + "（\(settings.region)）"; case .timeZone: return model.timeZoneDescription(settings.timeZone) }
    }
}
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(AppType.label).frame(maxWidth: .infinity).padding(.vertical, 11).foregroundStyle(.white).background(Color.blue.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 9)).opacity(configuration.isPressed ? 0.85 : 1) }
}
struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(AppType.body).frame(maxWidth: .infinity).padding(.vertical, 10).background(Color(nsColor: .controlBackgroundColor).opacity(configuration.isPressed ? 0.4 : 0.8), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.gray.opacity(0.2))) }
}

struct RecoveryPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text(model.busy ? "正在恢复 / 核验" : "待恢复 · 请核对实际值与默认目标").font(AppType.emphasis)
            if let session = model.session { Text("上次目标：" + session.targetTitle).font(AppType.caption); if let error = session.error { Text(error.message).font(AppType.caption).foregroundStyle(.orange) } }
            if let baseline = model.baseline {
                ForEach(SettingField.allCases, id: \.self) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(field.label).font(AppType.caption); Spacer(); Text(model.actual.map { $0.matches(baseline.settings, field: field) ? "已核验一致" : "尚未恢复" } ?? "无法读取").font(AppType.caption).foregroundStyle(.secondary) }
                        Text((model.recordError ? "备份证据（需人工核验）：" : "恢复目标：") + field.value(baseline.settings, model: model)).font(AppType.caption).textSelection(.enabled)
                    }
                }
            } else { Text("无法确定可靠的恢复目标，请保留本地记录；不要把当前工作设置保存为新的默认。").font(AppType.caption).foregroundStyle(.orange) }
            if let date = model.lastVerifiedAt { Text("最近核验：" + model.formatDate(date)).font(AppType.caption).foregroundStyle(.secondary) }
            Button("重新检查恢复结果") { model.recheckRecovery() }.buttonStyle(SecondaryButton()).disabled(model.busy)
            Button("重新授权并恢复") { model.beginRestore() }.buttonStyle(SecondaryButton()).disabled(model.busy || model.recordError)
            Button("暂不恢复") { model.pauseRecovery() }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.busy)
            Text("手动恢复：系统设置 → 通用 → 语言与地区，恢复完整语言顺序和地区；日期与时间中恢复保存的固定时区。自动时区由你管理。").font(AppType.caption).foregroundStyle(.secondary)
            Button("打开语言与地区设置") { Services.openLanguageAndRegion() }.buttonStyle(SecondaryButton())
            Button("打开日期与时间设置") { Services.openDateAndTime() }.buttonStyle(SecondaryButton())
        }
    }
}

struct OnboardingWindowView: View {
    @ObservedObject var model: AppModel
    var celebratePreparation = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Label("LocaleShift", systemImage: "arrow.left.arrow.right"); Spacer(); Text(model.clockLabel).foregroundStyle(.blue) }.font(AppType.caption).padding(18).modifier(WindowHeaderDrag())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.preparationCompletedAt != nil { PreparationCompleteView(model: model, celebrate: celebratePreparation).transition(.opacity) }
                    else if model.onboardingStage == .baseline { BaselineSetup(model: model) }
                    else { CardView(model: model).guide }
                    if let message = model.message { Text(message).font(AppType.caption).foregroundStyle(.secondary) }
                    if model.busy { ProgressView().controlSize(.small) }
                }.padding(22).disabled(model.busy)
            }.background(Color(nsColor: .controlBackgroundColor))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.preparationCompletedAt != nil)
        }.frame(width: AppLayout.onboardingWidth, height: AppLayout.onboardingHeight(compact: model.preparationCompletedAt == nil && model.onboardingStage == .guide && model.guideReturned && !model.showGuideSteps)).background(Color(nsColor: .windowBackgroundColor)).font(AppType.body).controlSize(.large).disclosureGroupStyle(AppDisclosureStyle()).environment(\.locale, Locale(identifier: "zh-Hans-CN"))
    }
}
