import Foundation

// MARK: - Resilient OpenWrt Lua / json-c Decoding Helpers

private struct IgnoredJSONValue: Decodable {}

extension KeyedDecodingContainer {
    func flexString(_ keys: [Key], default defaultValue: String = "") -> String {
        for key in keys {
            if let v = try? decodeIfPresent(String.self, forKey: key) {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != "--" && trimmed != "*" {
                    return trimmed
                }
            }
            if let i = try? decodeIfPresent(Int64.self, forKey: key) {
                return String(i)
            }
            if let d = try? decodeIfPresent(Double.self, forKey: key) {
                return String(Int64(d))
            }
        }
        return defaultValue
    }

    func flexInt(_ keys: [Key], default defaultValue: Int = 0) -> Int {
        for key in keys {
            if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
            if let s = try? decodeIfPresent(String.self, forKey: key),
               let parsed = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
            if let b = try? decodeIfPresent(Bool.self, forKey: key) {
                return b ? 1 : 0
            }
            if let d = try? decodeIfPresent(Double.self, forKey: key) {
                return Int(d)
            }
        }
        return defaultValue
    }

    func flexInt64(_ keys: [Key], default defaultValue: Int64 = 0) -> Int64 {
        for key in keys {
            if let v = try? decodeIfPresent(Int64.self, forKey: key) { return v }
            if let s = try? decodeIfPresent(String.self, forKey: key),
               let parsed = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
            if let d = try? decodeIfPresent(Double.self, forKey: key) {
                return Int64(d)
            }
        }
        return defaultValue
    }

    func flexArray<T: Decodable>(_ keys: [Key], of type: T.Type = T.self) -> [T] {
        for key in keys {
            if let arr = try? decodeIfPresent([T].self, forKey: key) {
                return arr
            }
            if (try? decodeIfPresent([String: IgnoredJSONValue].self, forKey: key)) != nil {
                return []
            }
        }
        return []
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Router Connection Profile

struct RouterConnectionProfile: Codable, Equatable {
    var lanURL: String = "http://192.168.10.1"
    var wanURL: String = ""
    var username: String = "root"
    var allowInsecureTLS: Bool = true
    var autoRefreshSeconds: Int = 10

    var isConfigured: Bool {
        !lanURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !wanURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ActiveEndpointRoute: Equatable {
    case disconnected
    case demo
    case lan(latencyMs: Int, baseURL: String)
    case wan(latencyMs: Int, baseURL: String)

    var badgeText: String {
        switch self {
        case .disconnected: return "未连接"
        case .demo: return "演示预览"
        case .lan(let ms, _): return "内网 · \(ms)ms"
        case .wan(let ms, _): return "外网 · \(ms)ms"
        }
    }

    var activeBaseURL: String? {
        switch self {
        case .lan(_, let url), .wan(_, let url): return url
        default: return nil
        }
    }
}

// MARK: - Device Category Inference (Precomputed once per model init)

enum DeviceKind: String, Equatable, Hashable {
    case iPhone
    case iPad
    case mac
    case watch
    case android
    case computer
    case gameConsole
    case tv
    case smartHome
    case generic

    var sfSymbol: String {
        switch self {
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .mac: return "laptopcomputer"
        case .watch: return "applewatch"
        case .android: return "apps.iphone"
        case .computer: return "desktopcomputer"
        case .gameConsole: return "gamecontroller.fill"
        case .tv: return "tv.fill"
        case .smartHome: return "powerplug.fill"
        case .generic: return "wifi.router.fill"
        }
    }

    static func infer(from name: String) -> DeviceKind {
        let lower = name.lowercased()
        if lower.contains("iphone") || lower.contains("ios") { return .iPhone }
        if lower.contains("ipad") { return .iPad }
        if lower.contains("macbook") || lower.contains("imac") || lower.contains("mac-") || lower.contains("macmini") { return .mac }
        if lower.contains("watch") { return .watch }
        if lower.contains("switch") && (lower.contains("nintendo") || lower.contains("oled")) { return .gameConsole }
        if lower.contains("ps5") || lower.contains("xbox") || lower.contains("steamdeck") { return .gameConsole }
        if lower.contains("tv") || lower.contains("appletv") || lower.contains("mitv") || lower.contains("box") { return .tv }
        if lower.contains("switch") || lower.contains("plug") || lower.contains("socket") || lower.contains("xiaomi-iot") || lower.contains("esp") || lower.contains("tuya") || lower.contains("mijia") || lower.contains("camera") || lower.contains("speaker") || lower.contains("homepod") {
            return .smartHome
        }
        if lower.contains("android") || lower.contains("xiaomi") || lower.contains("redmi") || lower.contains("huawei") || lower.contains("honor") || lower.contains("oppo") || lower.contains("oneplus") || lower.contains("vivo") || lower.contains("iqoo") || lower.contains("samsung") || lower.contains("galaxy") || lower.contains("pixel") || lower.contains("meizu") {
            return .android
        }
        if lower.contains("pc") || lower.contains("desktop") || lower.contains("win") || lower.contains("thinkpad") || lower.contains("ubuntu") {
            return .computer
        }
        return .generic
    }
}

// MARK: - OAF 7.0 Device & App Statistics Models

struct OAFBriefApp: Identifiable, Decodable, Equatable, Hashable {
    var appId: Int
    var name: String
    var icon: Int

    var id: String { "\(appId)-\(name)" }

    init(appId: Int, name: String, icon: Int = 1) {
        self.appId = appId
        self.name = name
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            self.appId = c.flexInt([DynamicCodingKey("id"), DynamicCodingKey("appid"), DynamicCodingKey("app_id")])
            let rawName = c.flexString([DynamicCodingKey("name"), DynamicCodingKey("appname")])
            self.name = rawName.isEmpty ? (appId > 0 ? "App \(appId)" : "未知应用") : rawName
            self.icon = c.flexInt([DynamicCodingKey("icon")], default: 1)
        } else if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            self.appId = 0
            self.name = s
            self.icon = 0
        } else {
            self.appId = 0
            self.name = "应用"
            self.icon = 0
        }
    }
}

struct OAFDevice: Identifiable, Decodable, Equatable, Hashable {
    var mac: String
    var ip: String
    var ipv6: String
    var hostname: String
    var nickname: String {
        didSet { kind = DeviceKind.infer(from: "\(nickname) \(hostname)") }
    }
    var online: Int
    var active: Int
    var currentApp: String
    var currentAppId: Int
    var currentURL: String
    var applist: [OAFBriefApp]
    var upRate: Int64
    var downRate: Int64
    var todayUpBytes: Int64
    var todayDownBytes: Int64
    var todayOnlineTime: Int
    var todayActiveTime: Int
    var rssi: Int
    var band: String
    var wifiIfname: String
    var txRate: Int
    var rxRate: Int
    var sessionCount: Int
    var kind: DeviceKind

    var id: String { mac }
    var normalizedMAC: String { mac }

    var displayName: String {
        if !nickname.isEmpty { return nickname }
        if !hostname.isEmpty { return hostname }
        return mac
    }

    var secondaryName: String? {
        if !nickname.isEmpty && !hostname.isEmpty && nickname != hostname {
            return hostname
        }
        return nil
    }

    var isOnline: Bool { online == 1 }
    var isActive: Bool { online == 1 && (active == 1 || !currentApp.isEmpty) }
    var todayTotalBytes: Int64 { todayUpBytes + todayDownBytes }
    var totalLiveRate: Int64 { upRate + downRate }

    init(
        mac: String,
        ip: String,
        ipv6: String = "",
        hostname: String,
        nickname: String = "",
        online: Int = 1,
        active: Int = 0,
        currentApp: String = "",
        currentAppId: Int = 0,
        currentURL: String = "",
        applist: [OAFBriefApp] = [],
        upRate: Int64 = 0,
        downRate: Int64 = 0,
        todayUpBytes: Int64 = 0,
        todayDownBytes: Int64 = 0,
        todayOnlineTime: Int = 0,
        todayActiveTime: Int = 0,
        rssi: Int = 0,
        band: String = "",
        wifiIfname: String = "",
        txRate: Int = 0,
        rxRate: Int = 0,
        sessionCount: Int = 0
    ) {
        self.mac = mac.uppercased()
        self.ip = ip
        self.ipv6 = ipv6
        self.hostname = hostname
        self.nickname = nickname
        self.online = online
        self.active = active
        self.currentApp = currentApp
        self.currentAppId = currentAppId
        self.currentURL = currentURL
        self.applist = applist
        self.upRate = upRate
        self.downRate = downRate
        self.todayUpBytes = todayUpBytes
        self.todayDownBytes = todayDownBytes
        self.todayOnlineTime = todayOnlineTime
        self.todayActiveTime = todayActiveTime
        self.rssi = rssi
        self.band = band
        self.wifiIfname = wifiIfname
        self.txRate = txRate
        self.rxRate = rxRate
        self.sessionCount = sessionCount
        self.kind = DeviceKind.infer(from: "\(nickname) \(hostname)")
    }

    init(from decoder: Decoder) throws {
        let k = DynamicCodingKey.init(_:)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.mac = c.flexString([k("mac")]).uppercased()
        self.ip = c.flexString([k("ip")], default: "--")
        let v6 = c.flexString([k("ipv6")])
        self.ipv6 = (v6 == "::") ? "" : v6
        let host = c.flexString([k("hostname"), k("name")])
        let nick = c.flexString([k("nickname")])
        self.hostname = host
        self.nickname = nick
        self.online = c.flexInt([k("online")])
        self.active = c.flexInt([k("active")])
        self.currentApp = c.flexString([k("app")])
        self.currentAppId = c.flexInt([k("app_id"), k("appid")])
        self.currentURL = c.flexString([k("url")])
        self.applist = c.flexArray([k("applist")])
        self.upRate = c.flexInt64([k("up_rate")])
        self.downRate = c.flexInt64([k("down_rate")])
        self.todayUpBytes = c.flexInt64([k("today_up_bytes"), k("up_bytes")])
        self.todayDownBytes = c.flexInt64([k("today_down_bytes"), k("down_bytes")])
        self.todayOnlineTime = c.flexInt([k("today_online_time"), k("online_time")])
        self.todayActiveTime = c.flexInt([k("today_active_time"), k("active_time")])
        self.rssi = c.flexInt([k("rssi")])
        self.band = c.flexString([k("band")])
        self.wifiIfname = c.flexString([k("wifi_ifname")])
        self.txRate = c.flexInt([k("tx_rate")])
        self.rxRate = c.flexInt([k("rx_rate")])
        self.sessionCount = c.flexInt([k("session")])
        self.kind = DeviceKind.infer(from: "\(nick) \(host)")
    }
}

struct OAFAppDuration: Identifiable, Decodable, Equatable {
    var appId: Int
    var name: String
    var seconds: Int
    var icon: Int

    var id: String { "\(appId)-\(name)" }

    init(appId: Int, name: String, seconds: Int, icon: Int = 1) {
        self.appId = appId
        self.name = name
        self.seconds = seconds
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let k = DynamicCodingKey.init(_:)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        let aid = c.flexInt([k("id"), k("appid"), k("app_id")])
        self.appId = aid
        let rawName = c.flexString([k("name"), k("appname")])
        self.name = rawName.isEmpty ? (aid > 0 ? "App \(aid)" : "未知应用") : rawName
        self.seconds = c.flexInt([k("t"), k("visit_time"), k("time"), k("tt")])
        self.icon = c.flexInt([k("icon")], default: 1)
    }
}

struct OAFCategoryDuration: Identifiable, Decodable, Equatable {
    var categoryId: Int
    var name: String
    var seconds: Int

    var id: String { "\(categoryId)-\(name)" }

    init(categoryId: Int, name: String, seconds: Int) {
        self.categoryId = categoryId
        self.name = name
        self.seconds = seconds
    }

    init(from decoder: Decoder) throws {
        let k = DynamicCodingKey.init(_:)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        let cid = c.flexInt([k("id"), k("type"), k("class_id")])
        self.categoryId = cid
        let raw = c.flexString([k("name"), k("class_name")])
        self.name = raw.isEmpty ? Self.fallbackCategoryName(cid) : raw
        self.seconds = c.flexInt([k("t"), k("visit_time"), k("time"), k("total_time"), k("count")])
    }

    static func fallbackCategoryName(_ id: Int) -> String {
        switch id {
        case 1: return "即时通讯"
        case 2: return "游戏娱乐"
        case 3: return "视频影音"
        case 4: return "网络购物"
        case 5: return "办公学习"
        case 6: return "招聘求职"
        case 7: return "新闻资讯"
        case 8: return "文件下载"
        case 9: return "音乐电台"
        case 10: return "金融理财"
        case 13: return "常用网站"
        default: return id > 0 ? "分类 \(id)" : "其他"
        }
    }
}

struct OAFVisitRecord: Identifiable, Decodable, Equatable {
    var recordKey: String
    var appId: Int
    var appName: String
    var mac: String
    var hostname: String
    var nickname: String
    var firstTime: Int64
    var latestTime: Int64
    var durationSeconds: Int
    var isFiltered: Bool
    var isOnline: Bool
    var icon: Int

    var id: String { recordKey }

    var deviceDisplayName: String {
        if !nickname.isEmpty { return nickname }
        if !hostname.isEmpty { return hostname }
        return mac
    }

    init(
        appId: Int,
        appName: String,
        mac: String = "",
        hostname: String = "",
        nickname: String = "",
        firstTime: Int64,
        latestTime: Int64,
        durationSeconds: Int,
        isFiltered: Bool = false,
        isOnline: Bool = false,
        icon: Int = 1
    ) {
        self.appId = appId
        self.appName = appName
        self.mac = mac.uppercased()
        self.hostname = hostname
        self.nickname = nickname
        self.firstTime = firstTime
        self.latestTime = latestTime
        self.durationSeconds = durationSeconds
        self.isFiltered = isFiltered
        self.isOnline = isOnline
        self.icon = icon
        self.recordKey = "\(self.mac)-\(appId)-\(firstTime)-\(latestTime)"
    }

    init(from decoder: Decoder) throws {
        let k = DynamicCodingKey.init(_:)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        let aid = c.flexInt([k("id"), k("appid"), k("app_id")])
        self.appId = aid
        let rawName = c.flexString([k("name"), k("appname")])
        self.appName = rawName.isEmpty ? (aid > 0 ? "App \(aid)" : "未知应用") : rawName
        let m = c.flexString([k("mac")]).uppercased()
        self.mac = m
        self.hostname = c.flexString([k("hostname")])
        self.nickname = c.flexString([k("nickname")])
        let ft = c.flexInt64([k("ft"), k("first_time")])
        let lt = c.flexInt64([k("lt"), k("latest_time")])
        let tt = c.flexInt([k("tt"), k("total_time"), k("t")])
        self.firstTime = ft
        self.latestTime = lt
        self.durationSeconds = tt
        self.isFiltered = c.flexInt([k("act"), k("latest_action")]) == 1
        self.isOnline = c.flexInt([k("online")]) == 1
        self.icon = c.flexInt([k("icon")], default: 1)
        self.recordKey = "\(m)-\(aid)-\(ft)-\(lt)"
    }
}

struct OAFHourlyAppItem: Identifiable, Decodable, Equatable {
    var appId: Int
    var name: String
    var seconds: Int

    var id: String { "\(appId)-\(name)" }

    init(appId: Int, name: String, seconds: Int) {
        self.appId = appId
        self.name = name
        self.seconds = seconds
    }

    init(from decoder: Decoder) throws {
        let k = DynamicCodingKey.init(_:)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        let aid = c.flexInt([k("appid"), k("id")])
        self.appId = aid
        let raw = c.flexString([k("name"), k("appname")])
        self.name = raw.isEmpty ? (aid > 0 ? "App \(aid)" : "应用") : raw
        self.seconds = c.flexInt([k("time"), k("t"), k("visit_time")])
    }
}

struct OAFHourlyStat: Identifiable, Decodable, Equatable {
    var hour: Int
    var upBytes: Int64
    var downBytes: Int64
    var apps: [OAFHourlyAppItem]

    var id: Int { hour }
    var totalBytes: Int64 { upBytes + downBytes }
    var totalAppSeconds: Int { apps.reduce(0) { $0 + $1.seconds } }

    init(hour: Int, upBytes: Int64, downBytes: Int64, apps: [OAFHourlyAppItem]) {
        self.hour = hour
        self.upBytes = upBytes
        self.downBytes = downBytes
        self.apps = apps
    }

    private struct TrafficBox: Decodable {
        var upBytes: Int64
        var downBytes: Int64

        init(from decoder: Decoder) throws {
            let k = DynamicCodingKey.init(_:)
            let c = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.upBytes = c.flexInt64([k("up_bytes"), k("up")])
            self.downBytes = c.flexInt64([k("down_bytes"), k("down")])
        }
    }

    init(from decoder: Decoder) throws {
        let k = DynamicCodingKey.init(_:)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.hour = c.flexInt([k("hour")])
        if let t = try? c.decodeIfPresent(TrafficBox.self, forKey: k("traffic")) {
            self.upBytes = t.upBytes
            self.downBytes = t.downBytes
        } else {
            self.upBytes = c.flexInt64([k("up_bytes")])
            self.downBytes = c.flexInt64([k("down_bytes")])
        }
        self.apps = c.flexArray([k("apps"), k("list")])
    }
}

/// Supports both OAF 7.0.2 `get_user_records` (`action`, `online_duration`, `active_duration`, `up_bytes`, `down_bytes`, `recent_apps`)
/// and legacy `get_online_offline_records` (`type`, `duration`).
struct OAFOnlineOfflineEvent: Identifiable, Decodable, Equatable {
    var eventId: String
    var isOnlineEvent: Bool
    var timestamp: Int64
    var timeStr: String
    var onlineDurationSeconds: Int
    var activeDurationSeconds: Int
    var upBytes: Int64
    var downBytes: Int64
    var recentApps: [OAFBriefApp]

    var id: String { eventId }
    var totalBytes: Int64 { upBytes + downBytes }

    init(
        isOnlineEvent: Bool,
        timestamp: Int64,
        timeStr: String = "",
        durationSeconds: Int = 0,
        activeDurationSeconds: Int = 0,
        upBytes: Int64 = 0,
        downBytes: Int64 = 0,
        recentApps: [OAFBriefApp] = []
    ) {
        self.isOnlineEvent = isOnlineEvent
        self.timestamp = timestamp
        self.timeStr = timeStr
        self.onlineDurationSeconds = durationSeconds
        self.activeDurationSeconds = activeDurationSeconds
        self.upBytes = upBytes
        self.downBytes = downBytes
        self.recentApps = recentApps
        self.eventId = "\(isOnlineEvent ? 0 : 1)-\(timestamp)-\(durationSeconds)"
    }

    init(from decoder: Decoder) throws {
        let k = DynamicCodingKey.init(_:)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        let actionStr = c.flexString([k("action_str")]).lowercased()
        let rawAction = c.flexInt([k("action"), k("type")], default: 0)
        if !actionStr.isEmpty {
            self.isOnlineEvent = (actionStr == "online")
        } else {
            self.isOnlineEvent = (rawAction == 0)
        }
        let ts = c.flexInt64([k("timestamp"), k("time")])
        self.timestamp = ts
        self.timeStr = c.flexString([k("time_str")])
        let onDur = c.flexInt([k("online_duration"), k("duration")])
        self.onlineDurationSeconds = onDur
        self.activeDurationSeconds = c.flexInt([k("active_duration")])
        self.upBytes = c.flexInt64([k("up_bytes")])
        self.downBytes = c.flexInt64([k("down_bytes")])
        self.recentApps = c.flexArray([k("recent_apps")])
        self.eventId = "\(self.isOnlineEvent ? 0 : 1)-\(ts)-\(onDur)"
    }
}

struct DeviceDetailBundle: Equatable {
    var basicInfo: OAFDevice?
    var appDurations: [OAFAppDuration] = []
    var categoryDurations: [OAFCategoryDuration] = []
    var hourlyStats: [OAFHourlyStat] = []
    var visitRecords: [OAFVisitRecord] = []
    var visitTotalCount: Int = 0
    var visitPage: Int = 1
    var visitTotalPages: Int = 1
    var onlineEvents: [OAFOnlineOfflineEvent] = []
}

// MARK: - Live Whole-Network Overview Models

struct OAFGlobalHourlyTraffic: Identifiable, Decodable, Equatable {
    var hour: Int
    var upBytes: Int64
    var downBytes: Int64

    var id: Int { hour }
    var totalBytes: Int64 { upBytes + downBytes }

    init(hour: Int, upBytes: Int64, downBytes: Int64) {
        self.hour = hour
        self.upBytes = upBytes
        self.downBytes = downBytes
    }

    init(from decoder: Decoder) throws {
        let k = DynamicCodingKey.init(_:)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.hour = c.flexInt([k("hour")])
        self.upBytes = c.flexInt64([k("up_bytes"), k("up")])
        self.downBytes = c.flexInt64([k("down_bytes"), k("down")])
    }
}

// MARK: - Router Bark Agent Config Models

struct BarkPushEvent: Identifiable, Decodable, Equatable {
    var eventId: String
    var type: String
    var mac: String
    var name: String
    var ip: String
    var detail: String
    var pushed: Bool
    var timestamp: Int64

    var id: String { eventId }
    var isOnline: Bool { type == "online" }

    init(type: String, mac: String, name: String, ip: String, detail: String, pushed: Bool, timestamp: Int64) {
        self.type = type
        self.mac = mac.uppercased()
        self.name = name
        self.ip = ip
        self.detail = detail
        self.pushed = pushed
        self.timestamp = timestamp
        self.eventId = "\(self.mac)-\(timestamp)-\(type)"
    }

    init(from decoder: Decoder) throws {
        let k = DynamicCodingKey.init(_:)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        let t = c.flexString([k("type")], default: "online")
        let m = c.flexString([k("mac")]).uppercased()
        let ts = c.flexInt64([k("timestamp")])
        self.type = t
        self.mac = m
        self.name = c.flexString([k("name")], default: m)
        self.ip = c.flexString([k("ip")])
        self.detail = c.flexString([k("detail")])
        self.pushed = c.flexInt([k("pushed")]) == 1
        self.timestamp = ts
        self.eventId = "\(m)-\(ts)-\(t)"
    }
}

struct BarkAgentConfig: Equatable, Decodable {
    var enabled: Bool = false
    var barkServer: String = "https://api.day.app"
    var barkKey: String = ""
    var pollInterval: Int = 15
    var offlineDebounce: Int = 90
    var watchMode: String = "selected"
    var notifyOnline: Bool = true
    var notifyOffline: Bool = true
    var includeSummary: Bool = true
    var quietEnable: Bool = false
    var quietStart: String = "23:30"
    var quietEnd: String = "07:00"
    var watchedMACs: [String] = []
    var daemonRunning: Bool = false
    var recentEvents: [BarkPushEvent] = []

    init() {}

    init(
        enabled: Bool,
        barkServer: String = "https://api.day.app",
        barkKey: String,
        pollInterval: Int = 15,
        offlineDebounce: Int = 90,
        watchMode: String = "selected",
        notifyOnline: Bool = true,
        notifyOffline: Bool = true,
        includeSummary: Bool = true,
        quietEnable: Bool = false,
        quietStart: String = "23:30",
        quietEnd: String = "07:00",
        watchedMACs: [String] = [],
        daemonRunning: Bool = true,
        recentEvents: [BarkPushEvent] = []
    ) {
        self.enabled = enabled
        self.barkServer = barkServer
        self.barkKey = barkKey
        self.pollInterval = pollInterval
        self.offlineDebounce = offlineDebounce
        self.watchMode = watchMode
        self.notifyOnline = notifyOnline
        self.notifyOffline = notifyOffline
        self.includeSummary = includeSummary
        self.quietEnable = quietEnable
        self.quietStart = quietStart
        self.quietEnd = quietEnd
        self.watchedMACs = watchedMACs.map { $0.uppercased() }
        self.daemonRunning = daemonRunning
        self.recentEvents = recentEvents
    }

    init(from decoder: Decoder) throws {
        let k = DynamicCodingKey.init(_:)
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.enabled = c.flexInt([k("enabled")]) == 1
        let srv = c.flexString([k("bark_server")], default: "https://api.day.app")
        self.barkServer = srv.isEmpty ? "https://api.day.app" : srv
        self.barkKey = c.flexString([k("bark_key")])
        self.pollInterval = max(10, c.flexInt([k("poll_interval")], default: 15))
        self.offlineDebounce = max(15, c.flexInt([k("offline_debounce")], default: 90))
        let wm = c.flexString([k("watch_mode")], default: "selected")
        self.watchMode = (wm == "all") ? "all" : "selected"
        self.notifyOnline = c.flexInt([k("notify_online")], default: 1) == 1
        self.notifyOffline = c.flexInt([k("notify_offline")], default: 1) == 1
        self.includeSummary = c.flexInt([k("include_summary")], default: 1) == 1
        self.quietEnable = c.flexInt([k("quiet_enable")], default: 0) == 1
        self.quietStart = c.flexString([k("quiet_start")], default: "23:30")
        self.quietEnd = c.flexString([k("quiet_end")], default: "07:00")
        self.watchedMACs = c.flexArray([k("watched_macs")], of: String.self).map { $0.uppercased() }
        self.daemonRunning = c.flexInt([k("daemon_running")]) == 1
        self.recentEvents = c.flexArray([k("recent_events")], of: BarkPushEvent.self)
    }

    func isWatching(_ mac: String) -> Bool {
        if watchMode == "all" { return true }
        return watchedMACs.contains(mac.uppercased())
    }
}
