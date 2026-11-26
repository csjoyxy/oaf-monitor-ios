import SwiftUI

struct BarkSettingsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var draft = BarkAgentConfig()
    @State private var isSavingBark = false
    @State private var isSendingTest = false
    @State private var showCustomServer = false

    private let installOneLiner = "sh -c \"$(wget -qO- https://raw.githubusercontent.com/csjoyxy/oaf-monitor-ios/main/router-agent/install.sh)\""

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // Section 1: Router Bark Notification Control Center
                if store.isBarkAgentInstalled {
                    BarkConfiguredPanel(
                        draft: $draft,
                        showCustomServer: $showCustomServer,
                        isSaving: isSavingBark,
                        isTesting: isSendingTest,
                        devices: store.devices,
                        onSave: {
                            Task {
                                isSavingBark = true
                                _ = await store.saveBarkConfiguration(draft)
                                isSavingBark = false
                            }
                        },
                        onTestPush: {
                            Task {
                                isSendingTest = true
                                await store.triggerBarkTest(server: draft.barkServer, key: draft.barkKey)
                                isSendingTest = false
                            }
                        }
                    )
                } else {
                    BarkInstallerGuideCard(installCommand: installOneLiner) {
                        UIPasteboard.general.string = installOneLiner
                        store.showToast("已复制路由器一键安装命令")
                    } onRecheck: {
                        Task { await store.refreshAll(showSpinner: true) }
                    }
                }

                // Section 2: Recent Bark Events from Router RAM
                if store.isBarkAgentInstalled && !store.barkConfig.recentEvents.isEmpty {
                    BentoCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("最近上下线触发日志", systemImage: "bell.and.waves.left.and.right.fill")
                                .font(.subheadline.weight(.bold))

                            ForEach(store.barkConfig.recentEvents.prefix(10)) { ev in
                                HStack(alignment: .top, spacing: 10) {
                                    Circle()
                                        .fill(ev.isOnline ? OAFTheme.activeEmerald : OAFTheme.coralRose)
                                        .frame(width: 8, height: 8)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text("\(ev.name) \(ev.isOnline ? "上线" : "离线")")
                                                .font(.subheadline.weight(.semibold))
                                            if ev.pushed {
                                                Text("已推 Bark")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1.5)
                                                    .background(OAFTheme.primaryIndigo.opacity(0.12), in: Capsule())
                                                    .foregroundStyle(OAFTheme.primaryIndigo)
                                            }
                                            Spacer()
                                            Text(Formatters.timestamp(ev.timestamp))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        if !ev.detail.isEmpty {
                                            Text(ev.detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Section 3: Router Connection & Auto-Refresh Preferences
                BentoCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("路由器连接与刷新", systemImage: "wifi.router.fill")
                            .font(.subheadline.weight(.bold))

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.isDemoMode ? "当前处于演示预览模式" : (store.profile.lanURL.isEmpty ? store.profile.wanURL : store.profile.lanURL))
                                    .font(.subheadline.weight(.medium))
                                Text("状态：\(store.routeStatus.badgeText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                store.showSetupSheet = true
                            } label: {
                                Text(store.isDemoMode ? "连接路由器" : "编辑连接")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(OAFTheme.primaryIndigo.opacity(0.13), in: Capsule())
                                    .foregroundStyle(OAFTheme.primaryIndigo)
                            }
                        }

                        Divider()

                        HStack {
                            Text("前台自动刷新频率")
                                .font(.subheadline)
                            Spacer()
                            Picker("自动刷新", selection: Binding(
                                get: { store.profile.autoRefreshSeconds },
                                set: { store.updateAutoRefreshSeconds($0) }
                            )) {
                                Text("仅手动").tag(0)
                                Text("5 秒").tag(5)
                                Text("10 秒").tag(10)
                                Text("30 秒").tag(30)
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("提醒与设置")
        .onAppear {
            draft = store.barkConfig
            showCustomServer = (draft.barkServer != "https://api.day.app" && !draft.barkServer.isEmpty)
        }
        .onChange(of: store.barkConfig) { updated in
            draft = updated
        }
    }
}

// MARK: - Bark Agent One-Line Installer Guide Card

private struct BarkInstallerGuideCard: View {
    let installCommand: String
    let onCopy: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        BentoCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(OAFTheme.amberAccent.opacity(0.16))
                            .frame(width: 40, height: 40)
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(OAFTheme.amberAccent)
                            .font(.headline)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用上下线 Bark 提醒")
                            .font(.headline)
                        Text("超轻量纯 Lua 脚本 · CPU < 0.01% · 0 闪存写入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("只需 SSH 登录一次路由器执行以下一行命令即可完成部署，之后所有 Bark Key、关注手机勾选、防抖时间均可直接在本页面可视化管理：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)

                Text(installCommand)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 10) {
                    Button(action: onCopy) {
                        Label("复制安装命令", systemImage: "doc.on.doc.fill")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .foregroundStyle(.white)
                            .background(OAFTheme.primaryIndigo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Button(action: onRecheck) {
                        Label("我已安装，重新检测", systemImage: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .foregroundStyle(OAFTheme.primaryIndigo)
                            .background(OAFTheme.primaryIndigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }
}

// MARK: - Full Bark Visual Configurator

private struct BarkConfiguredPanel: View {
    @Binding var draft: BarkAgentConfig
    @Binding var showCustomServer: Bool
    let isSaving: Bool
    let isTesting: Bool
    let devices: [OAFDevice]
    let onSave: () -> Void
    let onTestPush: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            BentoCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Bark 上下线实时通知", systemImage: "bell.badge.fill")
                            .font(.subheadline.weight(.bold))
                        Spacer()
                        HStack(spacing: 5) {
                            Circle()
                                .fill(draft.daemonRunning ? OAFTheme.activeEmerald : Color.secondary)
                                .frame(width: 7, height: 7)
                            Text(draft.daemonRunning ? "守护运行中" : "已停止")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("开启上下线通知推送", isOn: $draft.enabled)
                        .tint(OAFTheme.primaryIndigo)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Bark Device Key（官方 api.day.app）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(showCustomServer ? "使用官方默认地址" : "自建服务器?") {
                                withAnimation {
                                    showCustomServer.toggle()
                                    if !showCustomServer {
                                        draft.barkServer = "https://api.day.app"
                                    }
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(OAFTheme.primaryIndigo)
                        }

                        TextField("粘贴 Bark App 中的 Key（如 aBcDeFgHiJkL）", text: $draft.barkKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline.monospaced())
                            .padding(11)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if showCustomServer {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Bark 服务器地址")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("https://api.day.app", text: $draft.barkServer)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.subheadline)
                                .padding(11)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    Divider()

                    Toggle("手机连接 Wi-Fi 上线提醒", isOn: $draft.notifyOnline)
                        .font(.subheadline)
                        .tint(OAFTheme.primaryIndigo)

                    Toggle("手机断开 Wi-Fi 离线提醒", isOn: $draft.notifyOffline)
                        .font(.subheadline)
                        .tint(OAFTheme.primaryIndigo)

                    Toggle(isOn: $draft.includeSummary) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("离线通知附带今日常用 App 摘要")
                                .font(.subheadline)
                            Text("例如：本次在线 1h20m · 常用：抖音(42m)、微信(18m)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(OAFTheme.primaryIndigo)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("离线防抖等待时间")
                                .font(.subheadline)
                            Text("过滤 iPhone 锁屏省电短暂断连误报")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("离线防抖", selection: $draft.offlineDebounce) {
                            Text("30 秒").tag(30)
                            Text("60 秒").tag(60)
                            Text("90 秒 (推荐)").tag(90)
                            Text("120 秒").tag(120)
                            Text("180 秒").tag(180)
                        }
                        .pickerStyle(.menu)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("路由器轮询间隔")
                                .font(.subheadline)
                            Text("间隔越长对低配路由器越省资源")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("轮询间隔", selection: $draft.pollInterval) {
                            Text("10 秒").tag(10)
                            Text("15 秒 (推荐)").tag(15)
                            Text("30 秒").tag(30)
                            Text("60 秒").tag(60)
                        }
                        .pickerStyle(.menu)
                    }

                    Toggle(isOn: $draft.quietEnable) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("夜间免打扰（\(draft.quietStart) - \(draft.quietEnd)）")
                                .font(.subheadline)
                            Text("深夜时段只记录日志、不发 Bark 响铃")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(OAFTheme.primaryIndigo)

                    HStack(spacing: 10) {
                        Button(action: onSave) {
                            HStack(spacing: 6) {
                                if isSaving { ProgressView().tint(.white) }
                                Text(isSaving ? "保存中..." : "保存配置到路由器")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background(OAFTheme.heroGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(isSaving)

                        Button(action: onTestPush) {
                            HStack(spacing: 5) {
                                if isTesting {
                                    ProgressView()
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                                Text("测试推送")
                                    .fontWeight(.semibold)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .foregroundStyle(OAFTheme.primaryIndigo)
                            .background(OAFTheme.primaryIndigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(isTesting)
                    }
                }
            }

            // Watch Mode & Device Checklist Card
            BentoCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("监控设备范围", systemImage: "checklist")
                            .font(.subheadline.weight(.bold))
                        Spacer()
                        Picker("范围", selection: $draft.watchMode) {
                            Text("仅勾选设备").tag("selected")
                            Text("全部设备").tag("all")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 168)
                    }

                    if draft.watchMode == "all" {
                        Text("当前将推送局域网内所有设备的上下线通知（若智能家居设备较多，建议切换为「仅勾选设备」只关注家人的手机）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if devices.isEmpty {
                        Text("连接路由器刷新终端列表后，可在此快速勾选需要关注上下线的手机。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(devices) { dev in
                            let isChecked = draft.watchedMACs.contains(dev.normalizedMAC)
                            Button {
                                if let i = draft.watchedMACs.firstIndex(of: dev.normalizedMAC) {
                                    draft.watchedMACs.remove(at: i)
                                } else {
                                    draft.watchedMACs.append(dev.normalizedMAC)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isChecked ? OAFTheme.primaryIndigo : .secondary)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dev.displayName)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("\(dev.ip) · \(dev.normalizedMAC)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if dev.isOnline {
                                        Text("在线")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(OAFTheme.activeEmerald)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("提示：勾选后别忘了点击上方「保存配置到路由器」，或在终端详情页右上角一键点亮铃铛。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
