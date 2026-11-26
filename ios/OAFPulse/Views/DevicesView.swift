import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var renamingDevice: OAFDevice?
    @State private var newNicknameText: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HeroSummaryBanner()

                if let err = store.lastError, !store.isDemoMode {
                    ConnectionWarningCard(message: err) {
                        store.showSetupSheet = true
                    }
                }

                FilterAndSortStrip()

                let list = store.filteredDevices
                if store.isLoadingDevices && store.devices.isEmpty {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在同步路由器终端统计...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else if list.isEmpty {
                    BentoCard {
                        EmptyStateView(
                            icon: "iphone.slash",
                            title: store.devices.isEmpty ? "暂无终端数据" : "没有符合筛选条件的设备",
                            subtitle: store.devices.isEmpty ? "下拉刷新或检查路由器 OAF 7.0 服务是否正在运行" : "可尝试切换上方筛选标签或清空搜索词"
                        )
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(list) { device in
                            NavigationLink(value: device) {
                                DeviceRowCard(
                                    device: device,
                                    isWatched: store.isWatching(device),
                                    allowRemoteIcon: !store.isDemoMode,
                                    allowInsecureTLS: store.profile.allowInsecureTLS
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    Task { await store.toggleDeviceWatch(device) }
                                } label: {
                                    Label(
                                        store.isWatching(device) ? "关闭上下线 Bark 提醒" : "开启上下线 Bark 提醒",
                                        systemImage: store.isWatching(device) ? "bell.slash.fill" : "bell.badge.fill"
                                    )
                                }

                                Button {
                                    newNicknameText = device.nickname.isEmpty ? device.displayName : device.nickname
                                    renamingDevice = device
                                } label: {
                                    Label("修改设备备注名", systemImage: "pencil")
                                }

                                Button {
                                    UIPasteboard.general.string = device.ip
                                    store.showToast("已复制 IP：\(device.ip)")
                                } label: {
                                    Label("复制 IP 地址", systemImage: "doc.on.doc")
                                }

                                Button {
                                    UIPasteboard.general.string = device.normalizedMAC
                                    store.showToast("已复制 MAC：\(device.normalizedMAC)")
                                } label: {
                                    Label("复制 MAC 地址", systemImage: "number")
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
        .navigationTitle("OAF Pulse")
        .searchable(text: $store.searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索手机备注、主机名、IP 或正在用的 App")
        .refreshable {
            await store.refreshAll(showSpinner: false)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                RouteBadgeButton()
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("排序方式", selection: $store.sortOption) {
                        ForEach(DeviceSortOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    Divider()
                    Button {
                        Task { await store.refreshAll(showSpinner: true) }
                    } label: {
                        Label("立即刷新", systemImage: "arrow.clockwise")
                    }
                    Button {
                        store.showSetupSheet = true
                    } label: {
                        Label("切换路由器连接", systemImage: "server.rack")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.body.weight(.medium))
                }
            }
        }
        .alert(
            "修改设备备注名",
            isPresented: Binding(
                get: { renamingDevice != nil },
                set: { if !$0 { renamingDevice = nil } }
            )
        ) {
            TextField("例如：老婆的 iPhone", text: $newNicknameText)
            Button("取消", role: .cancel) { renamingDevice = nil }
            Button("保存") {
                if let target = renamingDevice {
                    Task { await store.renameDevice(target, nickname: newNicknameText) }
                }
                renamingDevice = nil
            }
        } message: {
            if let dev = renamingDevice {
                Text("\(dev.hostname.isEmpty ? dev.normalizedMAC : dev.hostname) (\(dev.ip))")
            }
        }
    }
}

// MARK: - Top Route Status Pill

private struct RouteBadgeButton: View {
    @EnvironmentObject private var store: AppStore

    private var dotColor: Color {
        switch store.routeStatus {
        case .lan: return OAFTheme.activeEmerald
        case .wan: return OAFTheme.onlineBlue
        case .demo: return OAFTheme.amberAccent
        case .disconnected: return OAFTheme.coralRose
        }
    }

    var body: some View {
        Button {
            store.showSetupSheet = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(store.routeStatus.badgeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hero Summary Bento Banner

private struct HeroSummaryBanner: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("家庭终端概览")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(store.onlineCount)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("台在线 / 共 \(store.devices.count) 台")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("实时总下行")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.78))
                    Text("↓ \(Formatters.rate(store.liveTotalDownRate))")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.18), in: Capsule())
                        .foregroundStyle(.white)
                }
            }

            HStack(spacing: 10) {
                HeroMiniStatPill(
                    icon: "flame.fill",
                    label: "正在刷应用",
                    value: "\(store.activeCount) 台"
                )
                HeroMiniStatPill(
                    icon: "arrow.up.arrow.down",
                    label: "今日总流量",
                    value: Formatters.bytes(store.todayTotalBytes)
                )
                HeroMiniStatPill(
                    icon: "bell.fill",
                    label: "Bark 提醒",
                    value: store.isBarkAgentInstalled && store.barkConfig.enabled ? "已开启" : "未开启"
                )
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(OAFTheme.heroGradient)
        )
    }
}

private struct HeroMiniStatPill: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.8))

            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Filter Chips & Sort Indicator

private struct FilterAndSortStrip: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DeviceFilterOption.allCases) { opt in
                    let selected = store.filterOption == opt
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            store.filterOption = opt
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if opt == .active {
                                Circle().fill(selected ? .white : OAFTheme.activeEmerald).frame(width: 6, height: 6)
                            } else if opt == .watched {
                                Image(systemName: "bell.fill")
                                    .font(.system(size: 10))
                            }
                            Text(opt.rawValue)
                                .font(.footnote.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(selected ? .white : .primary)
                        .background(
                            Capsule()
                                .fill(selected ? AnyShapeStyle(OAFTheme.primaryIndigo) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(selected ? 0 : 0.07), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Connection Warning Card

private struct ConnectionWarningCard: View {
    let message: String
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3)
                .foregroundStyle(OAFTheme.coralRose)
            VStack(alignment: .leading, spacing: 3) {
                Text("连接异常")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("设置", action: onAction)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(OAFTheme.coralRose.opacity(0.14), in: Capsule())
                .foregroundStyle(OAFTheme.coralRose)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(OAFTheme.coralRose.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - Modern Device Row Card

struct DeviceRowCard: View {
    let device: OAFDevice
    let isWatched: Bool
    let allowRemoteIcon: Bool
    let allowInsecureTLS: Bool

    var body: some View {
        BentoCard(padding: 15) {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 13) {
                    DeviceAvatarBadge(device: device, size: 48)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(device.displayName)
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundStyle(device.isOnline ? .primary : .secondary)
                                .lineLimit(1)

                            if isWatched {
                                Image(systemName: "bell.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(OAFTheme.amberAccent)
                            }

                            if !device.band.isEmpty && device.isOnline {
                                Text(device.band)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(OAFTheme.onlineBlue.opacity(0.12), in: Capsule())
                                    .foregroundStyle(OAFTheme.onlineBlue)
                            }
                        }

                        HStack(spacing: 8) {
                            Text(device.ip != "--" && !device.ip.isEmpty ? device.ip : device.normalizedMAC)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)

                            if device.isActive && !device.currentApp.isEmpty {
                                HStack(spacing: 5) {
                                    AppIconBadge(
                                        appId: device.currentAppId,
                                        appName: device.currentApp,
                                        allowRemoteIcon: allowRemoteIcon,
                                        allowInsecureTLS: allowInsecureTLS,
                                        size: 16
                                    )
                                    Text(device.currentApp)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(OAFTheme.activeEmerald)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(OAFTheme.activeEmerald.opacity(0.11), in: Capsule())
                            } else if !device.isOnline {
                                Text("离线")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("在线空闲")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(OAFTheme.onlineBlue.opacity(0.85))
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    // Right side: Recent App icon stack + chevron
                    HStack(spacing: 8) {
                        if !device.applist.isEmpty {
                            HStack(spacing: -5) {
                                ForEach(Array(device.applist.prefix(3))) { app in
                                    AppIconBadge(
                                        appId: app.appId,
                                        appName: app.name,
                                        allowRemoteIcon: allowRemoteIcon,
                                        allowInsecureTLS: allowInsecureTLS,
                                        size: 22
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                            .stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 1.5)
                                    )
                                }
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider().opacity(0.55)

                // Bottom Metrics Strip
                HStack(spacing: 12) {
                    Label {
                        Text("活跃 \(Formatters.duration(device.todayActiveTime, compact: true))")
                            .font(.caption.monospacedDigit().weight(.medium))
                    } icon: {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(OAFTheme.primaryIndigo)
                    }
                    .foregroundStyle(.secondary)

                    Label {
                        Text(Formatters.bytes(device.todayTotalBytes))
                            .font(.caption.monospacedDigit().weight(.medium))
                    } icon: {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(OAFTheme.electricCyan)
                    }
                    .foregroundStyle(.secondary)

                    Spacer()

                    if device.isOnline && (device.downRate > 0 || device.upRate > 0) {
                        HStack(spacing: 8) {
                            Text("↓ \(Formatters.rate(device.downRate))")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(OAFTheme.activeEmerald)
                            if device.upRate >= 1024 {
                                Text("↑ \(Formatters.rate(device.upRate))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(OAFTheme.onlineBlue)
                            }
                        }
                    } else if device.todayOnlineTime > 0 {
                        Text("在线 \(Formatters.duration(device.todayOnlineTime, compact: true))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
