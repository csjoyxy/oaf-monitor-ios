import SwiftUI
import Charts

struct LivePulseView: View {
    @EnvironmentObject private var store: AppStore
    @State private var inspectedApp: InspectedAppTarget?

    private var topDevicesByTime: [OAFDevice] {
        store.devices
            .map(store.sanitizedDevice)
            .filter { $0.todayActiveTime > 0 || $0.todayTotalBytes > 0 }
            .sorted { $0.todayActiveTime > $1.todayActiveTime }
    }

    var body: some View {
        let visibleRecords = store.filteredActiveRecords
        ScrollView {
            VStack(spacing: 16) {
                // Card 1: Real-time Active App Sessions Across All Phones
                BentoCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("全网实时正在访问的应用", systemImage: "bolt.horizontal.fill")
                                .font(.subheadline.weight(.bold))
                            Spacer()
                            Text("\(visibleRecords.count) 条活跃流")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if visibleRecords.isEmpty {
                            EmptyStateView(
                                icon: "sparkles",
                                title: "当前没有实时活跃应用会话",
                                subtitle: "家庭内任意手机打开视频、社交或游戏 App 时会实时出现在这里"
                            )
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(visibleRecords.prefix(25).enumerated()), id: \.element.id) { idx, rec in
                                    let rawDevice = store.devices.first(where: { $0.normalizedMAC == rec.mac })
                                        ?? OAFDevice(mac: rec.mac, ip: "--", hostname: rec.hostname, nickname: rec.nickname, online: 1)
                                    let matchedDevice = store.sanitizedDevice(rawDevice)

                                    NavigationLink(value: matchedDevice) {
                                        HStack(spacing: 12) {
                                            AppIconBadge(
                                                appId: rec.appId,
                                                appName: rec.appName,
                                                allowRemoteIcon: !store.isDemoMode,
                                                allowInsecureTLS: store.profile.allowInsecureTLS,
                                                size: 36
                                            )

                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(spacing: 6) {
                                                    Text(rec.appName)
                                                        .font(.subheadline.weight(.semibold))
                                                        .foregroundStyle(.primary)
                                                    Text("·")
                                                        .foregroundStyle(.tertiary)
                                                    Text(matchedDevice.displayName)
                                                        .font(.caption.weight(.medium))
                                                        .foregroundStyle(OAFTheme.primaryIndigo)
                                                        .lineLimit(1)
                                                }
                                                Text("最近活跃 \(Formatters.relativeShort(rec.latestTime)) · 持续 \(Formatters.duration(rec.durationSeconds, compact: true))")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            Image(systemName: "chevron.right")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            inspectedApp = InspectedAppTarget(appId: rec.appId, appName: rec.appName)
                                        } label: {
                                            Label("查看 OAF 特征规则与诊断", systemImage: "doc.text.magnifyingglass")
                                        }

                                        Button {
                                            Task {
                                                await store.setAppSoftIgnored(appId: rec.appId, appName: rec.appName, ignore: true)
                                            }
                                        } label: {
                                            Label("标记为误报并隐藏", systemImage: "eye.slash")
                                        }

                                        Button(role: .destructive) {
                                            Task {
                                                _ = await store.setRouterFeatureRuleDisabled(appId: rec.appId, appName: rec.appName, disable: true)
                                            }
                                        } label: {
                                            Label("从路由器特征库彻底禁用", systemImage: "scissors")
                                        }
                                    }

                                    if idx < min(25, visibleRecords.count) - 1 {
                                        Divider().padding(.leading, 48)
                                    }
                                }
                            }

                            Text("提示：长按任意疑似误报的应用（如后台串扰游戏），可查看底层 DPI 特征或一键屏蔽")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Card 2: Today's Device Screen-Time Ranking
                if !topDevicesByTime.isEmpty {
                    let maxSec = max(1, topDevicesByTime.first?.todayActiveTime ?? 1)
                    BentoCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("今日终端活跃时长榜", systemImage: "trophy.fill")
                                .font(.subheadline.weight(.bold))

                            ForEach(Array(topDevicesByTime.prefix(8).enumerated()), id: \.element.id) { idx, dev in
                                NavigationLink(value: dev) {
                                    VStack(spacing: 7) {
                                        HStack(spacing: 10) {
                                            Text("\(idx + 1)")
                                                .font(.caption.monospacedDigit().weight(.bold))
                                                .frame(width: 20, height: 20)
                                                .background(
                                                    Circle().fill(idx < 3 ? OAFTheme.color(at: idx).opacity(0.18) : Color.primary.opacity(0.06))
                                                )
                                                .foregroundStyle(idx < 3 ? OAFTheme.color(at: idx) : .secondary)

                                            Text(dev.displayName)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)

                                            Spacer()

                                            Text(Formatters.duration(dev.todayActiveTime))
                                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                                .foregroundStyle(.primary)

                                            Text(Formatters.bytes(dev.todayTotalBytes))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .frame(width: 64, alignment: .trailing)
                                        }

                                        SlimProgressBar(
                                            fraction: Double(dev.todayActiveTime) / Double(maxSec),
                                            color: OAFTheme.color(at: idx)
                                        )
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Card 3: 24-Hour Whole-Router Traffic Trend
                if !store.globalHourlyTraffic.isEmpty {
                    BentoCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("今日全网每小时流量趋势", systemImage: "chart.xyaxis.line")
                                .font(.subheadline.weight(.bold))

                            Chart {
                                ForEach(store.globalHourlyTraffic) { pt in
                                    let mb = Double(pt.totalBytes) / 1_048_576.0
                                    AreaMark(
                                        x: .value("小时", pt.hour),
                                        y: .value("MB", mb)
                                    )
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [OAFTheme.electricCyan.opacity(0.35), OAFTheme.primaryIndigo.opacity(0.03)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    LineMark(
                                        x: .value("小时", pt.hour),
                                        y: .value("MB", mb)
                                    )
                                    .foregroundStyle(OAFTheme.primaryIndigo)
                                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                                }
                            }
                            .frame(height: 170)
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
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("全网动态")
        .refreshable {
            await store.refreshAll(showSpinner: false)
        }
        .sheet(item: $inspectedApp) { target in
            FeatureRuleInspectorSheet(target: target)
        }
    }
}
