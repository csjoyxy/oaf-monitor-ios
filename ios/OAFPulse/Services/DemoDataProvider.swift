import Foundation

enum DemoDataProvider {
    static func devices() -> [OAFDevice] {
        [
            OAFDevice(
                mac: "76:13:65:14:B8:09",
                ip: "192.168.10.105",
                hostname: "lili-iPhone",
                nickname: "lili-iPhone",
                online: 1,
                active: 1,
                currentApp: "抖音",
                currentAppId: 3001,
                currentURL: "v26-web.douyinvod.com",
                applist: [
                    OAFBriefApp(appId: 3001, name: "抖音"),
                    OAFBriefApp(appId: 1001, name: "微信"),
                    OAFBriefApp(appId: 7012, name: "小红书")
                ],
                upRate: 68_400,
                downRate: 2_840_000,
                todayUpBytes: 186_400_000,
                todayDownBytes: 2_940_000_000,
                todayOnlineTime: 18_420,
                todayActiveTime: 9_840,
                rssi: -58,
                band: "5GHz",
                wifiIfname: "phy1-ap0",
                txRate: 866,
                rxRate: 866,
                sessionCount: 48
            ),
            OAFDevice(
                mac: "A4:CF:99:82:10:3E",
                ip: "192.168.10.102",
                hostname: "My-iPhone-16Pro",
                nickname: "我的 iPhone",
                online: 1,
                active: 1,
                currentApp: "哔哩哔哩",
                currentAppId: 3005,
                currentURL: "api.bilibili.com",
                applist: [
                    OAFBriefApp(appId: 3005, name: "哔哩哔哩"),
                    OAFBriefApp(appId: 1008, name: "Telegram"),
                    OAFBriefApp(appId: 1001, name: "微信")
                ],
                upRate: 42_000,
                downRate: 1_520_000,
                todayUpBytes: 245_000_000,
                todayDownBytes: 3_680_000_000,
                todayOnlineTime: 22_500,
                todayActiveTime: 12_360,
                rssi: -51,
                band: "5GHz",
                wifiIfname: "phy1-ap0",
                txRate: 1201,
                rxRate: 1201,
                sessionCount: 64
            ),
            OAFDevice(
                mac: "BC:D0:74:33:91:20",
                ip: "192.168.10.118",
                hostname: "LivingRoom-iPad",
                nickname: "客厅 iPad Pro",
                online: 1,
                active: 0,
                currentApp: "",
                currentAppId: 0,
                applist: [
                    OAFBriefApp(appId: 2001, name: "王者荣耀"),
                    OAFBriefApp(appId: 3002, name: "腾讯视频")
                ],
                upRate: 1_200,
                downRate: 3_400,
                todayUpBytes: 94_000_000,
                todayDownBytes: 1_850_000_000,
                todayOnlineTime: 14_200,
                todayActiveTime: 6_420,
                rssi: -63,
                band: "5GHz",
                wifiIfname: "phy1-ap0",
                txRate: 866,
                rxRate: 780,
                sessionCount: 14
            ),
            OAFDevice(
                mac: "F0:18:98:5A:C2:77",
                ip: "192.168.10.156",
                hostname: "BullSwitch",
                nickname: "公牛智能插座",
                online: 1,
                active: 0,
                upRate: 320,
                downRate: 480,
                todayUpBytes: 2_400_000,
                todayDownBytes: 4_100_000,
                todayOnlineTime: 79_200,
                todayActiveTime: 420,
                rssi: -67,
                band: "2.4GHz",
                wifiIfname: "phy0-ap0",
                txRate: 72,
                rxRate: 72,
                sessionCount: 3
            ),
            OAFDevice(
                mac: "58:D3:49:1E:7C:11",
                ip: "192.168.10.129",
                hostname: "MacBook-Air-M3",
                nickname: "书房 MacBook",
                online: 0,
                active: 0,
                todayUpBytes: 410_000_000,
                todayDownBytes: 1_420_000_000,
                todayOnlineTime: 11_400,
                todayActiveTime: 8_100
            )
        ]
    }

    static func detail(for device: OAFDevice) -> DeviceDetailBundle {
        let now = Int64(Date().timeIntervalSince1970)
        let durations: [OAFAppDuration] = [
            OAFAppDuration(appId: 3001, name: "抖音", seconds: 3_960),
            OAFAppDuration(appId: 1001, name: "微信", seconds: 2_340),
            OAFAppDuration(appId: 7012, name: "小红书", seconds: 1_680),
            OAFAppDuration(appId: 3005, name: "哔哩哔哩", seconds: 1_080),
            OAFAppDuration(appId: 4001, name: "淘宝", seconds: 540),
            OAFAppDuration(appId: 9001, name: "网易云音乐", seconds: 240)
        ]
        let categories: [OAFCategoryDuration] = [
            OAFCategoryDuration(categoryId: 3, name: "视频影音", seconds: 5_040),
            OAFCategoryDuration(categoryId: 1, name: "即时通讯", seconds: 2_340),
            OAFCategoryDuration(categoryId: 7, name: "社区资讯", seconds: 1_680),
            OAFCategoryDuration(categoryId: 4, name: "网络购物", seconds: 540),
            OAFCategoryDuration(categoryId: 9, name: "音乐电台", seconds: 240)
        ]

        var hourly: [OAFHourlyStat] = []
        for h in 0..<24 {
            let activeFactor: Double = (h >= 8 && h <= 23) ? Double((h % 5) + 1) : 0.15
            let down = Int64(activeFactor * 95_000_000)
            let up = Int64(activeFactor * 9_500_000)
            let apps: [OAFHourlyAppItem] = h >= 8 ? [
                OAFHourlyAppItem(appId: 3001, name: "抖音", seconds: Int(activeFactor * 260)),
                OAFHourlyAppItem(appId: 1001, name: "微信", seconds: Int(activeFactor * 160)),
                OAFHourlyAppItem(appId: 7012, name: "小红书", seconds: Int(activeFactor * 90))
            ] : []
            hourly.append(OAFHourlyStat(hour: h, upBytes: up, downBytes: down, apps: apps))
        }

        let records: [OAFVisitRecord] = [
            OAFVisitRecord(appId: 3001, appName: "抖音", mac: device.mac, hostname: device.hostname, nickname: device.nickname, firstTime: now - 1_420, latestTime: now - 8, durationSeconds: 1_412, isOnline: true),
            OAFVisitRecord(appId: 1001, appName: "微信", mac: device.mac, hostname: device.hostname, nickname: device.nickname, firstTime: now - 3_800, latestTime: now - 45, durationSeconds: 920, isOnline: true),
            OAFVisitRecord(appId: 7012, appName: "小红书", mac: device.mac, hostname: device.hostname, nickname: device.nickname, firstTime: now - 6_400, latestTime: now - 2_100, durationSeconds: 1_280, isOnline: false),
            OAFVisitRecord(appId: 3005, appName: "哔哩哔哩", mac: device.mac, hostname: device.hostname, nickname: device.nickname, firstTime: now - 11_200, latestTime: now - 9_800, durationSeconds: 1_080, isOnline: false),
            OAFVisitRecord(appId: 4001, appName: "淘宝", mac: device.mac, hostname: device.hostname, nickname: device.nickname, firstTime: now - 15_600, latestTime: now - 15_060, durationSeconds: 540, isOnline: false)
        ]

        let onOff: [OAFOnlineOfflineEvent] = [
            OAFOnlineOfflineEvent(isOnlineEvent: true, timestamp: now - 3_900),
            OAFOnlineOfflineEvent(isOnlineEvent: false, timestamp: now - 9_600, durationSeconds: 7_420),
            OAFOnlineOfflineEvent(isOnlineEvent: true, timestamp: now - 17_020),
            OAFOnlineOfflineEvent(isOnlineEvent: false, timestamp: now - 42_000, durationSeconds: 11_200)
        ]

        return DeviceDetailBundle(
            basicInfo: device,
            appDurations: durations,
            categoryDurations: categories,
            hourlyStats: hourly,
            visitRecords: records,
            visitTotalCount: records.count,
            visitPage: 1,
            visitTotalPages: 1,
            onlineEvents: onOff
        )
    }

    static func liveOverview() -> (activeRecords: [OAFVisitRecord], globalTraffic: [OAFGlobalHourlyTraffic]) {
        let now = Int64(Date().timeIntervalSince1970)
        let active: [OAFVisitRecord] = [
            OAFVisitRecord(appId: 3001, appName: "抖音", mac: "76:13:65:14:B8:09", hostname: "lili-iPhone", nickname: "lili-iPhone", firstTime: now - 1_420, latestTime: now - 5, durationSeconds: 1_415, isOnline: true),
            OAFVisitRecord(appId: 3005, appName: "哔哩哔哩", mac: "A4:CF:99:82:10:3E", hostname: "My-iPhone-16Pro", nickname: "我的 iPhone", firstTime: now - 920, latestTime: now - 3, durationSeconds: 917, isOnline: true),
            OAFVisitRecord(appId: 1001, appName: "微信", mac: "76:13:65:14:B8:09", hostname: "lili-iPhone", nickname: "lili-iPhone", firstTime: now - 3_800, latestTime: now - 25, durationSeconds: 920, isOnline: true),
            OAFVisitRecord(appId: 1008, appName: "Telegram", mac: "A4:CF:99:82:10:3E", hostname: "My-iPhone-16Pro", nickname: "我的 iPhone", firstTime: now - 2_100, latestTime: now - 18, durationSeconds: 610, isOnline: true)
        ]
        let traffic = (0..<24).map { h -> OAFGlobalHourlyTraffic in
            let factor = (h >= 7 && h <= 23) ? Int64((h % 6) + 2) : 1
            return OAFGlobalHourlyTraffic(hour: h, upBytes: factor * 36_000_000, downBytes: factor * 380_000_000)
        }
        return (active, traffic)
    }

    static func barkConfig() -> BarkAgentConfig {
        let now = Int64(Date().timeIntervalSince1970)
        return BarkAgentConfig(
            enabled: true,
            barkServer: "https://api.day.app",
            barkKey: "DemoBarkKey_8x92LpQ",
            pollInterval: 15,
            offlineDebounce: 90,
            watchMode: "selected",
            notifyOnline: true,
            notifyOffline: true,
            includeSummary: true,
            quietEnable: true,
            quietStart: "23:30",
            quietEnd: "07:00",
            watchedMACs: ["76:13:65:14:B8:09", "A4:CF:99:82:10:3E"],
            daemonRunning: true,
            recentEvents: [
                BarkPushEvent(type: "online", mac: "76:13:65:14:B8:09", name: "lili-iPhone", ip: "192.168.10.105", detail: "连接恢复在线", pushed: true, timestamp: now - 3_900),
                BarkPushEvent(type: "offline", mac: "58:D3:49:1E:7C:11", name: "书房 MacBook", ip: "192.168.10.129", detail: "本次在线 3小时10分 | GitHub(1h15m)、哔哩哔哩(42m)", pushed: true, timestamp: now - 6_200)
            ]
        )
    }
}
