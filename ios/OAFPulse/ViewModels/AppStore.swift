import Foundation
import SwiftUI
import UIKit

enum DeviceFilterOption: String, CaseIterable, Identifiable {
    case all = "全部"
    case online = "在线"
    case active = "活跃中"
    case watched = "已设提醒"

    var id: String { rawValue }
}

enum DeviceSortOption: String, CaseIterable, Identifiable {
    case smart = "活跃优先"
    case activeTime = "今日时长"
    case traffic = "今日流量"
    case liveSpeed = "实时网速"

    var id: String { rawValue }
}

struct ToastBanner: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var isError: Bool = false
}

@MainActor
final class AppStore: ObservableObject {
    private static let profileKey = "oafpulse.router.profile.v1"
    private static let onboardedKey = "oafpulse.onboarded.v1"
    private static let localIgnoredKey = "oafpulse.ignored.apps.v1"
    private static let passwordKeychainAccount = "router_password"

    @Published var profile: RouterConnectionProfile
    @Published var password: String
    @Published var isDemoMode: Bool = false
    @Published var showSetupSheet: Bool = false

    @Published var selectedTab: Int = 0
    @Published var navigationPath = NavigationPath()

    @Published var devices: [OAFDevice] = []
    @Published var activeRecords: [OAFVisitRecord] = []
    @Published var globalHourlyTraffic: [OAFGlobalHourlyTraffic] = []

    @Published var categoryMap: [Int: String] = [:]
    @Published var barkConfig: BarkAgentConfig = BarkAgentConfig()
    @Published var localIgnoredApps: [IgnoredAppEntry] = []
    @Published var isBarkAgentInstalled: Bool = false
    @Published var ignoreRevision: Int = 0

    @Published var routeStatus: ActiveEndpointRoute = .disconnected
    @Published var isLoadingDevices: Bool = false
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    @Published var toast: ToastBanner?

    // Search, Filter & Sort
    @Published var searchText: String = ""
    @Published var filterOption: DeviceFilterOption = .all
    @Published var sortOption: DeviceSortOption = .smart

    private var refreshTimerTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.profileKey),
           let saved = try? JSONDecoder().decode(RouterConnectionProfile.self, from: data) {
            self.profile = saved
        } else {
            self.profile = RouterConnectionProfile()
        }
        if let ignData = UserDefaults.standard.data(forKey: Self.localIgnoredKey),
           let savedIgn = try? JSONDecoder().decode([IgnoredAppEntry].self, from: ignData) {
            self.localIgnoredApps = savedIgn
        }
        self.password = KeychainHelper.read(account: Self.passwordKeychainAccount)

        let hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        if !hasOnboarded {
            self.showSetupSheet = true
        }
    }

    // MARK: - False-Positive Filtering Helpers

    var effectiveIgnoredApps: [IgnoredAppEntry] {
        var result: [IgnoredAppEntry] = []
        for entry in barkConfig.ignoredApps + barkConfig.disabledRules + localIgnoredApps {
            let exists = result.contains {
                (entry.appId > 0 && $0.appId == entry.appId) || (!entry.name.isEmpty && $0.name == entry.name)
            }
            if !exists {
                result.append(entry)
            }
        }
        return result
    }

    /// Apps that are soft-hidden only (excluding those already listed under `barkConfig.disabledRules`).
    var softOnlyIgnoredApps: [IgnoredAppEntry] {
        effectiveIgnoredApps.filter { entry in
            !barkConfig.disabledRules.contains { dis in
                (entry.appId > 0 && dis.appId == entry.appId) || (!entry.name.isEmpty && dis.name == entry.name)
            }
        }
    }

    func isAppIgnored(appId: Int, name: String) -> Bool {
        let list = effectiveIgnoredApps
        guard !list.isEmpty else { return false }
        return list.contains {
            (appId > 0 && $0.appId == appId) || (!name.isEmpty && $0.name == name)
        }
    }

    func sanitizedDevice(_ dev: OAFDevice) -> OAFDevice {
        var copy = dev
        copy.applist = dev.applist.filter { !isAppIgnored(appId: $0.appId, name: $0.name) }
        if !copy.currentApp.isEmpty && isAppIgnored(appId: copy.currentAppId, name: copy.currentApp) {
            if let fallback = copy.applist.first {
                copy.currentApp = fallback.name
                copy.currentAppId = fallback.appId
            } else {
                copy.currentApp = ""
                copy.currentAppId = 0
                copy.active = 0
            }
        }
        return copy
    }

    func sanitizeDetail(_ bundle: DeviceDetailBundle) -> DeviceDetailBundle {
        var out = bundle
        if let basic = out.basicInfo {
            out.basicInfo = sanitizedDevice(basic)
        }
        out.appDurations = bundle.appDurations.filter { !isAppIgnored(appId: $0.appId, name: $0.name) }
        out.visitRecords = bundle.visitRecords.filter { !isAppIgnored(appId: $0.appId, name: $0.appName) }
        out.hourlyStats = bundle.hourlyStats.map { h in
            var copy = h
            copy.apps = h.apps.filter { !isAppIgnored(appId: $0.appId, name: $0.name) }
            return copy
        }
        out.onlineEvents = bundle.onlineEvents.map { ev in
            var copy = ev
            copy.recentApps = ev.recentApps.filter { !isAppIgnored(appId: $0.appId, name: $0.name) }
            return copy
        }
        return out
    }

    var filteredActiveRecords: [OAFVisitRecord] {
        activeRecords.filter { !isAppIgnored(appId: $0.appId, name: $0.appName) }
    }

    // MARK: - Computed Summaries & Filtered List

    var onlineCount: Int {
        devices.filter(\.isOnline).count
    }

    var activeCount: Int {
        devices.map(sanitizedDevice).filter(\.isActive).count
    }

    var todayTotalBytes: Int64 {
        devices.reduce(0) { $0 + $1.todayTotalBytes }
    }

    var liveTotalDownRate: Int64 {
        devices.reduce(0) { $0 + ($1.isOnline ? $1.downRate : 0) }
    }

    var filteredDevices: [OAFDevice] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleaned = devices.map(sanitizedDevice)
        let filtered = cleaned.filter { dev in
            switch filterOption {
            case .all: break
            case .online: if !dev.isOnline { return false }
            case .active: if !dev.isActive { return false }
            case .watched: if !barkConfig.isWatching(dev.normalizedMAC) { return false }
            }
            if q.isEmpty { return true }
            return dev.displayName.lowercased().contains(q)
                || dev.hostname.lowercased().contains(q)
                || dev.ip.lowercased().contains(q)
                || dev.mac.lowercased().contains(q)
                || dev.currentApp.lowercased().contains(q)
        }

        return filtered.sorted { a, b in
            switch sortOption {
            case .smart:
                if a.isActive != b.isActive { return a.isActive && !b.isActive }
                if a.isOnline != b.isOnline { return a.isOnline && !b.isOnline }
                if a.todayActiveTime != b.todayActiveTime { return a.todayActiveTime > b.todayActiveTime }
                return a.todayTotalBytes > b.todayTotalBytes
            case .activeTime:
                if a.todayActiveTime != b.todayActiveTime { return a.todayActiveTime > b.todayActiveTime }
                return a.isOnline && !b.isOnline
            case .traffic:
                if a.todayTotalBytes != b.todayTotalBytes { return a.todayTotalBytes > b.todayTotalBytes }
                return a.isOnline && !b.isOnline
            case .liveSpeed:
                if a.totalLiveRate != b.totalLiveRate { return a.totalLiveRate > b.totalLiveRate }
                return a.isOnline && !b.isOnline
            }
        }
    }

    // MARK: - Connection & Lifecycle

    func startInitialLoadIfReady() {
        guard UserDefaults.standard.bool(forKey: Self.onboardedKey) else { return }
        Task {
            await refreshAll(showSpinner: true)
            restartAutoRefreshLoop()
        }
    }

    func enterDemoMode() {
        isDemoMode = true
        showSetupSheet = false
        devices = DemoDataProvider.devices()
        let live = DemoDataProvider.liveOverview()
        activeRecords = live.activeRecords
        globalHourlyTraffic = live.globalTraffic
        barkConfig = DemoDataProvider.barkConfig()
        isBarkAgentInstalled = true
        routeStatus = .demo
        lastError = nil
        lastUpdated = Date()
        showToast("已进入演示预览模式，可在「提醒与设置」连接真实路由器")
    }

    func saveConnectionAndConnect(newProfile: RouterConnectionProfile, newPassword: String) async -> Bool {
        self.profile = newProfile
        self.password = newPassword
        self.isDemoMode = false

        if let encoded = try? JSONEncoder().encode(newProfile) {
            UserDefaults.standard.set(encoded, forKey: Self.profileKey)
        }
        KeychainHelper.save(newPassword, account: Self.passwordKeychainAccount)
        await UbusClient.shared.resetSession()

        await refreshAll(showSpinner: true)
        if lastError == nil {
            UserDefaults.standard.set(true, forKey: Self.onboardedKey)
            showSetupSheet = false
            restartAutoRefreshLoop()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showToast("已成功连接路由器")
            return true
        }
        return false
    }

    func updateAutoRefreshSeconds(_ seconds: Int) {
        profile.autoRefreshSeconds = seconds
        if let encoded = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(encoded, forKey: Self.profileKey)
        }
        restartAutoRefreshLoop()
    }

    func restartAutoRefreshLoop() {
        refreshTimerTask?.cancel()
        let interval = profile.autoRefreshSeconds
        guard interval > 0, !isDemoMode else { return }

        refreshTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled, let self else { break }
                if !self.isLoadingDevices && !self.showSetupSheet {
                    await self.refreshAll(showSpinner: false)
                }
            }
        }
    }

    func refreshAll(showSpinner: Bool = false) async {
        if isDemoMode {
            devices = DemoDataProvider.devices()
            let live = DemoDataProvider.liveOverview()
            activeRecords = live.activeRecords
            globalHourlyTraffic = live.globalTraffic
            routeStatus = .demo
            lastUpdated = Date()
            return
        }

        guard profile.isConfigured else {
            lastError = UbusClientError.notConfigured.localizedDescription
            return
        }

        if showSpinner { isLoadingDevices = true }
        defer { if showSpinner { isLoadingDevices = false } }

        do {
            async let devsTask = UbusClient.shared.fetchAllDevices(profile: profile, password: password)
            async let liveTask = UbusClient.shared.fetchLiveOverview(profile: profile, password: password)
            async let barkTask = UbusClient.shared.fetchBarkConfig(profile: profile, password: password)

            let fetchedDevices = try await devsTask
            let liveData = (try? await liveTask) ?? (activeRecords: [], globalTraffic: [])
            let fetchedBark = try? await barkTask

            if categoryMap.isEmpty {
                categoryMap = await UbusClient.shared.fetchCategoryMap(profile: profile, password: password)
            }

            let currentRoute = await UbusClient.shared.currentRoute()
            AppIconCache.shared.activeBaseURL = currentRoute.activeBaseURL
            AppIconCache.shared.allowInsecureTLS = profile.allowInsecureTLS

            if self.devices != fetchedDevices {
                self.devices = fetchedDevices
            }
            if self.activeRecords != liveData.activeRecords {
                self.activeRecords = liveData.activeRecords
            }
            if self.globalHourlyTraffic != liveData.globalTraffic {
                self.globalHourlyTraffic = liveData.globalTraffic
            }
            if let fetchedBark {
                if self.barkConfig != fetchedBark {
                    self.barkConfig = fetchedBark
                }
                if !self.isBarkAgentInstalled {
                    self.isBarkAgentInstalled = true
                }
            } else if self.isBarkAgentInstalled {
                self.isBarkAgentInstalled = false
            }
            if self.routeStatus != currentRoute {
                self.routeStatus = currentRoute
            }
            if self.lastError != nil {
                self.lastError = nil
            }
            self.lastUpdated = Date()
        } catch {
            self.lastError = error.localizedDescription
            self.routeStatus = .disconnected
        }
    }

    func recheckBarkAgent() async {
        // Force fresh rpcd login so newly added /usr/share/rpcd/acl.d/oaf-bark.json ACLs take effect immediately!
        await UbusClient.shared.resetSession()
        await refreshAll(showSpinner: true)
        if isBarkAgentInstalled {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("已成功检测到路由器 Bark 通知组件")
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showToast("仍未检测到 oaf_bark 接口，请重新执行最新安装命令", isError: true)
        }
    }

    // MARK: - Device Detail & Actions

    func loadDetail(for device: OAFDevice) async throws -> DeviceDetailBundle {
        if isDemoMode {
            return sanitizeDetail(DemoDataProvider.detail(for: device))
        }
        let raw = try await UbusClient.shared.fetchDeviceDetail(
            profile: profile,
            password: password,
            mac: device.normalizedMAC,
            categoryMap: categoryMap
        )
        return sanitizeDetail(raw)
    }

    func loadMoreVisitRecords(for mac: String, page: Int) async throws -> (records: [OAFVisitRecord], page: Int, totalPages: Int) {
        if isDemoMode {
            return ([], 1, 1)
        }
        let res = try await UbusClient.shared.fetchVisitRecordsPage(
            profile: profile,
            password: password,
            mac: mac,
            page: page
        )
        let filtered = res.records.filter { !isAppIgnored(appId: $0.appId, name: $0.appName) }
        return (filtered, res.page, res.totalPages)
    }

    func renameDevice(_ device: OAFDevice, nickname: String) async {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDemoMode {
            if let idx = devices.firstIndex(where: { $0.normalizedMAC == device.normalizedMAC }) {
                devices[idx].nickname = trimmed
            }
            showToast("备注名已更新（演示）")
            return
        }
        do {
            try await UbusClient.shared.setDeviceNickname(
                profile: profile,
                password: password,
                mac: device.normalizedMAC,
                nickname: trimmed
            )
            if let idx = devices.firstIndex(where: { $0.normalizedMAC == device.normalizedMAC }) {
                devices[idx].nickname = trimmed
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("设备备注已保存")
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Bark Watch & Config Actions

    func isWatching(_ device: OAFDevice) -> Bool {
        guard isBarkAgentInstalled else { return false }
        return barkConfig.isWatching(device.normalizedMAC)
    }

    func toggleDeviceWatch(_ device: OAFDevice) async {
        if isDemoMode {
            let mac = device.normalizedMAC
            if let i = barkConfig.watchedMACs.firstIndex(of: mac) {
                barkConfig.watchedMACs.remove(at: i)
                showToast("已关闭 \(device.displayName) 上下线通知")
            } else {
                barkConfig.watchedMACs.append(mac)
                showToast("已开启 \(device.displayName) 上下线通知")
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        guard isBarkAgentInstalled else {
            selectedTab = 2
            showToast("请先在路由器执行一行安装命令启用 Bark 组件", isError: true)
            return
        }

        let newWatch = !barkConfig.watchedMACs.contains(device.normalizedMAC)
        do {
            let updated = try await UbusClient.shared.toggleBarkWatch(
                profile: profile,
                password: password,
                mac: device.normalizedMAC,
                watch: newWatch
            )
            self.barkConfig = updated
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showToast(newWatch ? "🔔 已开启 \(device.displayName) 上下线提醒" : "已关闭 \(device.displayName) 上下线提醒")
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    func saveBarkConfiguration(_ updated: BarkAgentConfig) async -> Bool {
        if isDemoMode {
            barkConfig = updated
            showToast("Bark 配置已保存（演示模式）")
            return true
        }
        do {
            let saved = try await UbusClient.shared.saveBarkConfig(
                profile: profile,
                password: password,
                config: updated
            )
            self.barkConfig = saved
            self.isBarkAgentInstalled = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("Bark 提醒配置已同步至路由器")
            return true
        } catch {
            showToast(error.localizedDescription, isError: true)
            return false
        }
    }

    func triggerBarkTest(server: String, key: String) async {
        if isDemoMode {
            showToast("演示模式：连接真实路由器后可发送真实 Bark 测试推送")
            return
        }
        do {
            let msg = try await UbusClient.shared.sendTestBarkPush(
                profile: profile,
                password: password,
                barkServer: server,
                barkKey: key,
                sampleDevice: devices.first
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast(msg)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: - False-Positive Inspection & Feature Rule Surgical Controls

    private func persistLocalIgnored() {
        if let data = try? JSONEncoder().encode(localIgnoredApps) {
            UserDefaults.standard.set(data, forKey: Self.localIgnoredKey)
        }
    }

    private func updateLocalIgnoredList(appId: Int, appName: String, ignore: Bool) {
        localIgnoredApps.removeAll {
            (appId > 0 && $0.appId == appId) || (!appName.isEmpty && $0.name == appName)
        }
        if ignore {
            localIgnoredApps.append(IgnoredAppEntry(appId: appId, name: appName))
        }
        persistLocalIgnored()
        ignoreRevision &+= 1
    }

    func inspectAppFeature(appId: Int, appName: String) async throws -> OAFFeatureRuleInfo {
        if isDemoMode {
            return OAFFeatureRuleInfo(
                found: true,
                version: "26.09.10",
                appId: appId,
                appName: appName,
                rawRule: "\(appId)~\(appName):[udp;;;;;00:28|01:28,tcp;;;;;00:33|01:66]",
                ruleBody: "[udp;;;;;00:28|01:28,tcp;;;;;00:33|01:66]",
                isDisabled: false,
                riskHint: "存在「不限端口、不限域名」的纯字节偏移特征，看直播/刷视频的高并发包极易随机撞上产生误报"
            )
        }
        return try await UbusClient.shared.inspectFeatureRule(
            profile: profile,
            password: password,
            appId: appId,
            appName: appName
        )
    }

    func setAppSoftIgnored(appId: Int, appName: String, ignore: Bool) async {
        updateLocalIgnoredList(appId: appId, appName: appName, ignore: ignore)

        if !isDemoMode && isBarkAgentInstalled {
            if let updated = try? await UbusClient.shared.toggleIgnoreApp(
                profile: profile,
                password: password,
                appId: appId,
                appName: appName,
                ignore: ignore
            ) {
                self.barkConfig = updated
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showToast(ignore ? "🚫 已将「\(appName)」标记为误报隐藏" : "已恢复显示「\(appName)」")
    }

    func setRouterFeatureRuleDisabled(appId: Int, appName: String, disable: Bool) async -> Bool {
        if isDemoMode {
            updateLocalIgnoredList(appId: appId, appName: appName, ignore: disable)
            showToast(disable ? "演示：已禁用「\(appName)」特征规则" : "演示：已恢复「\(appName)」特征规则")
            return true
        }
        do {
            let updated = try await UbusClient.shared.setFeatureRuleDisabled(
                profile: profile,
                password: password,
                appId: appId,
                appName: appName,
                disable: disable
            )
            self.barkConfig = updated
            updateLocalIgnoredList(appId: appId, appName: appName, ignore: disable)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast(disable ? "✂️ 已从路由器特征库彻底禁用「\(appName)」并热重载生效" : "已恢复路由器特征库中的「\(appName)」规则")
            return true
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showToast(error.localizedDescription, isError: true)
            return false
        }
    }

    func restoreAllRouterFeatures() async {
        let previousDisabled = barkConfig.disabledRules
        if isDemoMode {
            for item in previousDisabled {
                updateLocalIgnoredList(appId: item.appId, appName: item.name, ignore: false)
            }
            barkConfig.disabledRules = []
            showToast("演示：已还原原厂特征库")
            return
        }
        do {
            let updated = try await UbusClient.shared.restoreAllFeatures(profile: profile, password: password)
            for item in previousDisabled {
                localIgnoredApps.removeAll {
                    (item.appId > 0 && $0.appId == item.appId) || (!item.name.isEmpty && $0.name == item.name)
                }
            }
            persistLocalIgnored()
            self.barkConfig = updated
            ignoreRevision &+= 1
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("已恢复路由器原厂特征库并热重载生效")
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Deep Link (`oafpulse://device?mac=76:13:65:14:B8:09`)

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "oafpulse" else { return }
        let host = url.host?.lowercased() ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let macParam = components?.queryItems?.first(where: { $0.name.lowercased() == "mac" })?.value?.uppercased()

        selectedTab = 0
        guard host == "device", let targetMAC = macParam, !targetMAC.isEmpty else { return }

        Task {
            if devices.isEmpty {
                await refreshAll(showSpinner: true)
            }
            if let matched = devices.first(where: { $0.normalizedMAC == targetMAC }) {
                navigationPath = NavigationPath()
                try? await Task.sleep(nanoseconds: 120_000_000)
                navigationPath.append(matched)
            } else {
                let placeholder = OAFDevice(mac: targetMAC, ip: "--", hostname: targetMAC, online: 0)
                navigationPath = NavigationPath()
                navigationPath.append(placeholder)
            }
        }
    }

    func showToast(_ message: String, isError: Bool = false) {
        let banner = ToastBanner(message: message, isError: isError)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            self.toast = banner
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if self.toast?.id == banner.id {
                withAnimation(.easeOut(duration: 0.25)) {
                    self.toast = nil
                }
            }
        }
    }
}
