import Foundation
import UIKit

enum UbusClientError: LocalizedError {
    case notConfigured
    case invalidEndpoint(String)
    case authenticationFailed
    case oafNotAvailable
    case barkAgentNotInstalled
    case rpcError(String)
    case networkUnreachable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先配置 OpenWrt 路由器地址与登录密码"
        case .invalidEndpoint(let url):
            return "路由器地址格式无效：\(url)"
        case .authenticationFailed:
            return "路由器用户名或密码错误，请检查登录凭据"
        case .oafNotAvailable:
            return "未在路由器上检测到 OAF 7.0 (fwx) 接口，请确认 OAF 服务已启动"
        case .barkAgentNotInstalled:
            return "路由器尚未安装 OAF Pulse Bark 轻量通知脚本"
        case .rpcError(let msg):
            return msg
        case .networkUnreachable(let detail):
            return "无法连接到路由器：\(detail)"
        }
    }
}

/// Trust delegate allowing OpenWrt self-signed HTTPS certificates when enabled
final class InsecureTLSDelegate: NSObject, URLSessionDelegate, Sendable {
    let allowInsecure: Bool

    init(allowInsecure: Bool) {
        self.allowInsecure = allowInsecure
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if allowInsecure,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

actor UbusClient {
    static let shared = UbusClient()

    private let zeroSession = "00000000000000000000000000000000"
    private var cachedToken: String?
    private var activeEndpoint: (baseURL: String, isWAN: Bool)?
    private var lastLatencyMs: Int = 0
    private var insecureSession: URLSession
    private var strictSession: URLSession
    private let iconCache = NSCache<NSString, UIImage>()

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        self.insecureSession = URLSession(configuration: cfg, delegate: InsecureTLSDelegate(allowInsecure: true), delegateQueue: nil)
        self.strictSession = URLSession(configuration: cfg, delegate: InsecureTLSDelegate(allowInsecure: false), delegateQueue: nil)
    }

    func resetSession() {
        cachedToken = nil
        activeEndpoint = nil
    }

    static func normalizeBaseURL(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.lowercased().hasSuffix("/ubus") {
            trimmed = String(trimmed.dropLast(5))
        }
        if let range = trimmed.range(of: "/cgi-bin", options: .caseInsensitive) {
            trimmed = String(trimmed[..<range.lowerBound])
        }
        guard URL(string: trimmed + "/ubus") != nil else { return nil }
        return trimmed
    }

    func currentRoute() -> ActiveEndpointRoute {
        guard let ep = activeEndpoint else { return .disconnected }
        return ep.isWAN
            ? .wan(latencyMs: lastLatencyMs, baseURL: ep.baseURL)
            : .lan(latencyMs: lastLatencyMs, baseURL: ep.baseURL)
    }

    // MARK: - App Icon Loader (from router /luci-static/resources/oaf/app_icons/<id>.png)

    func fetchAppIcon(appId: Int, allowInsecureTLS: Bool) async -> UIImage? {
        guard appId > 0, let ep = activeEndpoint else { return nil }
        let cacheKey = "\(ep.baseURL)-\(appId)" as NSString
        if let cached = iconCache.object(forKey: cacheKey) {
            return cached
        }
        guard let url = URL(string: "\(ep.baseURL)/luci-static/resources/oaf/app_icons/\(appId).png") else {
            return nil
        }
        let session = allowInsecureTLS ? insecureSession : strictSession
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.5
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let img = UIImage(data: data) else {
            return nil
        }
        iconCache.setObject(img, forKey: cacheKey)
        return img
    }

    // MARK: - Core ubus JSON-RPC Transport + Auto LAN/WAN Failover

    private func session(allowInsecure: Bool) -> URLSession {
        allowInsecure ? insecureSession : strictSession
    }

    private func performRawRPC(
        baseURL: String,
        timeout: TimeInterval,
        allowInsecure: Bool,
        token: String,
        object: String,
        method: String,
        arguments: [String: Any]
    ) async throws -> (ubusCode: Int, payload: Any?, latencyMs: Int) {
        guard let url = URL(string: baseURL + "/ubus") else {
            throw UbusClientError.invalidEndpoint(baseURL)
        }
        let bodyObj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...999_999),
            "method": "call",
            "params": [token, object, method, arguments]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyObj)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let start = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await session(allowInsecure: allowInsecure).data(for: req)
        let elapsedMs = max(1, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UbusClientError.networkUnreachable("HTTP \(http.statusCode)")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UbusClientError.rpcError("路由器返回了非 JSON 数据")
        }

        if let err = root["error"] as? [String: Any] {
            let code = err["code"] as? Int ?? -1
            let msg = err["message"] as? String ?? "RPC Error"
            if code == -32002 {
                // Access denied / expired ubus session
                return (6, nil, elapsedMs)
            }
            if code == -32000 {
                // Object not found
                return (4, nil, elapsedMs)
            }
            throw UbusClientError.rpcError("\(msg) (\(code))")
        }

        guard let resultArr = root["result"] as? [Any], let statusCode = resultArr.first as? Int else {
            throw UbusClientError.rpcError("ubus 响应格式异常")
        }

        let value: Any? = resultArr.count > 1 ? resultArr[1] : nil
        return (statusCode, value, elapsedMs)
    }

    private func authenticate(profile: RouterConnectionProfile, password: String) async throws -> (token: String, baseURL: String, isWAN: Bool) {
        var candidates: [(url: String, isWAN: Bool, timeout: TimeInterval)] = []

        if let lan = Self.normalizeBaseURL(profile.lanURL) {
            let lanTimeout: TimeInterval = Self.normalizeBaseURL(profile.wanURL) != nil ? 2.4 : 6.0
            candidates.append((lan, false, lanTimeout))
        }
        if let wan = Self.normalizeBaseURL(profile.wanURL),
           !candidates.contains(where: { $0.url == wan }) {
            candidates.append((wan, true, 8.0))
        }

        guard !candidates.isEmpty else {
            throw UbusClientError.notConfigured
        }

        // Prefer the previously working endpoint first, then fallback to the alternate one
        if let current = activeEndpoint,
           let idx = candidates.firstIndex(where: { $0.url == current.baseURL }),
           idx != 0 {
            let preferred = candidates.remove(at: idx)
            candidates.insert((preferred.url, preferred.isWAN, preferred.isWAN ? 6.0 : 2.5), at: 0)
        }

        var lastError: Error = UbusClientError.notConfigured
        for candidate in candidates {
            do {
                let (code, payload, ms) = try await performRawRPC(
                    baseURL: candidate.url,
                    timeout: candidate.timeout,
                    allowInsecure: profile.allowInsecureTLS,
                    token: zeroSession,
                    object: "session",
                    method: "login",
                    arguments: [
                        "username": profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "root" : profile.username.trimmingCharacters(in: .whitespacesAndNewlines),
                        "password": password
                    ]
                )
                if code == 6 {
                    throw UbusClientError.authenticationFailed
                }
                guard code == 0,
                      let dict = payload as? [String: Any],
                      let sysauth = dict["ubus_rpc_session"] as? String,
                      sysauth != zeroSession else {
                    throw UbusClientError.authenticationFailed
                }
                self.cachedToken = sysauth
                self.activeEndpoint = (candidate.url, candidate.isWAN)
                self.lastLatencyMs = ms
                return (sysauth, candidate.url, candidate.isWAN)
            } catch let authErr as UbusClientError {
                if case .authenticationFailed = authErr {
                    throw authErr
                }
                lastError = authErr
            } catch {
                lastError = UbusClientError.networkUnreachable(error.localizedDescription)
            }
        }
        throw lastError
    }

    private func callAuthenticated(
        profile: RouterConnectionProfile,
        password: String,
        object: String,
        method: String,
        arguments: [String: Any]
    ) async throws -> Any? {
        let token: String
        let baseURL: String
        if let existingToken = cachedToken, let existingEP = activeEndpoint {
            token = existingToken
            baseURL = existingEP.baseURL
        } else {
            let auth = try await authenticate(profile: profile, password: password)
            token = auth.token
            baseURL = auth.baseURL
        }

        do {
            let (code, payload, ms) = try await performRawRPC(
                baseURL: baseURL,
                timeout: 8.0,
                allowInsecure: profile.allowInsecureTLS,
                token: token,
                object: object,
                method: method,
                arguments: arguments
            )
            self.lastLatencyMs = ms

            if code == 6 {
                // Token expired -> silent re-login once
                self.cachedToken = nil
                let fresh = try await authenticate(profile: profile, password: password)
                let (retryCode, retryPayload, retryMs) = try await performRawRPC(
                    baseURL: fresh.baseURL,
                    timeout: 8.0,
                    allowInsecure: profile.allowInsecureTLS,
                    token: fresh.token,
                    object: object,
                    method: method,
                    arguments: arguments
                )
                self.lastLatencyMs = retryMs
                if retryCode == 4 {
                    throw object == "oaf_bark" ? UbusClientError.barkAgentNotInstalled : UbusClientError.oafNotAvailable
                }
                if retryCode != 0 {
                    throw UbusClientError.rpcError("ubus 调用失败 (code \(retryCode))")
                }
                return retryPayload
            }

            if code == 4 {
                throw object == "oaf_bark" ? UbusClientError.barkAgentNotInstalled : UbusClientError.oafNotAvailable
            }
            if code != 0 {
                throw UbusClientError.rpcError("ubus 调用失败 (code \(code))")
            }
            return payload
        } catch let err as UbusClientError {
            throw err
        } catch {
            // Network switched between Wi-Fi and 4G/5G -> clear activeEndpoint and failover once!
            self.cachedToken = nil
            self.activeEndpoint = nil
            let fresh = try await authenticate(profile: profile, password: password)
            let (retryCode, retryPayload, retryMs) = try await performRawRPC(
                baseURL: fresh.baseURL,
                timeout: 8.0,
                allowInsecure: profile.allowInsecureTLS,
                token: fresh.token,
                object: object,
                method: method,
                arguments: arguments
            )
            self.lastLatencyMs = retryMs
            if retryCode == 4 {
                throw object == "oaf_bark" ? UbusClientError.barkAgentNotInstalled : UbusClientError.oafNotAvailable
            }
            if retryCode != 0 {
                throw UbusClientError.rpcError("ubus 调用失败 (code \(retryCode))")
            }
            return retryPayload
        }
    }

    // MARK: - OAF 7.0 `fwx.common` High-Level Wrappers

    private func callFWXData(
        profile: RouterConnectionProfile,
        password: String,
        api: String,
        data: [String: Any] = [:]
    ) async throws -> Any? {
        let raw = try await callAuthenticated(
            profile: profile,
            password: password,
            object: "fwx",
            method: "common",
            arguments: [
                "api": api,
                "CopyRight": "www.fanchmwrt.com",
                "data": data
            ]
        )
        guard let dict = raw as? [String: Any] else { return nil }
        return dict["data"] ?? dict
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from object: Any?) throws -> T {
        guard let object else {
            throw UbusClientError.rpcError("空响应数据")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchAllDevices(profile: RouterConnectionProfile, password: String) async throws -> [OAFDevice] {
        let dataObj = try await callFWXData(
            profile: profile,
            password: password,
            api: "get_all_users",
            data: ["flag": 3, "page": 1, "page_size": 250]
        )
        guard let dict = dataObj as? [String: Any], let listObj = dict["list"] else {
            return []
        }
        if listObj is [String: Any] { return [] }
        return (try? decodeJSON([OAFDevice].self, from: listObj)) ?? []
    }

    func fetchCategoryMap(profile: RouterConnectionProfile, password: String) async -> [Int: String] {
        guard let dataObj = try? await callFWXData(profile: profile, password: password, api: "class_list"),
              let dict = dataObj as? [String: Any],
              let arr = dict["class_list"] as? [[String: Any]] else {
            return [:]
        }
        var map: [Int: String] = [:]
        for item in arr {
            let name = (item["name"] as? String) ?? ""
            if let id = item["id"] as? Int, id > 0, !name.isEmpty {
                map[id] = name
            } else if let apps = item["app_list"] as? [String], !name.isEmpty {
                for entry in apps {
                    if let first = entry.split(separator: ",").first, let appId = Int(first), appId >= 1000 {
                        let cid = appId / 1000
                        if map[cid] == nil { map[cid] = name }
                    }
                }
            }
        }
        return map
    }

    func fetchDeviceDetail(
        profile: RouterConnectionProfile,
        password: String,
        mac: String,
        categoryMap: [Int: String],
        page: Int = 1,
        pageSize: Int = 30
    ) async throws -> DeviceDetailBundle {
        let lowerMac = mac.lowercased()

        async let basicTask = callFWXData(profile: profile, password: password, api: "get_user_basic_info", data: ["mac": lowerMac])
        async let durTask = callFWXData(profile: profile, password: password, api: "dev_visit_time", data: ["mac": lowerMac])
        async let catTask = callFWXData(profile: profile, password: password, api: "app_class_visit_time", data: ["mac": lowerMac])
        async let hourlyTask = callFWXData(profile: profile, password: password, api: "get_hourly_top_apps", data: ["mac": lowerMac])
        async let visitTask = callFWXData(profile: profile, password: password, api: "dev_visit_list", data: ["mac": lowerMac, "page": page, "page_size": pageSize])
        async let onOffTask = callFWXData(profile: profile, password: password, api: "get_online_offline_records", data: ["mac": lowerMac, "page": 1, "page_size": 40])

        let basicRaw = try? await basicTask
        let durRaw = try? await durTask
        let catRaw = try? await catTask
        let hourlyRaw = try? await hourlyTask
        let visitRaw = try? await visitTask
        let onOffRaw = try? await onOffTask

        var bundle = DeviceDetailBundle()

        if let basicRaw {
            bundle.basicInfo = try? decodeJSON(OAFDevice.self, from: basicRaw)
        }
        if let durDict = durRaw as? [String: Any], let list = durDict["list"] as? [Any] {
            let decoded = (try? decodeJSON([OAFAppDuration].self, from: list)) ?? []
            bundle.appDurations = decoded.filter { $0.seconds > 0 }.sorted { $0.seconds > $1.seconds }
        } else if let durArr = durRaw as? [Any] {
            let decoded = (try? decodeJSON([OAFAppDuration].self, from: durArr)) ?? []
            bundle.appDurations = decoded.filter { $0.seconds > 0 }.sorted { $0.seconds > $1.seconds }
        }

        if let catDict = catRaw as? [String: Any], let list = catDict["class_list"] as? [Any] {
            var cats = (try? decodeJSON([OAFCategoryDuration].self, from: list)) ?? []
            for idx in cats.indices {
                if let mapped = categoryMap[cats[idx].categoryId], !mapped.isEmpty {
                    cats[idx].name = mapped
                }
            }
            bundle.categoryDurations = cats.filter { $0.seconds > 0 }.sorted { $0.seconds > $1.seconds }
        }

        if let hDict = hourlyRaw as? [String: Any], let hList = hDict["hourly_stats"] as? [Any] {
            let stats = (try? decodeJSON([OAFHourlyStat].self, from: hList)) ?? []
            bundle.hourlyStats = stats.sorted { $0.hour < $1.hour }
        }

        if let vDict = visitRaw as? [String: Any] {
            bundle.visitTotalCount = (vDict["total_num"] as? Int) ?? 0
            bundle.visitPage = (vDict["page"] as? Int) ?? page
            bundle.visitTotalPages = max(1, (vDict["total_page"] as? Int) ?? 1)
            if let vList = vDict["list"] as? [Any] {
                bundle.visitRecords = (try? decodeJSON([OAFVisitRecord].self, from: vList)) ?? []
            }
        }

        if let oDict = onOffRaw as? [String: Any], let oList = (oDict["records"] ?? oDict["list"]) as? [Any] {
            bundle.onlineEvents = (try? decodeJSON([OAFOnlineOfflineEvent].self, from: oList)) ?? []
        }

        return bundle
    }

    func fetchVisitRecordsPage(
        profile: RouterConnectionProfile,
        password: String,
        mac: String,
        page: Int,
        pageSize: Int = 30
    ) async throws -> (records: [OAFVisitRecord], page: Int, totalPages: Int) {
        let visitRaw = try await callFWXData(
            profile: profile,
            password: password,
            api: "dev_visit_list",
            data: ["mac": mac.lowercased(), "page": page, "page_size": pageSize]
        )
        guard let vDict = visitRaw as? [String: Any] else { return ([], page, 1) }
        let curPage = (vDict["page"] as? Int) ?? page
        let totalPages = max(1, (vDict["total_page"] as? Int) ?? 1)
        let records: [OAFVisitRecord]
        if let vList = vDict["list"] as? [Any] {
            records = (try? decodeJSON([OAFVisitRecord].self, from: vList)) ?? []
        } else {
            records = []
        }
        return (records, curPage, totalPages)
    }

    func setDeviceNickname(profile: RouterConnectionProfile, password: String, mac: String, nickname: String) async throws {
        _ = try await callFWXData(
            profile: profile,
            password: password,
            api: "set_nickname",
            data: ["mac": mac.lowercased(), "nickname": nickname]
        )
    }

    func fetchLiveOverview(
        profile: RouterConnectionProfile,
        password: String
    ) async throws -> (activeRecords: [OAFVisitRecord], globalTraffic: [OAFGlobalHourlyTraffic]) {
        async let activeTask = callFWXData(
            profile: profile,
            password: password,
            api: "get_active_app_records",
            data: ["page": 1, "page_size": 40]
        )
        async let trafficTask = callFWXData(
            profile: profile,
            password: password,
            api: "get_global_traffic_stats",
            data: ["date": 0]
        )

        let activeRaw = try? await activeTask
        let trafficRaw = try? await trafficTask

        var activeList: [OAFVisitRecord] = []
        if let dict = activeRaw as? [String: Any], let arr = dict["list"] as? [Any] {
            activeList = (try? decodeJSON([OAFVisitRecord].self, from: arr)) ?? []
        }

        var hourlyTraffic: [OAFGlobalHourlyTraffic] = []
        if let dict = trafficRaw as? [String: Any], let arr = dict["hourly_traffic"] as? [Any] {
            hourlyTraffic = ((try? decodeJSON([OAFGlobalHourlyTraffic].self, from: arr)) ?? []).sorted { $0.hour < $1.hour }
        }
        return (activeList, hourlyTraffic)
    }

    // MARK: - Router `oaf_bark` Agent RPCs

    func fetchBarkConfig(profile: RouterConnectionProfile, password: String) async throws -> BarkAgentConfig {
        let raw = try await callAuthenticated(
            profile: profile,
            password: password,
            object: "oaf_bark",
            method: "get_config",
            arguments: [:]
        )
        guard let dict = raw as? [String: Any], let dataObj = dict["data"] else {
            throw UbusClientError.barkAgentNotInstalled
        }
        return try decodeJSON(BarkAgentConfig.self, from: dataObj)
    }

    func saveBarkConfig(profile: RouterConnectionProfile, password: String, config: BarkAgentConfig) async throws -> BarkAgentConfig {
        let args: [String: Any] = [
            "enabled": config.enabled ? 1 : 0,
            "bark_server": config.barkServer,
            "bark_key": config.barkKey,
            "poll_interval": config.pollInterval,
            "offline_debounce": config.offlineDebounce,
            "watch_mode": config.watchMode,
            "notify_online": config.notifyOnline ? 1 : 0,
            "notify_offline": config.notifyOffline ? 1 : 0,
            "include_summary": config.includeSummary ? 1 : 0,
            "quiet_enable": config.quietEnable ? 1 : 0,
            "quiet_start": config.quietStart,
            "quiet_end": config.quietEnd,
            "watched_macs_csv": config.watchedMACs.map { $0.uppercased() }.joined(separator: ",")
        ]
        let raw = try await callAuthenticated(
            profile: profile,
            password: password,
            object: "oaf_bark",
            method: "set_config",
            arguments: args
        )
        if let dict = raw as? [String: Any], let dataObj = dict["data"] {
            return try decodeJSON(BarkAgentConfig.self, from: dataObj)
        }
        return config
    }

    func toggleBarkWatch(profile: RouterConnectionProfile, password: String, mac: String, watch: Bool) async throws -> BarkAgentConfig {
        let raw = try await callAuthenticated(
            profile: profile,
            password: password,
            object: "oaf_bark",
            method: "toggle_device",
            arguments: ["mac": mac.uppercased(), "watch": watch ? 1 : 0]
        )
        guard let dict = raw as? [String: Any], let dataObj = dict["data"] else {
            throw UbusClientError.barkAgentNotInstalled
        }
        return try decodeJSON(BarkAgentConfig.self, from: dataObj)
    }

    func sendTestBarkPush(
        profile: RouterConnectionProfile,
        password: String,
        barkServer: String,
        barkKey: String,
        sampleDevice: OAFDevice?
    ) async throws -> String {
        var args: [String: Any] = [
            "bark_server": barkServer,
            "bark_key": barkKey
        ]
        if let sampleDevice {
            args["mac"] = sampleDevice.normalizedMAC
            args["device_name"] = sampleDevice.displayName
        }
        let raw = try await callAuthenticated(
            profile: profile,
            password: password,
            object: "oaf_bark",
            method: "test_push",
            arguments: args
        )
        guard let dict = raw as? [String: Any] else {
            throw UbusClientError.rpcError("未收到测试推送响应")
        }
        let code = (dict["code"] as? Int) ?? -1
        let msg = (dict["message"] as? String) ?? (code == 0 ? "测试推送成功" : "推送失败")
        if code != 0 {
            throw UbusClientError.rpcError(msg)
        }
        return msg
    }
}
