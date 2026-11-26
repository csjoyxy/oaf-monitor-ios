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
    @Published var isBarkAgentInstalled: Bool = false

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
        self.password = KeychainHelper.read(account: Self.passwordKeychainAccount)

        let hasOnboarded = UserDefaults.standard.bool(forKey: Self.onboardedKey)
        if !hasOnboarded {
            self.showSetupSheet = true
        }
    }

    // MARK: - Computed Summaries & Filtered List

    var onlineCount: Int {
        devices.filter(\.isOnline).count
    }

    var activeCount: Int {
        devices.filter(\.isActive).count
    }

    var todayTotalBytes: Int64 {
        devices.reduce(0) { $0 + $1.todayTotalBytes }
    }

    var liveTotalDownRate: Int64 {
        devices.reduce(0) { $0 + ($1.isOnline ? $1.downRate : 0) }
    }

    var filteredDevices: [OAFDevice] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = devices.filter { dev in
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
            let liveData = (try? await liveTask) ?? ([], [])
            let fetchedBark = try? await barkTask

            if categoryMap.isEmpty {
                categoryMap = await UbusClient.shared.fetchCategoryMap(profile: profile, password: password)
            }

            self.devices = fetchedDevices
            self.activeRecords = liveData.activeRecords
            self.globalHourlyTraffic = liveData.globalTraffic
            if let fetchedBark {
                self.barkConfig = fetchedBark
                self.isBarkAgentInstalled = true
            } else {
                self.isBarkAgentInstalled = false
            }
            self.routeStatus = await UbusClient.shared.currentRoute()
            self.lastError = nil
            self.lastUpdated = Date()
        } catch {
            self.lastError = error.localizedDescription
            self.routeStatus = .disconnected
        }
    }

    // MARK: - Device Detail & Actions

    func loadDetail(for device: OAFDevice) async throws -> DeviceDetailBundle {
        if isDemoMode {
            return DemoDataProvider.detail(for: device)
        }
        return try await UbusClient.shared.fetchDeviceDetail(
            profile: profile,
            password: password,
            mac: device.normalizedMAC,
            categoryMap: categoryMap
        )
    }

    func loadMoreVisitRecords(for mac: String, page: Int) async throws -> (records: [OAFVisitRecord], page: Int, totalPages: Int) {
        if isDemoMode {
            return ([], 1, 1)
        }
        return try await UbusClient.shared.fetchVisitRecordsPage(
            profile: profile,
            password: password,
            mac: mac,
            page: page
        )
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
