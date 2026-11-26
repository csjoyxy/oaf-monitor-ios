import SwiftUI
import Charts

private enum DetailSegment: String, CaseIterable, Identifiable {
    case stats = "应用统计"
    case records = "访问流水"
    case sessions = "上下线"

    var id: String { rawValue }
}

struct DeviceDetailView: View {
    @EnvironmentObject private var store: AppStore
    let initialDevice: OAFDevice

    @State private var detail = DeviceDetailBundle()
    @State private var isLoading: Bool = true
    @State private var isLoadingMoreVisits: Bool = false
    @State private var segment: DetailSegment = .stats
    @State private var selectedSliceId: String?
    @State private var selectedHour: Int?
    @State private var hourlyMetricIsTraffic: Bool = false
    @State private var showRenameAlert: Bool = false
    @State private var nicknameInput: String = ""

    private var liveDevice: OAFDevice {
        if let updated = store.devices.first(where: { $0.normalizedMAC == initialDevice.normalizedMAC }) {
            return updated
        }
        return detail.basicInfo ?? initialDevice
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DeviceHeroCard(
                    device: liveDevice,
                    basicOverride: detail.basicInfo,
                    allowRemoteIcon: !store.isDemoMode,
                    allowInsecureTLS: store.profile.allowInsecureTLS,
                    onEditName: {
                        nicknameInput = liveDevice.nickname.isEmpty ? liveDevice.displayName : liveDevice.nickname
                        showRenameAlert = true
                    }
                )

                KPIGridSection(device: detail.basicInfo ?? liveDevice)

                SegmentedTabPill(selection: $segment)

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在加载该设备的 OAF 访问详情...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 44)
                } else {
                    switch segment {
                    case .stats:
                        AppStatsSection(
                            durations: detail.appDurations,
                            categories: detail.categoryDurations,
                            hourlyStats: detail.hourlyStats,
                            selectedSliceId: $selectedSliceId,
                            selectedHour: $selectedHour,
                            hourlyMetricIsTraffic: $hourlyMetricIsTraffic,
                            allowRemoteIcon: !store.isDemoMode,
                            allowInsecureTLS: store.profile.allowInsecureTLS
                        )
                    case .records:
                        VisitTimelineSection(
                            records: detail.visitRecords,
                            currentPage: detail.visitPage,
                            totalPages: detail.visitTotalPages,
                            isLoadingMore: isLoadingMoreVisits,
                            allowRemoteIcon: !store.isDemoMode,
                            allowInsecureTLS: store.profile.allowInsecureTLS,
                            onLoadMore: {
                                Task { await loadNextVisitPage() }
                            }
                        )
                    case .sessions:
                        OnlineOfflineTimelineSection(events: detail.onlineEvents)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(liveDevice.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    Task { await store.toggleDeviceWatch(liveDevice) }
                } label: {
                    let watching = store.isWatching(liveDevice)
                    HStack(spacing: 4) {
                        Image(systemName: watching ? "bell.fill" : "bell")
                            .font(.subheadline.weight(.semibold))
                        Text(watching ? "已提醒" : "提醒")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(watching ? .white : .primary)
                    .background(
                        Capsule()
                            .fill(watching ? AnyShapeStyle(OAFTheme.amberAccent) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)))
                    )
                }

                Button {
                    nicknameInput = liveDevice.nickname.isEmpty ? liveDevice.displayName : liveDevice.nickname
                    showRenameAlert = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .refreshable {
            await fetchAllDetail(showSpinner: false)
        }
        .task(id: initialDevice.normalizedMAC) {
            await fetchAllDetail(showSpinner: true)
        }
        .alert("修改设备备注名", isPresented: $showRenameAlert) {
            TextField("例如：我的 iPhone", text: $nicknameInput)
            Button("取消", role: .cancel) {}
            Button("保存") {
                Task {
                    await store.renameDevice(liveDevice, nickname: nicknameInput)
                    await fetchAllDetail(showSpinner: false)
                }
            }
        } message: {
            Text("MAC: \(liveDevice.normalizedMAC)")
        }
    }

    private func fetchAllDetail(showSpinner: Bool) async {
        if showSpinner { isLoading = true }
        defer { if showSpinner { isLoading = false } }
        do {
            let loaded = try await store.loadDetail(for: liveDevice)
            self.detail = loaded
            if selectedHour == nil {
                let curHour = Calendar.current.component(.hour, from: Date())
                if loaded.hourlyStats.contains(where: { $0.hour == curHour && ($0.totalAppSeconds > 0 || $0.totalBytes > 0) }) {
                    selectedHour = curHour
                }
            }
        } catch {
            store.showToast(error.localizedDescription, isError: true)
        }
    }

    private func loadNextVisitPage() async {
        guard !isLoadingMoreVisits, detail.visitPage < detail.visitTotalPages else { return }
        isLoadingMoreVisits = true
        defer { isLoadingMoreVisits = false }
        do {
            let next = detail.visitPage + 1
            let res = try await store.loadMoreVisitRecords(for: liveDevice.normalizedMAC, page: next)
            detail.visitRecords.append(contentsOf: res.records)
            detail.visitPage = res.page
            detail.visitTotalPages = res.totalPages
        } catch {
            store.showToast(error.localizedDescription, isError: true)
        }
    }
}

// MARK: - Device Hero Profile Card

private struct DeviceHeroCard: View {
    let device: OAFDevice
    let basicOverride: OAFDevice?
    let allowRemoteIcon: Bool
    let allowInsecureTLS: Bool
    let onEditName: () -> Void

    private var merged: OAFDevice { basicOverride ?? device }

    var body: some View {
        BentoCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    DeviceAvatarBadge(device: device, size: 56)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(device.displayName)
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .lineLimit(1)
                            Button(action: onEditName) {
                                Image(systemName: "pencil.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                        }

                        if let sub = device.secondaryName {
                            Text("主机名：\(sub)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            PulseStatusDot(isOnline: device.isOnline, isActive: device.isActive, size: 8)
                            Text(device.isActive ? "正在活跃" : (device.isOnline ? "在线空闲" : "当前离线"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(device.isActive ? OAFTheme.activeEmerald : (device.isOnline ? OAFTheme.onlineBlue : .secondary))

                            if !merged.band.isEmpty && device.isOnline {
                                Text("· \(merged.band)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if device.rssi != 0 && device.isOnline {
                                Text("· \(device.rssi) dBm")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }

                // IP & MAC pills
                HStack(spacing: 8) {
                    InfoCopyChip(icon: "network", text: merged.ip.isEmpty ? device.ip : merged.ip)
                    InfoCopyChip(icon: "number", text: device.normalizedMAC)
                }

                // Current Active App Highlight
                if device.isActive && !device.currentApp.isEmpty {
                    HStack(spacing: 10) {
                        AppIconBadge(
                            appId: device.currentAppId,
                            appName: device.currentApp,
                            allowRemoteIcon: allowRemoteIcon,
                            allowInsecureTLS: allowInsecureTLS,
                            size: 28
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前正在访问：\(device.currentApp)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if !device.currentURL.isEmpty {
                                Text(device.currentURL)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if device.downRate > 0 {
                            Text("↓ \(Formatters.rate(device.downRate))")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(OAFTheme.activeEmerald)
                        }
                    }
                    .padding(12)
                    .background(OAFTheme.activeEmerald.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

private struct InfoCopyChip: View {
    let icon: String
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation { copied = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(copied ? OAFTheme.activeEmerald : .secondary)
                Text(text)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 4-Card KPI Bento Grid

private struct KPIGridSection: View {
    let device: OAFDevice

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            KPIMiniTile(
                icon: "flame.fill",
                iconColor: OAFTheme.primaryIndigo,
                title: "今日活跃时长",
                value: Formatters.duration(device.todayActiveTime)
            )
            KPIMiniTile(
                icon: "wifi",
                iconColor: OAFTheme.onlineBlue,
                title: "今日在线时长",
                value: Formatters.duration(device.todayOnlineTime)
            )
            KPIMiniTile(
                icon: "arrow.down.circle.fill",
                iconColor: OAFTheme.activeEmerald,
                title: "今日下载流量",
                value: Formatters.bytes(device.todayDownBytes)
            )
            KPIMiniTile(
                icon: "arrow.up.circle.fill",
                iconColor: OAFTheme.electricCyan,
                title: "今日上传流量",
                value: Formatters.bytes(device.todayUpBytes)
            )
        }
    }
}

private struct KPIMiniTile: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String

    var body: some View {
        BentoCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(value)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

// MARK: - Custom Segmented Tab Bar

private struct SegmentedTabPill: View {
    @Binding var selection: DetailSegment

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DetailSegment.allCases) { tab in
                let active = selection == tab
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(active ? .white : .secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(active ? AnyShapeStyle(OAFTheme.primaryIndigo) : AnyShapeStyle(Color.clear))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

// MARK: - Segment 1: App Statistics (Donut + Ranked Bars + 24h Chart + Categories)

private struct AppStatsSection: View {
    let durations: [OAFAppDuration]
    let categories: [OAFCategoryDuration]
    let hourlyStats: [OAFHourlyStat]
    @Binding var selectedSliceId: String?
    @Binding var selectedHour: Int?
    @Binding var hourlyMetricIsTraffic: Bool
    let allowRemoteIcon: Bool
    let allowInsecureTLS: Bool

    private var totalAppSeconds: Int {
        max(1, durations.reduce(0) { $0 + $1.seconds })
    }

    private var donutSlices: [DonutSlice] {
        let top = Array(durations.prefix(6))
        var result = top.enumerated().map { idx, item in
            DonutSlice(
                id: item.id,
                title: item.name,
                seconds: item.seconds,
                color: OAFTheme.color(at: idx)
            )
        }
        let restSeconds = durations.dropFirst(6).reduce(0) { $0 + $1.seconds }
        if restSeconds > 0 {
            result.append(DonutSlice(id: "other", title: "其他应用", seconds: restSeconds, color: .gray.opacity(0.45)))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 16) {
            // Card 1: Top Apps Donut & Progress List
            BentoCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label("常用应用时长排行", systemImage: "chart.pie.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("共 \(durations.count) 款应用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if durations.isEmpty {
                        EmptyStateView(
                            icon: "hourglass",
                            title: "今日暂无应用时长统计",
                            subtitle: "当该手机产生联网应用流量后，OAF 会自动统计各 App 使用时长"
                        )
                    } else {
                        HStack {
                            Spacer()
                            DonutRingChart(slices: donutSlices, selectedSliceId: $selectedSliceId)
                            Spacer()
                        }
                        .padding(.vertical, 4)

                        VStack(spacing: 13) {
                            ForEach(Array(durations.prefix(12).enumerated()), id: \.element.id) { idx, item in
                                let pct = Double(item.seconds) / Double(totalAppSeconds)
                                let barColor = idx < 6 ? OAFTheme.color(at: idx) : Color.secondary
                                let isHighlighted = selectedSliceId == nil || selectedSliceId == item.id

                                VStack(spacing: 6) {
                                    HStack(spacing: 10) {
                                        AppIconBadge(
                                            appId: item.appId,
                                            appName: item.name,
                                            allowRemoteIcon: allowRemoteIcon,
                                            allowInsecureTLS: allowInsecureTLS,
                                            size: 28
                                        )
                                        Text(item.name)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(Formatters.duration(item.seconds))
                                            .font(.subheadline.monospacedDigit().weight(.semibold))
                                        Text(String(format: "%.0f%%", pct * 100))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 34, alignment: .trailing)
                                    }

                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule()
                                                .fill(Color.primary.opacity(0.06))
                                                .frame(height: 6)
                                            Capsule()
                                                .fill(barColor)
                                                .frame(width: max(6, geo.size.width * pct), height: 6)
                                        }
                                    }
                                    .frame(height: 6)
                                }
                                .opacity(isHighlighted ? 1.0 : 0.4)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                        selectedSliceId = (selectedSliceId == item.id) ? nil : item.id
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Card 2: 24-Hour Interactive Activity & Traffic Chart
            if !hourlyStats.isEmpty {
                BentoCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("24 小时分段统计", systemImage: "clock.badge.checkmark.fill")
                                .font(.subheadline.weight(.bold))
                            Spacer()
                            Picker("指标", selection: $hourlyMetricIsTraffic) {
                                Text("活跃时长").tag(false)
                                Text("上下行流量").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 152)
                        }

                        Chart {
                            ForEach(hourlyStats) { item in
                                let yVal: Double = hourlyMetricIsTraffic
                                    ? Double(item.totalBytes) / 1_048_576.0
                                    : Double(item.totalAppSeconds) / 60.0

                                BarMark(
                                    x: .value("小时", item.hour),
                                    y: .value(hourlyMetricIsTraffic ? "MB" : "分钟", yVal)
                                )
                                .foregroundStyle(
                                    selectedHour == item.hour
                                        ? AnyShapeStyle(OAFTheme.amberAccent)
                                        : AnyShapeStyle(OAFTheme.heroGradient)
                                )
                                .cornerRadius(4)
                            }
                        }
                        .frame(height: 175)
                        .chartXScale(domain: 0...23)
                        .chartXAxis {
                            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                                AxisValueLabel {
                                    if let h = value.as(Int.self) {
                                        Text("\(h)时").font(.caption2)
                                    }
                                }
                            }
                        }
                        .chartOverlay { proxy in
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        SpatialTapGesture()
                                            .onEnded { value in
                                                let x = value.location.x - geo[proxy.plotAreaFrame].origin.x
                                                if let tappedHour: Int = proxy.value(atX: x),
                                                   (0...23).contains(tappedHour) {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        selectedHour = tappedHour
                                                    }
                                                }
                                            }
                                    )
                            }
                        }

                        if let h = selectedHour,
                           let stat = hourlyStats.first(where: { $0.hour == h }) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(String(format: "%02d:00 - %02d:59 明细", h, h))
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(OAFTheme.primaryIndigo)
                                    Spacer()
                                    Text("流量 \(Formatters.bytes(stat.totalBytes))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }

                                if stat.apps.isEmpty {
                                    Text("该时段无记录的应用活跃")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(stat.apps.sorted(by: { $0.seconds > $1.seconds })) { app in
                                                HStack(spacing: 5) {
                                                    AppIconBadge(
                                                        appId: app.appId,
                                                        appName: app.name,
                                                        allowRemoteIcon: allowRemoteIcon,
                                                        allowInsecureTLS: allowInsecureTLS,
                                                        size: 18
                                                    )
                                                    Text(app.name)
                                                        .font(.caption.weight(.medium))
                                                    Text(Formatters.duration(app.seconds, compact: true))
                                                        .font(.caption2.monospacedDigit())
                                                        .foregroundStyle(.secondary)
                                                }
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 5)
                                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else {
                            Text("轻触柱状图任意小时可查看该时段具体使用的 App")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // Card 3: App Category Breakdown
            if !categories.isEmpty {
                let catTotal = max(1, categories.reduce(0) { $0 + $1.seconds })
                BentoCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("应用类型分布", systemImage: "square.grid.2x2.fill")
                            .font(.subheadline.weight(.bold))

                        ForEach(Array(categories.enumerated()), id: \.element.id) { idx, cat in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(OAFTheme.color(at: idx + 2))
                                    .frame(width: 9, height: 9)
                                Text(cat.name)
                                    .font(.subheadline)
                                Spacer()
                                Text(Formatters.duration(cat.seconds))
                                    .font(.subheadline.monospacedDigit().weight(.medium))
                                Text(String(format: "%.0f%%", Double(cat.seconds) / Double(catTotal) * 100))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Segment 2: Chronological App Visit Stream

private struct VisitTimelineSection: View {
    let records: [OAFVisitRecord]
    let currentPage: Int
    let totalPages: Int
    let isLoadingMore: Bool
    let allowRemoteIcon: Bool
    let allowInsecureTLS: Bool
    let onLoadMore: () -> Void

    var body: some View {
        BentoCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("应用访问流水", systemImage: "list.bullet.rectangle.portrait.fill")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text("按最近活跃排序")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if records.isEmpty {
                    EmptyStateView(
                        icon: "tray",
                        title: "暂无访问流水",
                        subtitle: "该终端今日还没有捕获到具体的应用访问记录"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { idx, rec in
                            HStack(spacing: 12) {
                                AppIconBadge(
                                    appId: rec.appId,
                                    appName: rec.appName,
                                    allowRemoteIcon: allowRemoteIcon,
                                    allowInsecureTLS: allowInsecureTLS,
                                    size: 36
                                )

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(rec.appName)
                                            .font(.subheadline.weight(.semibold))
                                        if rec.isOnline {
                                            Text("活跃")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1.5)
                                                .background(OAFTheme.activeEmerald.opacity(0.14), in: Capsule())
                                                .foregroundStyle(OAFTheme.activeEmerald)
                                        }
                                        if rec.isFiltered {
                                            Text("已阻断")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1.5)
                                                .background(OAFTheme.coralRose.opacity(0.14), in: Capsule())
                                                .foregroundStyle(OAFTheme.coralRose)
                                        }
                                    }

                                    Text("首次 \(Formatters.timestamp(rec.firstTime)) · 最近 \(Formatters.relativeShort(rec.latestTime))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(rec.isFiltered ? "--" : Formatters.duration(rec.durationSeconds, compact: true))
                                        .font(.subheadline.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("持续时长")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 11)

                            if idx < records.count - 1 {
                                Divider().padding(.leading, 48)
                            }
                        }
                    }

                    if currentPage < totalPages {
                        Button(action: onLoadMore) {
                            HStack(spacing: 6) {
                                if isLoadingMore {
                                    ProgressView()
                                }
                                Text(isLoadingMore ? "加载中..." : "加载更多记录 (\(currentPage)/\(totalPages))")
                                    .font(.footnote.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(isLoadingMore)
                    }
                }
            }
        }
    }
}

// MARK: - Segment 3: Online / Offline Event Timeline

private struct OnlineOfflineTimelineSection: View {
    let events: [OAFOnlineOfflineEvent]

    var body: some View {
        BentoCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("上下线历史时间轴", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.bold))

                if events.isEmpty {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "暂无上下线记录",
                        subtitle: "设备发生连接或断开事件后会自动记录在此处"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { idx, ev in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 0) {
                                    Circle()
                                        .fill(ev.isOnlineEvent ? OAFTheme.activeEmerald : OAFTheme.coralRose)
                                        .frame(width: 10, height: 10)
                                        .padding(.top, 5)
                                    if idx < events.count - 1 {
                                        Rectangle()
                                            .fill(Color.primary.opacity(0.10))
                                            .frame(width: 1.5)
                                            .frame(minHeight: 34)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(ev.isOnlineEvent ? "连接上线" : "断开离线")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(ev.isOnlineEvent ? OAFTheme.activeEmerald : OAFTheme.coralRose)
                                        Spacer()
                                        Text(ev.timeStr.isEmpty ? Formatters.timestamp(ev.timestamp) : ev.timeStr)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }

                                    if !ev.isOnlineEvent && (ev.durationSeconds > 0 || !ev.durationStr.isEmpty) {
                                        Text("本次持续在线：\(ev.durationStr.isEmpty ? Formatters.duration(ev.durationSeconds) : ev.durationStr)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.bottom, idx < events.count - 1 ? 14 : 2)
                            }
                        }
                    }
                }
            }
        }
    }
}
