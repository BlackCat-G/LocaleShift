import SwiftUI
import AppKit
import LocaleShiftCore
import LocaleShiftSystem

struct ManagementView: View {
    @ObservedObject var model: AppModel
    @State private var editingDefault = false
    var body: some View {
        GeometryReader { geometry in
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text("LocaleShift").font(AppType.sectionTitle).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 24).modifier(WindowHeaderDrag())
                ForEach(["概览", "已保存的设置", "系统默认配置", "偏好设置", "操作记录"], id: \.self) { page in
                    Button { model.managementPage = page } label: {
                        Text(page)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(model.managementPage == page ? Color.blue.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer(); Text("macOS · 本地配置").font(AppType.caption).foregroundStyle(.secondary)
            }.padding(20).frame(width: 210).background(Color.gray.opacity(0.05))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack { Text(model.managementPage).font(AppType.pageTitle); Spacer(); if model.busy { ProgressView().controlSize(.small) } }.modifier(WindowHeaderDrag())
                    switch model.managementPage {
                    case "已保存的设置": profiles
                    case "系统默认配置": defaults
                    case "偏好设置": preferences
                    case "操作记录": history
                    default: overview
                    }
                    if let message = model.message { Text(message).font(AppType.body).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
                }.padding(32)
            }
        }.font(AppType.body).controlSize(.large).disclosureGroupStyle(AppDisclosureStyle()).disabled(model.busy)
            .environment(\.locale, Locale(identifier: "zh-Hans-CN"))
            .sheet(item: $model.editor) { draft in ProfileEditor(model: model, draft: draft, size: AppLayout.editorSize(in: geometry.size)) }
            .sheet(isPresented: $editingDefault) { BaselineSetup(model: model, editing: true, afterSave: { editingDefault = false }, scrollContent: true).padding(24).frame(width: AppLayout.editorSize(in: geometry.size, defaultEditor: true).width, height: AppLayout.editorSize(in: geometry.size, defaultEditor: true).height).font(AppType.body).controlSize(.large) }
        }.frame(minWidth: AppLayout.mainMinimumSize.width, minHeight: AppLayout.mainMinimumSize.height).background(Color(nsColor: .windowBackgroundColor))
    }
    @ViewBuilder var overview: some View {
        Text(model.statusTitle).font(AppType.sectionTitle)
        if let notice = model.settingsNotice { SettingsResultBanner(result: notice).frame(maxWidth: 550) }
        if let actual = model.actual { ClockPair(model: model, target: actual.timeZone).frame(maxWidth: 430); SettingsFields(model: model, settings: actual).frame(maxWidth: 550) }
        HStack { Label(model.protection.available ? "后台恢复可用" : "后台恢复尚未就绪", systemImage: model.protection.available ? "checkmark.shield" : "shield"); Spacer() }.foregroundStyle(model.protection.available ? Color.green : Color.secondary)
        Text(model.protection.message).font(AppType.body).foregroundStyle(.secondary)
        if model.session != nil { Text("目标配置：" + (model.session?.targetTitle ?? "未知")).font(AppType.emphasis); if let target = model.session?.target { SettingsFields(model: model, settings: target) }; if model.session?.state != .working || !model.protection.available { RecoveryPanel(model: model) } }
        if model.baseline == nil { Text("请从菜单栏卡片确认系统默认配置，再进行使用前准备。首次打开只读取设置。").foregroundStyle(.secondary) }
        HStack {
            Button("管理配置") { model.managementPage = "已保存的设置" }
            if model.baseline != nil { Button("恢复系统默认") { model.beginRestore(); (NSApp.delegate as? AppDelegate)?.showPopover() } }
        }
    }
    var profiles: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("选择国家或地区，自动推荐系统语言。可保存多套设置。").foregroundStyle(.secondary); Spacer(); Button("添加一套设置") { model.edit() }.buttonStyle(.borderedProminent) }
            if model.profiles.isEmpty { ContentUnavailable("还没有保存的设置", text: "添加后可以在菜单栏预览并切换。", symbol: "globe") }
            ForEach(model.profiles) { profile in
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(profile.title).font(AppType.emphasis); if model.currentProfile?.id == profile.id { Text("当前生效").font(AppType.caption).foregroundStyle(.blue) }; Spacer() }
                    Text("系统语言：\(model.languageName(profile.language))  ·  \(model.timeZoneDescription(profile.timeZone))").font(AppType.body).foregroundStyle(.secondary)
                    HStack {
                        Button("预览切换") { model.beginPreview(profile); (NSApp.delegate as? AppDelegate)?.showPopover() }
                        Button("编辑") { model.edit(profile) }
                        Button("复制") { model.edit(profile, duplicate: true) }
                        Spacer(); Button("删除", role: .destructive) { model.deleteProfile(profile) }
                    }
                }.padding(18).background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    @ViewBuilder var defaults: some View {
        if let baseline = model.baseline {
            Text("退出和异常恢复时使用这份已保存的配置，不会随工作切换自动更新。").foregroundStyle(.secondary)
            SettingsFields(model: model, settings: baseline.settings)
            Text("保存于 \(model.formatDate(baseline.confirmedAt)) · \(baseline.source)").font(AppType.caption).foregroundStyle(.secondary)
            Button("编辑系统默认配置…") { model.baselineCandidate = baseline.settings; editingDefault = true }.disabled(model.session != nil || model.busy || model.recordError)
            Button("用当前系统设置更新默认配置…") {
                do {
                    guard model.session == nil, try model.repository?.restartIntent() == nil,
                          try model.repository?.operations().allSatisfy({ $0.completedAt != nil }) != false else { throw CoreError(.sessionUnresolved) }
                    let actual = try NativePreferences.read()
                    let alert = NSAlert(); alert.messageText = "更新系统默认配置？"
                    alert.informativeText = SettingField.allCases.map { "\($0.label)：\n\($0.value(baseline.settings, model: model)) → \($0.value(actual, model: model))" }.joined(separator: "\n\n")
                    alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "确认更新")
                    if alert.runModal() == .alertSecondButtonReturn { model.saveBaseline(actual) }
                } catch { model.message = error.localizedDescription }
            }.disabled(model.session != nil || model.busy || model.recordError)
            Text("编辑只改变保存的恢复目标，不立即修改系统。存在工作会话或待恢复操作时，必须先恢复系统默认。").font(AppType.caption).foregroundStyle(.secondary)
        } else { BaselineSetup(model: model).frame(maxWidth: 560) }
    }
    var preferences: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Text("菜单栏显示").font(AppType.emphasis)
                Picker("时间", selection: $model.clockStyle) { Text("系统默认日期和时间").tag(0); Text("默认日期时间 + 当前时间").tag(1) }.pickerStyle(.segmented)
                    .onChange(of: model.clockStyle) { value in UserDefaults.standard.set(value, forKey: "menuClockStyle") }
            }
            Toggle("登录时打开菜单栏应用", isOn: Binding(get: { model.serviceRegistration.loginEnabled }, set: { value in model.run { try await Services.setLoginEnabledInBackground(value); await model.refreshRegistration() } })).disabled(model.isolated || !model.registrationLoaded)
            Text("登录打开应用与后台恢复分别管理。关闭菜单栏自启动不会清除待恢复记录。").font(AppType.caption).foregroundStyle(.secondary)
            Divider()
            Text("使用前准备").font(AppType.emphasis)
            Text(model.preparation.userConfirmed ? "自动时区：已由用户确认关闭" : "自动时区：尚未确认").font(AppType.body)
            Text("应用不读取或修改自动时区开关，也不更改网络校时。").font(AppType.caption).foregroundStyle(.secondary)
            Button("查看自动时区设置引导") {
                model.selectedProfile = nil; model.preview = nil
                if model.baseline == nil { model.baselineCandidate = model.actual; model.route = .baseline } else { model.selectedProfile = nil; model.preview = nil; model.route = .guide; model.guideOpened = false; model.guideReturned = false; model.showGuideSteps = false }
            }
            Button("重新设置时区准备") { model.resetPreparation() }.disabled(model.busy || model.baseline == nil)
            Divider()
            Text("恢复保护").font(AppType.emphasis)
            Text(model.protection.message).font(AppType.body).foregroundStyle(.secondary)
            if let blocker = model.systemModificationBlocker {
                Text(blocker).font(AppType.body).foregroundStyle(.secondary)
                if RuntimePaths.localDevelopment {
                    Text("本机测试版：仅限批准安装时的用户和固定程序版本。更新前须恢复系统默认并停用旧服务。无需安装完整 Xcode。").font(AppType.caption).foregroundStyle(.secondary)
                } else if !model.isolated && model.registrationLoaded && !model.serviceRegistration.trustedSignature {
                    Text("开发启用步骤：配置 Apple Development 等有效签名，用同一身份重新签名主应用与两个服务，再批准后台恢复。仅开启登录项不能补齐签名。").font(AppType.caption).foregroundStyle(.secondary)
                    Link("查看 Apple 签名证书配置说明", destination: URL(string: "https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html")!)
                }
            }
            if !model.isolated && model.serviceRegistration.trustedSignature { Button("打开后台项目设置") { Services.openLoginItems() } }
            Button("重启 Mac…") { model.requestRestart() }.disabled(model.busy || model.recordError || model.isolated)
            Text("本机暂不开放重启后自动继续工作。普通注销或重启将恢复系统默认配置；重新登录后可重新预览并切换。").font(AppType.body).foregroundStyle(.secondary)
        }
    }
    var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button("导出本地诊断…") { model.exportDiagnostics() }
            Text("保留最近 50 条已结束记录，未解决的恢复记录持续保留。").font(AppType.body).foregroundStyle(.secondary)
            if model.history.isEmpty { ContentUnavailable("还没有操作记录", text: "系统切换和恢复后会显示逐项核验结果。", symbol: "clock.arrow.circlepath") }
            ForEach(model.history) { operation in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(operation.steps) { step in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(step.field.label)：\(step.state.chinese)" + (step.error.map { " · " + $0.message } ?? "")).font(AppType.caption)
                                Text("目标：" + step.field.value(operation.target, model: model)).font(AppType.caption).foregroundStyle(.secondary)
                                Text("读回：" + (step.readback.map { step.field.value($0, model: model) } ?? "尚无核验结果")).font(AppType.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let error = operation.error { Text(error.message).foregroundStyle(.orange) }
                        Text("操作编号：\(operation.id.uuidString)").font(AppType.caption).textSelection(.enabled)
                    }.padding(.vertical, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 4) { Text("\(operation.title) · \(operation.state.chinese)").font(AppType.emphasis); Text(model.formatDate(operation.createdAt)).font(AppType.caption).foregroundStyle(.secondary) }
                }.padding().background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct BaselineSetup: View {
    @ObservedObject var model: AppModel
    var editing = false
    var afterSave: (() -> Void)?
    var scrollContent = false
    @State private var expanded = false
    @State private var languages = ""
    @State private var region = ""
    @State private var zone = ""
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing ? "修改保存的恢复目标" : "使用前准备 · 第 1 步，共 2 步").font(AppType.caption).foregroundStyle(.secondary)
            Text(editing ? "编辑系统默认配置" : "确认系统默认配置").font(AppType.title)
            Text("这是恢复时使用的完整设置。请确认它就是你希望回到的语言、地区和时区。").font(AppType.body).foregroundStyle(.secondary)
            if let actual = model.baselineCandidate ?? model.actual { SettingsFields(model: model, settings: actual) }
            DisclosureGroup("修正保存内容", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("语言顺序（逗号分隔，如 zh-Hans-CN,en-US）", text: $languages)
                    TextField("地区标识，如 zh_CN", text: $region)
                    TextField("时区标识，如 Asia/Shanghai", text: $zone)
                    Text("仅修正将保存的恢复基准，保存不会立即修改系统。").font(AppType.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(.top, 8)
            }
        }
    }
    private var actions: some View {
        VStack(spacing: 12) {
            Button("确认并保存系统默认配置") {
                let value = expanded ? SystemSettings(languages: languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, region: region, timeZone: zone) : model.baselineCandidate ?? model.actual
                if let value {
                    if editing, let old = model.baseline {
                        let alert = NSAlert(); alert.messageText = "更新系统默认配置？"
                        alert.informativeText = "之后的恢复目标会改变，保存本身不会修改系统。\n\n" + SettingField.allCases.map { "\($0.label)：\n\($0.value(old.settings, model: model)) → \($0.value(value, model: model))" }.joined(separator: "\n\n")
                        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "确认更新")
                        guard alert.runModal() == .alertSecondButtonReturn else { return }
                    }
                    model.saveBaseline(value, afterSave: afterSave)
                }
            }.buttonStyle(PrimaryButton()).disabled(model.busy)
            Button(editing ? "取消" : "稍后设置") { if editing { afterSave?() } else { model.deferOnboarding() } }.buttonStyle(.plain).foregroundStyle(.blue).frame(maxWidth: .infinity)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if scrollContent { ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) } }
            else { content }
            actions
        }.font(AppType.body).disclosureGroupStyle(AppDisclosureStyle()).onAppear {
            let value = model.baselineCandidate ?? model.actual
            expanded = editing
            languages = value?.languages.joined(separator: ",") ?? ""; region = value?.region ?? ""; zone = value?.timeZone ?? ""
        }
    }
}

struct ProfileEditor: View {
    @ObservedObject var model: AppModel
    @State var draft: ProfileDraft
    var size: CGSize = CGSize(width: 640, height: 620)
    @State private var advanced = false
    @State private var recommendation = ""
    @State private var manuallyAdjusted = false
    @State private var recommending = false
    @State private var error: String?
    private var zones: [String] { model.catalog.regions.first { $0.countryCode == draft.country }?.timeZones ?? [] }
    private var duplicate: WorkProfile? { model.profiles.first { $0.id != draft.profileID && IdentifierNormalizer.language($0.language) == IdentifierNormalizer.language(draft.language) && IdentifierNormalizer.canonicalRegion($0.region) == IdentifierNormalizer.canonicalRegion(draft.profile.region) && (try? IdentifierNormalizer.timeZone($0.timeZone)) == (try? IdentifierNormalizer.timeZone(draft.timeZone)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(draft.isEditing ? "编辑设置" : "添加一套设置").font(AppType.sectionTitle)
                Text("选择国家或地区，自动推荐语言和首都所在时区；你也可以改选其他城市。").font(AppType.body).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 18) {
            CountrySearchPicker(regions: model.catalog.regions, selection: $draft.country)
                .onChange(of: draft.country) { country in
                let result = model.catalog.recommendation(countryCode: country, currentLanguages: model.actual?.languages ?? [])
                if manuallyAdjusted {
                    let alert = NSAlert(); alert.messageText = "更换地区会更新推荐设置"
                    alert.informativeText = "你已调整高级选项。是否采用新地区的语言、地区格式和时区推荐？"
                    alert.addButton(withTitle: "保留高级设置"); alert.addButton(withTitle: "采用新推荐")
                    if alert.runModal() == .alertFirstButtonReturn { recommendation = "已保留手动调整的高级设置。"; return }
                }
                recommending = true
                draft.language = result.language ?? ""; draft.formatRegion = country; draft.timeZone = result.selectedTimeZone ?? ""
                recommendation = result.explanation + (Set(result.languageCandidates.map { $0.split(separator: "-").first ?? "" }).count > 1 ? "该地区使用多种语言，可在高级设置中调整。" : "")
                manuallyAdjusted = false
                DispatchQueue.main.async { recommending = false }
            }
            CityTimeZonePicker(model: model, country: draft.country, zones: zones, selection: $draft.timeZone)

            if !draft.country.isEmpty { Text(model.catalog.recommendation(countryCode: draft.country, currentLanguages: model.actual?.languages ?? []).timeZoneExplanation).font(AppType.caption).foregroundStyle(.secondary) }
            Text("系统语言：\(draft.language.isEmpty ? "待选择地区" : model.languageName(draft.language))").font(AppType.emphasis)
            Text(recommendation).font(AppType.caption).foregroundStyle(.secondary)
            DisclosureGroup("高级设置", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("系统语言", selection: $draft.language) { Text("请选择受支持的语言").tag(""); ForEach(model.catalog.supportedLanguages, id: \.self) { language in Text(model.languageName(language) + " · " + language).tag(language) } }
                    Picker("地区格式", selection: $draft.formatRegion) { Text("跟随地区推荐").tag(""); ForEach(model.catalog.regions) { country in Text(country.name).tag(country.countryCode) } }
                    Picker("独立时区", selection: $draft.timeZone) { Text("请选择").tag(""); ForEach(Array(Set(model.catalog.regions.flatMap(\.timeZones))).sorted(), id: \.self) { zone in Text(model.timeZoneDescription(zone) + " · " + model.localTime(zone) + " · " + zone).tag(zone) } }
                    Text("目标语言排到首位，其他语言保留原顺序。高级选项可独立组合，更换地区前会确认是否覆盖。").font(AppType.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            if !draft.country.isEmpty && !draft.timeZone.isEmpty { Text(draft.profile.title).font(AppType.emphasis); Text("名称自动生成，无需输入。系统语言显示在副标题中。").font(AppType.caption).foregroundStyle(.secondary)
                if let actual = model.actual, let target = try? draft.profile.applying(to: actual) { SettingsFields(model: model, settings: target); Text(formatSample(target)).font(AppType.caption).foregroundStyle(.secondary); Text("已有的独立格式覆盖项可能影响实际显示。").font(AppType.caption).foregroundStyle(.secondary) }
            }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
            if let duplicate { Text("已经保存过相同的语言、地区和时区设置").font(AppType.body).foregroundStyle(.orange); Button("查看已保存的设置") { model.editor = nil; model.managementPage = "已保存的设置"; model.message = "已保存：" + duplicate.title + " · " + model.languageName(duplicate.language) } }
            if let message = model.message { Text(message).foregroundStyle(.orange).font(AppType.body) }
            if let error { Text(error).foregroundStyle(.orange).font(AppType.body) }
            HStack {
                Button("取消") { model.editor = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存设置") {
                    guard !draft.language.isEmpty, !draft.country.isEmpty, !draft.timeZone.isEmpty else { error = "请完整选择地区、系统语言和城市。"; return }
                    model.saveProfile(draft.profile)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(duplicate != nil || draft.language.isEmpty || draft.timeZone.isEmpty || model.busy)
            }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)).font(AppType.body).controlSize(.large).disclosureGroupStyle(AppDisclosureStyle()).environment(\.locale, Locale(identifier: "zh-Hans-CN"))
            .onChange(of: draft.language) { _ in if !recommending { manuallyAdjusted = true } }
            .onChange(of: draft.formatRegion) { _ in if !recommending { manuallyAdjusted = true } }
            .onChange(of: draft.timeZone) { _ in if advanced && !recommending { manuallyAdjusted = true } }
            .onAppear { if !draft.country.isEmpty { recommendation = model.catalog.recommendation(countryCode: draft.country, currentLanguages: model.actual?.languages ?? []).explanation } }
    }
    func formatSample(_ target: SystemSettings) -> String {
        let date = DateFormatter(); date.locale = Locale(identifier: target.region); date.timeZone = TimeZone(identifier: target.timeZone); date.dateStyle = .medium
        let number = NumberFormatter(); number.locale = Locale(identifier: target.region); number.numberStyle = .decimal
        return "格式预览：" + date.string(from: model.now) + " · " + (number.string(from: 12345.67) ?? "")
    }
}
/// Inline search avoids a screen-height menu of untranslated timezone identifiers.
struct CityTimeZonePicker: View {
    @ObservedObject var model: AppModel
    var country: String
    var zones: [String]
    @Binding var selection: String
    @State private var query = ""
    @State private var browsing = false
    @State private var chosenPlace: TimeZoneSearchResult?
    @FocusState private var searchFocused: Bool
    private var capital: CapitalTimeZone? { model.catalog.recommendation(countryCode: country, currentLanguages: model.actual?.languages ?? []).capital }
    private var available: [String] { Array(Set(zones + (selection.isEmpty ? [] : [selection]))) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var results: [TimeZoneSearchResult] { TimeZonePlaceSearch.results(countryCode: country, zones: available, query: query, capital: capital) }
    private var selectedTitle: String {
        if let chosenPlace, chosenPlace.timeZone == selection { return chosenPlace.title }
        let city = ProfileTitle.city(selection)
        if let capital, capital.timeZone == selection { return "\(capital.city)（\(capital.kind)） · " + city }
        return city
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("城市／州与时区").font(AppType.label)
            if !selection.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedTitle).font(AppType.label)
                    Text(detail(zone: selection, generic: TimeZone(identifier: selection)?.localizedName(for: .generic, locale: Locale(identifier: "zh-Hans-CN")) ?? "")).font(AppType.caption).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            }
            HStack(spacing: 8) {
                TextField(country.isEmpty ? "请先选择国家或地区" : "搜索州或城市，如弗吉尼亚、Virginia、纽约", text: $query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused).accessibilityIdentifier("city-search")
                    .onSubmit { if searching && results.count == 1 { choose(results[0]) } }
                if !query.isEmpty { Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除城市搜索") }
            }.disabled(country.isEmpty)
            if searching {
                if results.isEmpty { Text("未找到匹配地点，请尝试城市中文名、英文名或时区名称。").font(AppType.caption).foregroundStyle(.secondary) }
                else { Text("找到 \(results.count) 个时区，点击选择").font(AppType.caption).foregroundStyle(.secondary); resultList }
            } else if !country.isEmpty {
                DisclosureGroup("浏览全部 \(available.count) 个时区", isExpanded: $browsing) { resultList }
            }
            if country == "US" { Text("州名用于查找，配置按对应时区保存。跨时区的州请按具体城市选择。").font(AppType.caption).foregroundStyle(.secondary) }
        }.onChange(of: country) { _ in query = ""; browsing = false; chosenPlace = nil }
            .onChange(of: selection) { zone in if chosenPlace?.timeZone != zone { chosenPlace = nil } }
    }
    private func detail(zone: String, generic: String) -> String {
        "\(generic) · \(model.timeZoneDescription(zone)) · \(model.localTime(zone))"
    }
    private func choose(_ result: TimeZoneSearchResult) {
        selection = result.timeZone
        chosenPlace = result
        query = ""; browsing = false; searchFocused = false
    }
    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { result in
                    Button { choose(result) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top) { Text(result.title).font(AppType.label); Spacer(); if selection == result.timeZone { Image(systemName: "checkmark").foregroundStyle(.blue) } }
                            if !result.coverage.isEmpty { Text(result.coverage).font(AppType.caption).foregroundStyle(.secondary).lineLimit(2) }
                            Text(detail(zone: result.timeZone, generic: result.genericName)).font(AppType.caption).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("city-result-" + result.timeZone)
                    Divider()
                }
            }
        }.frame(height: min(210, CGFloat(results.count) * (searching ? 100 : 76)))
            .background(Color.blue.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.gray.opacity(0.15)))
    }
}
/// Search results are visible and actionable without opening a second control.
struct CountrySearchPicker: View {
    var regions: [RegionEntry]
    @Binding var selection: String
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private let english = Locale(identifier: "en-US")
    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [RegionEntry] {
        if let exactCode = regions.first(where: { $0.countryCode.caseInsensitiveCompare(term) == .orderedSame }) { return [exactCode] }
        return regions.filter {
            $0.name.localizedStandardContains(term)
                || $0.countryCode.localizedCaseInsensitiveContains(term)
                || (english.localizedString(forRegionCode: $0.countryCode) ?? "").localizedStandardContains(term)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("搜索国家或地区（中文、英文或代码）", text: $query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityIdentifier("country-search")
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("清除国家搜索")
                }
            }
            if !term.isEmpty {
                if matches.isEmpty {
                    Text("没有找到匹配的国家或地区，请尝试其他名称或国家代码。").font(AppType.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("country-search-empty")
                } else {
                    Text("找到 \(matches.count) 个结果，点击选择").font(AppType.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches) { country in
                                Button {
                                    selection = country.countryCode
                                    query = ""; searchFocused = false
                                } label: {
                                    HStack {
                                        Text(country.name + "（\(country.countryCode)）")
                                        Spacer()
                                        if selection == country.countryCode { Image(systemName: "checkmark").foregroundStyle(.blue) }
                                    }.font(AppType.body).padding(.horizontal, 12)
                                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("country-result-" + country.countryCode)
                            }
                        }
                    }.frame(height: min(160, CGFloat(matches.count) * 40))
                        .background(Color.blue.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.gray.opacity(0.15)))
                }
            }
            Picker("国家或地区", selection: $selection) {
                Text("请选择").tag("")
                ForEach(regions) { country in Text(country.name + "（\(country.countryCode)）").tag(country.countryCode) }
            }
        }
    }
}
struct ContentUnavailable: View {
    var title: String; var text: String; var symbol: String
    init(_ title: String, text: String, symbol: String) { self.title = title; self.text = text; self.symbol = symbol }
    var body: some View { VStack(spacing: 12) { Image(systemName: symbol).font(.largeTitle).foregroundStyle(.blue); Text(title).font(AppType.emphasis); Text(text).font(AppType.body).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(50) }
}
extension StepState {
    var chinese: String { switch self { case .pending: return "待执行"; case .intentSaved: return "已保存写入意图"; case .verified: return "已读回核验"; case .rollbackIntentSaved: return "已保存回滚意图"; case .rolledBack: return "已回滚"; case .failed: return "待处理" } }
}
extension OperationState {
    var chinese: String { switch self { case .recorded: return "已记录"; case .executing: return "执行中"; case .verifying: return "核验中"; case .completed: return "已完成"; case .rollingBack: return "回滚中"; case .rolledBack: return "已回滚"; case .needsAttention: return "需要处理" } }
}
