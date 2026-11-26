import SwiftUI
import UIKit

// MARK: - Zero-Jank Synchronous App Icon Cache (With Negative 404 Cache & Deduplication)

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    var activeBaseURL: String?
    var allowInsecureTLS: Bool = true

    private let imageCache = NSCache<NSString, UIImage>()
    private var missingKeys = Set<String>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private lazy var insecureSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3.0
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg, delegate: InsecureTLSDelegate(allowInsecure: true), delegateQueue: nil)
    }()

    private lazy var strictSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3.0
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg, delegate: InsecureTLSDelegate(allowInsecure: false), delegateQueue: nil)
    }()

    func lookupSync(appId: Int) -> UIImage? {
        guard appId > 0, let base = activeBaseURL else { return nil }
        let key = "\(base)|\(appId)" as NSString
        return imageCache.object(forKey: key)
    }

    func isKnownMissing(appId: Int) -> Bool {
        guard appId > 0, let base = activeBaseURL else { return true }
        return missingKeys.contains("\(base)|\(appId)")
    }

    func fetchIfNeeded(appId: Int) async -> UIImage? {
        guard appId > 0, let base = activeBaseURL else { return nil }
        let key = "\(base)|\(appId)"
        if let hit = imageCache.object(forKey: key as NSString) {
            return hit
        }
        if missingKeys.contains(key) {
            return nil
        }
        if let existingTask = inFlight[key] {
            return await existingTask.value
        }

        let useInsecure = allowInsecureTLS
        let session = useInsecure ? insecureSession : strictSession
        let task = Task<UIImage?, Never> {
            guard let url = URL(string: "\(base)/luci-static/resources/oaf/app_icons/\(appId).png") else {
                return nil
            }
            guard let (data, resp) = try? await session.data(from: url),
                  let http = resp as? HTTPURLResponse,
                  http.statusCode == 200,
                  let decoded = UIImage(data: data) else {
                return nil
            }
            return decoded
        }

        inFlight[key] = task
        let img = await task.value
        inFlight[key] = nil

        if let img {
            imageCache.setObject(img, forKey: key as NSString)
        } else {
            missingKeys.insert(key)
        }
        return img
    }
}

// MARK: - Palette & Formatting Utilities

enum OAFTheme {
    static let primaryIndigo = Color(red: 0.31, green: 0.27, blue: 0.90)
    static let electricCyan = Color(red: 0.02, green: 0.71, blue: 0.83)
    static let activeEmerald = Color(red: 0.06, green: 0.73, blue: 0.51)
    static let onlineBlue = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let amberAccent = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let coralRose = Color(red: 0.94, green: 0.27, blue: 0.37)

    static let chartPalette: [Color] = [
        Color(red: 0.31, green: 0.27, blue: 0.90),
        Color(red: 0.06, green: 0.73, blue: 0.51),
        Color(red: 0.02, green: 0.71, blue: 0.83),
        Color(red: 0.96, green: 0.62, blue: 0.04),
        Color(red: 0.93, green: 0.28, blue: 0.60),
        Color(red: 0.55, green: 0.36, blue: 0.96),
        Color(red: 0.98, green: 0.45, blue: 0.09),
        Color(red: 0.23, green: 0.51, blue: 0.96)
    ]

    static func color(at index: Int) -> Color {
        chartPalette[abs(index) % chartPalette.count]
    }

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [primaryIndigo, Color(red: 0.15, green: 0.48, blue: 0.95), electricCyan],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum Formatters {
    private static let todayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    private static let yesterdayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "HH:mm"
        return df
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "MM-dd HH:mm"
        return df
    }()

    static func duration(_ seconds: Int, compact: Bool = false) -> String {
        guard seconds > 0 else { return compact ? "0m" : "0分钟" }
        if seconds < 60 {
            return compact ? "\(seconds)s" : "\(seconds)秒"
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if compact {
            if h > 0 && m > 0 { return "\(h)h \(m)m" }
            if h > 0 { return "\(h)h" }
            return "\(m)m"
        } else {
            if h > 0 && m > 0 { return "\(h)小时\(m)分" }
            if h > 0 { return "\(h)小时" }
            return "\(m)分钟"
        }
    }

    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "0 MB" }
        let b = Double(value)
        if b >= 1_073_741_824 {
            return String(format: "%.2f GB", b / 1_073_741_824)
        } else if b >= 1_048_576 {
            return String(format: "%.1f MB", b / 1_048_576)
        } else if b >= 1024 {
            return String(format: "%.0f KB", b / 1024)
        }
        return "\(value) B"
    }

    static func rate(_ bytesPerSec: Int64) -> String {
        guard bytesPerSec > 0 else { return "0 KB/s" }
        let b = Double(bytesPerSec)
        if b >= 1_048_576 {
            return String(format: "%.1f MB/s", b / 1_048_576)
        } else if b >= 1024 {
            return String(format: "%.0f KB/s", b / 1024)
        }
        return "\(bytesPerSec) B/s"
    }

    static func timestamp(_ unixSeconds: Int64) -> String {
        guard unixSeconds > 0 else { return "--" }
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "今天 " + todayFormatter.string(from: date)
        } else if cal.isDateInYesterday(date) {
            return "昨天 " + yesterdayFormatter.string(from: date)
        } else {
            return dateTimeFormatter.string(from: date)
        }
    }

    static func relativeShort(_ unixSeconds: Int64) -> String {
        guard unixSeconds > 0 else { return "--" }
        let diff = max(0, Int(Date().timeIntervalSince1970) - Int(unixSeconds))
        if diff < 15 { return "刚刚" }
        if diff < 60 { return "\(diff)秒前" }
        if diff < 3600 { return "\(diff / 60)分钟前" }
        if diff < 86400 { return "\(diff / 3600)小时前" }
        return "\(diff / 86400)天前"
    }
}

// MARK: - GPU-Friendly Bento Card Container (Zero Offscreen Blur Pass!)

struct BentoCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.6)
            )
    }
}

// MARK: - Crisp Zero-Cost Status Indicator Dot

struct PulseStatusDot: View {
    var isOnline: Bool
    var isActive: Bool
    var size: CGFloat = 9

    private var dotColor: Color {
        if !isOnline { return Color.secondary.opacity(0.45) }
        return isActive ? OAFTheme.activeEmerald : OAFTheme.onlineBlue
    }

    var body: some View {
        ZStack {
            if isOnline {
                Circle()
                    .fill(dotColor.opacity(0.20))
                    .frame(width: size * 1.85, height: size * 1.85)
            }
            Circle()
                .fill(dotColor)
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.85, height: size * 1.85)
    }
}

// MARK: - Smart Device Avatar View

struct DeviceAvatarBadge: View {
    let device: OAFDevice
    var size: CGFloat = 46

    private var colors: [Color] {
        if !device.isOnline {
            return [Color.gray.opacity(0.35), Color.gray.opacity(0.2)]
        }
        switch device.kind {
        case .iPhone, .iPad, .watch:
            return [OAFTheme.primaryIndigo, OAFTheme.onlineBlue]
        case .mac, .computer:
            return [Color(red: 0.09, green: 0.56, blue: 0.88), OAFTheme.electricCyan]
        case .android:
            return [OAFTheme.activeEmerald, Color(red: 0.05, green: 0.60, blue: 0.53)]
        case .gameConsole:
            return [Color(red: 0.93, green: 0.28, blue: 0.60), Color(red: 0.55, green: 0.36, blue: 0.96)]
        case .tv:
            return [Color(red: 0.55, green: 0.36, blue: 0.96), OAFTheme.primaryIndigo]
        case .smartHome, .generic:
            return [OAFTheme.amberAccent, Color(red: 0.95, green: 0.45, blue: 0.15)]
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: device.kind.sfSymbol)
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                )

            Circle()
                .fill(device.isOnline ? (device.isActive ? OAFTheme.activeEmerald : OAFTheme.onlineBlue) : Color(uiColor: .systemGray3))
                .frame(width: size * 0.27, height: size * 0.27)
                .overlay(
                    Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2)
                )
                .offset(x: 2, y: 2)
        }
    }
}

// MARK: - Smart App Icon Badge (Keyed by appId, Sync Cache Hit, Zero Scroll Lag)

struct AppIconBadge: View {
    let appId: Int
    let appName: String
    var allowRemoteIcon: Bool = true
    var allowInsecureTLS: Bool = true
    var size: CGFloat = 30

    @State private var loadedForAppId: Int = -1
    @State private var loadedImage: UIImage?

    private var curatedVisual: (symbol: String?, label: String, color: Color) {
        let lower = appName.lowercased()
        if lower.contains("微信") || lower.contains("wechat") {
            return ("message.fill", "微", Color(red: 0.03, green: 0.76, blue: 0.38))
        }
        if lower.contains("抖音") || lower.contains("tiktok") {
            return ("play.rectangle.fill", "抖", Color(red: 0.11, green: 0.11, blue: 0.16))
        }
        if lower.contains("哔哩") || lower.contains("bilibili") {
            return ("tv.and.mediabox.fill", "B", Color(red: 0.98, green: 0.45, blue: 0.60))
        }
        if lower.contains("小红书") {
            return ("heart.text.square.fill", "红", Color(red: 1.00, green: 0.18, blue: 0.30))
        }
        if lower.contains("telegram") {
            return ("paperplane.fill", "TG", Color(red: 0.14, green: 0.63, blue: 0.88))
        }
        if lower.contains("youtube") {
            return ("play.tv.fill", "YT", Color(red: 0.94, green: 0.16, blue: 0.16))
        }
        if lower.contains("王者") || lower.contains("和平精英") || lower.contains("原神") || lower.contains("steam") || lower.contains("游戏") {
            return ("gamecontroller.fill", "游", Color(red: 0.55, green: 0.36, blue: 0.96))
        }
        if lower.contains("拼多多") || lower.contains("淘宝") || lower.contains("京东") || lower.contains("美团") {
            return ("bag.fill", "购", Color(red: 0.98, green: 0.45, blue: 0.09))
        }
        if lower.contains("音乐") || lower.contains("spotify") || lower.contains("apple music") {
            return ("music.note", "乐", Color(red: 0.93, green: 0.24, blue: 0.36))
        }
        if lower.contains("qq") {
            return ("bubble.left.and.bubble.right.fill", "Q", Color(red: 0.12, green: 0.58, blue: 0.95))
        }
        let firstChar = appName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)
        let text = firstChar.isEmpty ? "A" : String(firstChar).uppercased()
        let color = OAFTheme.color(at: appId > 0 ? appId : appName.hashValue)
        return (nil, text, color)
    }

    var body: some View {
        let syncCached = allowRemoteIcon ? AppIconCache.shared.lookupSync(appId: appId) : nil
        let effectiveImage = syncCached ?? (loadedForAppId == appId ? loadedImage : nil)

        Group {
            if let img = effectiveImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            } else {
                let visual = curatedVisual
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [visual.color, visual.color.opacity(0.76)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay {
                        if let sym = visual.symbol, size >= 24 {
                            Image(systemName: sym)
                                .font(.system(size: size * 0.46, weight: .semibold))
                                .foregroundStyle(.white)
                        } else {
                            Text(visual.label)
                                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
            }
        }
        .task(id: appId) {
            guard allowRemoteIcon, appId > 0 else { return }
            if AppIconCache.shared.lookupSync(appId: appId) != nil || AppIconCache.shared.isKnownMissing(appId: appId) {
                return
            }
            if let fetched = await AppIconCache.shared.fetchIfNeeded(appId: appId) {
                loadedForAppId = appId
                loadedImage = fetched
            }
        }
    }
}

// MARK: - Lightweight Progress Bar (Zero GeometryReader Pass)

struct SlimProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ProgressView(value: min(1.0, max(0.02, fraction)), total: 1.0)
            .progressViewStyle(.linear)
            .tint(color)
            .scaleEffect(x: 1, y: 1.35, anchor: .center)
    }
}

// MARK: - Interactive Animated Donut Ring Chart (iOS 16+ Native)

struct DonutSlice: Identifiable, Equatable {
    let id: String
    let title: String
    let seconds: Int
    let color: Color
}

struct DonutRingChart: View {
    let slices: [DonutSlice]
    var centerTitle: String = "今日总活跃"
    @Binding var selectedSliceId: String?

    private var totalSeconds: Double {
        max(1, Double(slices.reduce(0) { $0 + $1.seconds }))
    }

    private struct PositionedSlice: Identifiable {
        let slice: DonutSlice
        let startTrim: CGFloat
        let endTrim: CGFloat
        var id: String { slice.id }
    }

    private var positionedSlices: [PositionedSlice] {
        var cursor: CGFloat = 0
        let gap: CGFloat = slices.count > 1 ? 0.008 : 0
        return slices.map { s in
            let fraction = CGFloat(Double(s.seconds) / totalSeconds)
            let start = cursor + gap / 2
            let end = max(start + 0.004, cursor + fraction - gap / 2)
            cursor += fraction
            return PositionedSlice(slice: s, startTrim: start, endTrim: min(1.0, end))
        }
    }

    private var activeSlice: DonutSlice? {
        guard let selectedSliceId else { return nil }
        return slices.first(where: { $0.id == selectedSliceId })
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: 22)

            ForEach(positionedSlices) { item in
                let isSelected = selectedSliceId == item.slice.id
                Circle()
                    .trim(from: item.startTrim, to: item.endTrim)
                    .stroke(
                        item.slice.color,
                        style: StrokeStyle(lineWidth: isSelected ? 27 : 21, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
                    .opacity(selectedSliceId == nil || isSelected ? 1.0 : 0.42)
                    .animation(.spring(response: 0.32, dampingFraction: 0.8), value: selectedSliceId)
                    .onTapGesture {
                        if selectedSliceId == item.slice.id {
                            selectedSliceId = nil
                        } else {
                            selectedSliceId = item.slice.id
                        }
                    }
            }

            VStack(spacing: 4) {
                if let active = activeSlice {
                    Text(active.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 108)
                    Text(Formatters.duration(active.seconds, compact: true))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)
                    let pct = Int(round((Double(active.seconds) / totalSeconds) * 100))
                    Text("占比 \(pct)%")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(active.color)
                } else {
                    Text(centerTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(Formatters.duration(Int(totalSeconds), compact: true))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)
                    Text("轻触色环筛选")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 176, height: 176)
    }
}

// MARK: - Empty / Placeholder Card

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
