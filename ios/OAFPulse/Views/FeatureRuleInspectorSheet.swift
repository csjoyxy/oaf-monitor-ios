import SwiftUI

struct InspectedAppTarget: Identifiable, Equatable {
    let appId: Int
    let appName: String
    var id: String { "\(appId)-\(appName)" }
}

struct FeatureRuleInspectorSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let target: InspectedAppTarget
    var onActionCompleted: (() -> Void)?

    @State private var info: OAFFeatureRuleInfo?
    @State private var isLoading: Bool = true
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header App Summary
                    BentoCard(padding: 18) {
                        HStack(spacing: 14) {
                            AppIconBadge(
                                appId: target.appId,
                                appName: target.appName,
                                allowRemoteIcon: !store.isDemoMode,
                                allowInsecureTLS: store.profile.allowInsecureTLS,
                                size: 52
                            )
                            VStack(alignment: .leading, spacing: 5) {
                                Text(target.appName)
                                    .font(.title3.weight(.bold))
                                HStack(spacing: 8) {
                                    if target.appId > 0 {
                                        Text("App ID: \(target.appId)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    if let ver = info?.version, !ver.isEmpty {
                                        Text("特征库 \(ver)")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(OAFTheme.primaryIndigo.opacity(0.12), in: Capsule())
                                            .foregroundStyle(OAFTheme.primaryIndigo)
                                    }
                                }
                            }
                            Spacer()
                        }
                    }

                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在解密读取路由器特征库规则...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else if let errorMessage {
                        BentoCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("读取特征库规则提示", systemImage: "info.circle.fill")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(OAFTheme.amberAccent)
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("提示：即使尚未更新路由器特征工具，你依然可以直接点击下方「仅在 App 与 Bark 中隐藏」立即屏蔽此误报应用。")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else if let info {
                        // Risk Diagnosis Card
                        BentoCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("误报原因诊断", systemImage: "stethoscope")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(OAFTheme.amberAccent)
                                Text(info.riskHint)
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                                    .lineSpacing(3)
                            }
                        }

                        // Raw DPI Signature Card
                        BentoCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label("路由器底层 DPI 特征规则", systemImage: "chevron.left.forwardslash.chevron.right")
                                        .font(.subheadline.weight(.bold))
                                    Spacer()
                                    if info.found && !info.rawRule.isEmpty {
                                        Button {
                                            UIPasteboard.general.string = info.rawRule
                                            store.showToast("已复制原始特征规则")
                                        } label: {
                                            Label("复制", systemImage: "doc.on.doc")
                                                .font(.caption.weight(.semibold))
                                        }
                                    }
                                }

                                if info.found && !info.rawRule.isEmpty {
                                    Text(info.rawRule)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                                    Text("语法格式：AppID~名称:[协议;源端口;目的端口;域名关键词;请求路径;字节偏移匹配]")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text("当前 /etc/fwxd/feature.bin 中未找到该条独立规则（可能属于自定义特征库或内置映射）。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Action Buttons
                    VStack(spacing: 12) {
                        Button {
                            Task {
                                isProcessing = true
                                await store.setAppSoftIgnored(appId: target.appId, appName: target.appName, ignore: true)
                                isProcessing = false
                                onActionCompleted?()
                                dismiss()
                            }
                        } label: {
                            VStack(spacing: 3) {
                                Label("仅在 App 与 Bark 通知中隐藏（软屏蔽）", systemImage: "eye.slash.fill")
                                    .font(.subheadline.weight(.semibold))
                                Text("不修改路由器特征库文件，立即从统计图表与离线总结中剔除")
                                    .font(.caption2)
                                    .opacity(0.85)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .foregroundStyle(.white)
                            .background(OAFTheme.primaryIndigo, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .disabled(isProcessing)

                        if info?.found != false {
                            Button {
                                Task {
                                    isProcessing = true
                                    let ok = await store.setRouterFeatureRuleDisabled(
                                        appId: target.appId,
                                        appName: target.appName,
                                        disable: true
                                    )
                                    isProcessing = false
                                    if ok {
                                        onActionCompleted?()
                                        dismiss()
                                    }
                                }
                            } label: {
                                VStack(spacing: 3) {
                                    HStack(spacing: 6) {
                                        if isProcessing {
                                            ProgressView().tint(OAFTheme.coralRose)
                                        } else {
                                            Image(systemName: "scissors")
                                        }
                                        Text("从路由器特征库彻底禁用该规则（硬根治）")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    Text("自动备份原厂特征库 · 热重载内核不再比对此规则 · 路由器后台同步清净")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .foregroundStyle(OAFTheme.coralRose)
                                .background(OAFTheme.coralRose.opacity(0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .disabled(isProcessing)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("误报诊断与处理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                isLoading = true
                do {
                    info = try await store.inspectAppFeature(appId: target.appId, appName: target.appName)
                } catch {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }
    }
}
