import Foundation
import SwiftUI
import AppKit
import Darwin
import UniformTypeIdentifiers
import LocaleShiftCore
import LocaleShiftSystem

@MainActor final class AppModel: ObservableObject {
    @Published var recordError = false
    @Published var actual: SystemSettings?
    @Published var baseline: DefaultBaseline?
    @Published var session: WorkSession?
    @Published var profiles: [WorkProfile] = []
    @Published var history: [OperationRecord] = []
    @Published var preparation = TimezonePreparation()
    @Published var protection = ProtectionStatus(available: false)
    @Published var message: String?
    @Published var settingsResult: SettingsResult?
    @Published var busy = false
    @Published private(set) var serviceRegistration = ServiceRegistrationStatus()
    @Published private(set) var registrationLoaded = false
    @Published var now = Date()
    @Published var route: CardRoute = .home
    @Published var preview: SwitchPreview?
    @Published var selectedProfile: WorkProfile?
    @Published var editor: ProfileDraft?
    @Published var managementPage = "概览"
    @Published var lastVerifiedAt: Date?
    @Published var onboardingVisible = false
    @Published var preparationCompletedAt: Date?
    @Published var onboardingStage: CardRoute = .baseline
    @Published var guideOpened = false
    @Published var guideReturned = false
    @Published var showGuideSteps = false
    @Published var clockStyle: Int = UserDefaults.standard.integer(forKey: "menuClockStyle")
    @Published var baselineCandidate: SystemSettings?
    let repository: Repository?
    let catalog = RegionCatalog(supportedLanguages: NativePreferences.supportedLanguages())
    let isolated: Bool
    let dataDirectory: URL
    var showManagement: (() -> Void)?
    var requestQuit: (() -> Void)?
    var onboardingFinished: ((Bool) -> Void)?
    private var progressTimer: Timer?
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var refreshing = false
    private var registrationGeneration = 0
    private var operationGeneration = 0
    private var origin: CardRoute = .home

    init() {
        let args = CommandLine.arguments
        let index = args.firstIndex(of: "--data-directory")
        let override = index.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        isolated = override != nil
        dataDirectory = override.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? RuntimePaths.userData
        do { repository = try Repository(directory: dataDirectory) }
        catch { repository = nil; recordError = true; message = "本地记录无法读取：\(error.localizedDescription)" }
        loadLocal()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, self.busy, let repository = self.repository else { return }
            if let operations = try? repository.operations() { self.history = operations }
            if let session = try? repository.activeSession() { self.session = session }
        } }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.now = Date() } }
        Task { await refresh() }
    }
    var systemModificationBlocker: String? {
        if isolated { return "当前使用独立演示记录，只能预览和管理配置，不能修改系统设置。" }
        if !registrationLoaded { return "正在检查后台恢复，请稍候…" }
        if !serviceRegistration.trustedSignature { return RuntimePaths.localDevelopment ? "请先安装经管理员批准的本机测试版，再从安装位置打开。工作目录中的副本只能预览。" : "当前开发包缺少受信任的开发签名，不能修改系统语言、地区和时区。需要完成签名并重新构建。" }
        if !VerifiedCapabilities.current.canApply { return "当前系统版本尚未通过切换验收，暂不能修改系统设置。" }
        return nil
    }
    var serviceReady: Bool { !isolated && registrationLoaded && serviceRegistration.ready }
    func refreshRegistration() async {
        guard !isolated else { registrationLoaded = true; return }
        registrationGeneration += 1
        let generation = registrationGeneration
        let fresh = await Services.statusInBackground()
        guard generation == registrationGeneration else { return }
        if serviceRegistration != fresh { serviceRegistration = fresh }
        if !registrationLoaded { registrationLoaded = true }
    }
    var settingsNotice: SettingsResult? {
        guard !busy, !recordError, message == nil, let actual else { return nil }
        if let session, session.state == .working, actual.matches(session.target) { return .applied }
        if settingsResult == .restored, session == nil, let baseline, actual.matches(baseline.settings) { return .restored }
        return nil
    }
    var currentProfile: WorkProfile? {
        guard let actual else { return nil }
        return profiles.first { profile in
            IdentifierNormalizer.language(actual.languages.first ?? "") == IdentifierNormalizer.language(profile.language) &&
            IdentifierNormalizer.countryCode(actual.region) == IdentifierNormalizer.countryCode(profile.region) &&
            (try? IdentifierNormalizer.timeZone(actual.timeZone)) == (try? IdentifierNormalizer.timeZone(profile.timeZone))
        }
    }
    var statusTitle: String {
        if recordError { return "恢复记录需要人工核验" }
        if let session, session.state != .working { return "需要处理恢复" }
        if let actual, let baseline, actual.matches(baseline.settings), session == nil { return "系统默认配置" }
        return currentProfile?.title ?? (baseline == nil ? "欢迎使用 LocaleShift" : "当前系统设置")
    }
    var recentProfiles: [WorkProfile] { Array(profiles.filter { $0.id != currentProfile?.id }.prefix(3)) }
    var blocked: Bool { busy || recordError || repository == nil || (session != nil && session?.state != .working) }
    var clockLabel: String {
        let zone = baseline?.settings.timeZone ?? actual?.timeZone ?? TimeZone.current.identifier
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh-Hans-CN")
        formatter.timeZone = TimeZone(identifier: zone); formatter.dateFormat = "M月d日 HH:mm"
        let first = formatter.string(from: now)
        guard clockStyle == 1, let actual, actual.timeZone != zone else { return first }
        formatter.timeZone = TimeZone(identifier: actual.timeZone); formatter.dateFormat = "HH:mm"
        return ProfileTitle.city(zone) + " " + first + " · " + ProfileTitle.city(actual.timeZone) + " " + formatter.string(from: now)
    }
    func loadLocal() {
        do {
            actual = try NativePreferences.read(); lastVerifiedAt = Date()
            if let repository {
                baseline = try repository.baseline(); session = try repository.activeSession()
                profiles = try repository.profiles(); history = try repository.operations()
                preparation = try repository.timezonePreparation(); recordError = false
            }
            protection = ProtectionStatus(available: false, message: isolated ? "本次使用独立演示记录，系统修改未开放。" : !registrationLoaded ? "正在检查后台恢复…" : !serviceRegistration.trustedSignature ? "当前开发包尚未通过身份核验，已保存的设置和时间查看仍可使用。" : VerifiedCapabilities.current.canApply ? "尚未启用后台恢复。" : "此系统版本尚未通过系统修改验收，当前只开放配置查看与管理。")
        } catch {
            if let error = error as? CoreError, error.code == .busy { return }
            message = "本地记录无法核验：" + error.localizedDescription
            if let error = error as? CoreError, error.code == .dataCorrupt || error.code == .persistence {
                recordError = true; baseline = (try? Repository.verifiedRecoverySnapshot(directory: dataDirectory))?.baseline
            } else { actual = nil }
        }
    }
    func consume(_ snapshot: AgentSnapshot) {
        recordError = snapshot.requiresManualVerification || snapshot.error?.code == .dataCorrupt || snapshot.error?.code == .persistence
        actual = snapshot.actual; if actual != nil { lastVerifiedAt = Date() }; baseline = snapshot.baseline; session = snapshot.session
        profiles = snapshot.profiles; history = snapshot.history; preparation = snapshot.preparation
        protection = snapshot.protection
        if let error = snapshot.error { message = error.message }
    }
    func refresh() async {
        guard !refreshing, !busy else { return }; refreshing = true; defer { refreshing = false }
        let generation = operationGeneration
        await refreshRegistration()
        guard !busy, generation == operationGeneration else { return }
        if serviceReady {
            do {
                let result = try await XPCClient.user(UserRequest(.status))
                guard !busy, generation == operationGeneration else { return }
                if let snapshot = result.snapshot { consume(snapshot) }; if let error = result.error { message = error.message }
            } catch {
                guard !busy, generation == operationGeneration else { return }
                protection = ProtectionStatus(available: false, message: "后台恢复暂不可用，请检查登录项。"); message = error.localizedDescription
            }
        } else { loadLocal() }
    }
    func perform(_ request: UserRequest) async throws -> UserReply {
        guard !recordError else { throw CoreError(.dataCorrupt) }
        guard !isolated else { throw CoreError(.capabilityUnavailable) }
        await refreshRegistration() // Fresh authorization for actions; UI snapshots never grant writes.
        if request.action == .apply, !VerifiedCapabilities.current.canApply { throw CoreError(.capabilityUnavailable, detail: "此系统版本尚未通过系统修改验收，当前只开放配置查看与管理。") }
        if request.action == .restore, !serviceReady {
            return try await emergencyRestore(request)
        }
        guard serviceReady else { throw CoreError(.protectionUnavailable, detail: "请先启用后台恢复，再修改系统设置。") }
        let reply: UserReply
        do { reply = try await XPCClient.user(request) }
        catch {
            if request.action == .restore { return try await emergencyRestore(request) }
            throw error
        }
        if let snapshot = reply.snapshot { consume(snapshot) }
        if let error = reply.error { throw error }
        if let operation = reply.operation, !operation.succeeded { throw operation.error ?? CoreError(.readbackMismatch) }
        return reply
    }
    private func emergencyRestore(_ request: UserRequest) async throws -> UserReply {
        let fresh = await Services.statusInBackground()
        guard let repository, fresh.trustedSignature,
              fresh.timezoneService == 1,
              let process = ProcessInspector.identity(pid: getpid()) else { throw CoreError(.protectionUnavailable) }
        // The shared engine takes the same cross-process lock. It cannot race an active agent writer.
        let engine = SwitchEngine(repository: repository,
            adapter: MacSystemAdapter(repository: repository, allowExternalRestore: request.confirmedActual != nil),
            process: process, capabilities: VerifiedCapabilities.current)
        let operation = try await engine.restore(confirmedActual: request.confirmedActual)
        let snapshot = AgentSnapshot(await engine.status(), history: try repository.operations())
        consume(snapshot)
        guard operation.succeeded else { throw operation.error ?? CoreError(.readbackMismatch) }
        return UserReply(snapshot: snapshot, operation: operation)
    }
    func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; operationGeneration += 1; busy = true; message = nil; settingsResult = nil
        Task { do { try await action() } catch { message = error.localizedDescription }; busy = false; await refresh() }
    }
    func beginPreview(_ profile: WorkProfile, from: CardRoute = .home) {
        do {
            let actual = try NativePreferences.read(); self.actual = actual
            preview = SwitchPreview(actual: actual, target: try profile.applying(to: actual), title: profile.title)
            selectedProfile = profile; origin = from; route = .preview; message = nil
        } catch { message = error.localizedDescription }
    }
    func beginRestore(from: CardRoute? = nil) {
        do {
            guard let baseline else { throw CoreError(.baselineMissing) }
            let actual = try NativePreferences.read(); self.actual = actual
            preview = SwitchPreview(actual: actual, target: baseline.settings, title: "系统默认配置")
            selectedProfile = nil; origin = from ?? (route == .all ? .all : .home); route = .preview; message = nil
        } catch { message = error.localizedDescription }
    }
    func back() { route = origin; preview = nil; selectedProfile = nil }
    func applyPreview() {
        guard let preview else { return }
        if selectedProfile != nil {
            guard baseline != nil else { baselineCandidate = actual; route = .baseline; return }
            guard preparation.userConfirmed else { route = .guide; guideReturned = false; guideOpened = false; return }
        }
        run { [self] in
            let reply: UserReply
            do { reply = try await perform(UserRequest(selectedProfile == nil ? .restore : .apply,
                profile: selectedProfile, confirmedActual: preview.actual)) }
            catch {
                if let error = error as? CoreError, [.previewChanged, .externalChange].contains(error.code), let fresh = try? NativePreferences.read() {
                    self.actual = fresh
                    self.preview = SwitchPreview(actual: fresh, target: selectedProfile.flatMap { try? $0.applying(to: fresh) } ?? self.baseline?.settings ?? preview.target, title: preview.title)
                    throw CoreError(error.code, detail: "当前值已变化，预览已重新读取。请核对后再次确认。")
                }
                throw error
            }
            if reply.operation?.succeeded == true {
                settingsResult = selectedProfile == nil ? .restored : .applied
                route = .home; self.preview = nil; message = nil; selectedProfile = nil
            }
        }
    }
    func saveBaseline(_ settings: SystemSettings, afterSave: (() -> Void)? = nil) {
        let hadBaseline = baseline != nil
        run { [self] in
            guard let repository else { throw CoreError(.dataCorrupt) }
            if serviceReady { _ = try await perform(UserRequest(.saveBaseline, settings: settings)) }
            else { baseline = try repository.saveBaseline(settings: settings, source: "用户明确确认") }
            route = hadBaseline ? .home : .guide
            afterSave?()
        }
    }
    func confirmPreparation() {
        run { [self] in
            guard let repository, baseline != nil else { throw CoreError(.baselineMissing) }
            if serviceReady { _ = try await perform(UserRequest(.confirmPreparation)) }
            else { let lock = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lock.unlock() }; try repository.saveTimezonePreparation(TimezonePreparation(userConfirmed: true, confirmedAt: Date())) }
            preparation = try repository.timezonePreparation()
            guard preparation.userConfirmed else { throw CoreError(.preparationRequired) }
            // Keep the preparation window open until the user chooses their next step.
            // The timestamp makes celebration finite and prevents replay on refresh/reopen.
            message = nil; preparationCompletedAt = Date()
        }
    }
    func continueAfterPreparation(showCurrentSettings: Bool = false) {
        guard preparationCompletedAt != nil, preparation.userConfirmed, !busy else { return }
        let nextProfile = showCurrentSettings ? nil : selectedProfile
        preparationCompletedAt = nil; onboardingVisible = false
        if let nextProfile { beginPreview(nextProfile, from: origin) }
        else { route = .home; preview = nil; selectedProfile = nil }
        onboardingFinished?(nextProfile != nil || showCurrentSettings)
        if nextProfile == nil && !showCurrentSettings {
            managementPage = "已保存的设置"
            if profiles.isEmpty { edit() } else { showManagement?() }
        }
    }
    func enableProtection() {
        run { [self] in
            guard !isolated else { throw CoreError(.capabilityUnavailable, detail: "独立演示模式只能管理本地配置。") }
            guard VerifiedCapabilities.current.canApply else { throw CoreError(.capabilityUnavailable) }
            try await Services.registerProtectionInBackground()
            await refreshRegistration()
            if !serviceReady { Services.openLoginItems(); message = "请在系统设置中允许 LocaleShift 的后台恢复。批准后返回并重新查看预览。" }
        }
    }
    func saveProfile(_ profile: WorkProfile) {
        run { [self] in
            guard let repository else { throw CoreError(.dataCorrupt) }
            if serviceReady { _ = try await perform(UserRequest(.saveProfile, profile: profile)) }
            else { _ = try repository.saveProfile(profile) }
            profiles = try repository.profiles(); editor = nil
        }
    }
    func deleteProfile(_ profile: WorkProfile) {
        let alert = NSAlert(); alert.messageText = "删除\(profile.title)？"
        alert.informativeText = "只删除保存的配置。当前系统设置和系统默认配置不会改变。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        run { [self] in
            guard let repository else { throw CoreError(.dataCorrupt) }
            if serviceReady { _ = try await perform(UserRequest(.deleteProfile, profileID: profile.id)) }
            else { try repository.deleteProfile(id: profile.id) }
            profiles = try repository.profiles()
        }
    }
    func openGuideSettings() {
        guideOpened = Services.openDateAndTime(); guideReturned = false; showGuideSteps = false
        if !guideOpened { message = "无法打开日期与时间，请从系统设置 → 通用手动进入。" }
    }
    func returnedToApp() { if preparationCompletedAt == nil, guideOpened, route == .guide || onboardingVisible && onboardingStage == .guide { guideReturned = true; showGuideSteps = false }; Task { await refresh() } }
    func deferOnboarding() {
        preparationCompletedAt = nil; onboardingVisible = false; route = .home; preview = nil; selectedProfile = nil
        onboardingFinished?(false)
    }
    func resetPreparation() {
        run { [self] in
            guard let repository else { throw CoreError(.dataCorrupt) }
            if serviceReady { _ = try await perform(UserRequest(.clearPreparation)) }
            else { let lock = try CrossProcessLock(url: repository.lockURL).acquire(); defer { lock.unlock() }; try repository.saveTimezonePreparation(TimezonePreparation()) }
            preparation = TimezonePreparation(); preparationCompletedAt = nil; selectedProfile = nil; preview = nil; route = .guide; guideReturned = false; guideOpened = false; showGuideSteps = false
        }
    }
    func recheckRecovery() {
        run { [self] in
            let fresh = try NativePreferences.read(); actual = fresh; lastVerifiedAt = Date()
            guard let baseline else { throw CoreError(.baselineMissing) }
            guard fresh.matches(baseline.settings) else { throw CoreError(.readbackMismatch, detail: "仍有项目与系统默认配置不同，请按下方目标继续手动恢复。") }
            if recordError {
                message = "实际值与可验证的备份证据一致。主记录仍需人工核验，恢复责任尚未关闭。"
                return
            }
            if session != nil {
                // The common restore flow skips matching fields but still verifies records and releases ownership.
                _ = try await perform(UserRequest(.restore, confirmedActual: fresh))
            }
            message = "三项实际值已恢复并核验。自动时区仍由你管理。"
        }
    }
    func pauseRecovery() {
        run { [self] in
            guard repository != nil else { throw CoreError(.dataCorrupt) }
            if serviceReady { _ = try await perform(UserRequest(.pauseRecovery)) }
            else { throw CoreError(.protectionUnavailable, detail: "后台无法确认暂停，请保留待恢复记录并先手动核对默认设置。") }
        }
    }
    func requestRestart() {
        let alert = NSAlert(); alert.messageText = "重新启动 Mac？"
        alert.informativeText = "将先恢复保存的系统默认配置，再请求系统正常重启。其他应用仍可取消重启。本机暂不开放重启后自动继续工作。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "恢复默认并请求重启")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        run { [self] in
            if let baseline {
                let current = try NativePreferences.read()
                if session != nil || !current.matches(baseline.settings) { _ = try await perform(UserRequest(.restore, confirmedActual: current)) }
                guard try NativePreferences.read().matches(baseline.settings) else { throw CoreError(.readbackMismatch) }
            }
            try Services.requestNormalRestart()
            message = "已请求系统正常重启。如被其他应用取消，将保留已恢复的系统默认配置。"
        }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "LocaleShift-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var payload: [String: Any] = ["appVersion": "0.1.0", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "protection": protection.message, "recordNeedsVerification": recordError, "exportedAt": ISO8601DateFormatter().string(from: Date())]
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            payload["operations"] = try JSONSerialization.jsonObject(with: encoder.encode(history))
            if let actual { payload["actual"] = try JSONSerialization.jsonObject(with: encoder.encode(actual)) }
            if let baseline { payload["savedDefault"] = try JSONSerialization.jsonObject(with: encoder.encode(baseline)) }
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            message = "本地诊断已导出，未上传。"
        } catch { message = error.localizedDescription }
    }
    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh-Hans-CN")
        formatter.timeZone = TimeZone(identifier: baseline?.settings.timeZone ?? actual?.timeZone ?? "Etc/UTC")
        formatter.dateFormat = "yyyy年M月d日 HH:mm:ss"; return formatter.string(from: date)
    }
    func localTime(_ zone: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh-Hans-CN"); formatter.timeZone = TimeZone(identifier: zone); formatter.dateFormat = "HH:mm"; return formatter.string(from: now)
    }
    func edit(_ profile: WorkProfile? = nil, duplicate: Bool = false) {
        message = nil
        editor = ProfileDraft(profile: profile, duplicate: duplicate)
        showManagement?()
    }
    func timeZoneDescription(_ zone: String) -> String {
        let seconds = TimeZone(identifier: zone)?.secondsFromGMT(for: now) ?? 0
        let minutes = abs(seconds) / 60
        return "\(ProfileTitle.city(zone)) · UTC\(seconds >= 0 ? "+" : "−")\(minutes / 60)" + (minutes % 60 == 0 ? "" : String(format: ":%02d", minutes % 60))
    }
    func languageName(_ id: String) -> String { Locale(identifier: "zh-Hans-CN").localizedString(forIdentifier: id) ?? id }
    func countryName(_ id: String) -> String { Locale(identifier: "zh-Hans-CN").localizedString(forRegionCode: IdentifierNormalizer.countryCode(id)) ?? id }
}

enum CardRoute: Equatable, Hashable { case home, all, preview, baseline, guide }
struct ProfileDraft: Identifiable {
    var id = UUID()
    var profileID = UUID()
    var country = ""
    var formatRegion = ""
    var language = ""
    var timeZone = ""
    var createdAt = Date()
    var lastAppliedAt: Date?
    var isEditing = false
    init(profile: WorkProfile? = nil, duplicate: Bool = false) {
        if let profile {
            country = IdentifierNormalizer.countryCode(profile.region); formatRegion = profile.region; language = profile.language; timeZone = profile.timeZone
            if !duplicate { profileID = profile.id; createdAt = profile.createdAt; lastAppliedAt = profile.lastAppliedAt; isEditing = true }
        }
    }
    var profile: WorkProfile { WorkProfile(id: profileID, language: language, region: formatRegion.isEmpty ? country : formatRegion, timeZone: timeZone, createdAt: createdAt, lastAppliedAt: lastAppliedAt) }
}
