import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $store.selectedTab) {
                NavigationStack(path: $store.navigationPath) {
                    DevicesView()
                        .navigationDestination(for: OAFDevice.self) { device in
                            DeviceDetailView(initialDevice: device)
                        }
                }
                .tabItem {
                    Label("终端统计", systemImage: "iphone.radiowaves.left.and.right")
                }
                .tag(0)

                NavigationStack {
                    LivePulseView()
                        .navigationDestination(for: OAFDevice.self) { device in
                            DeviceDetailView(initialDevice: device)
                        }
                }
                .tabItem {
                    Label("全网动态", systemImage: "waveform.path.ecg")
                }
                .tag(1)

                NavigationStack {
                    BarkSettingsView()
                }
                .tabItem {
                    Label("提醒与设置", systemImage: "bell.badge.fill")
                }
                .tag(2)
            }
            .tint(OAFTheme.primaryIndigo)

            if let toast = store.toast {
                ToastOverlayPill(toast: toast)
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(99)
            }
        }
        .sheet(isPresented: $store.showSetupSheet) {
            RouterOnboardingSheet()
                .environmentObject(store)
                .interactiveDismissDisabled(store.devices.isEmpty && !store.isDemoMode)
        }
    }
}

// MARK: - Top Floating Toast Banner

private struct ToastOverlayPill: View {
    let toast: ToastBanner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? OAFTheme.coralRose : OAFTheme.activeEmerald)
                .font(.subheadline.weight(.semibold))

            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    (toast.isError ? OAFTheme.coralRose : OAFTheme.primaryIndigo).opacity(0.22),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 6)
    }
}

// MARK: - Sleek Router Connection & Onboarding Sheet

struct RouterOnboardingSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var lanURL: String = "http://192.168.10.1"
    @State private var wanURL: String = ""
    @State private var username: String = "root"
    @State private var password: String = ""
    @State private var allowInsecureTLS: Bool = true
    @State private var isTesting: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Hero Header
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(OAFTheme.heroGradient)
                                .frame(width: 74, height: 74)
                                .shadow(color: OAFTheme.primaryIndigo.opacity(0.35), radius: 14, x: 0, y: 8)
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Text("连接 OpenWrt 路由器")
                            .font(.title3.weight(.bold))
                        Text("专为 OAF 7.0+ 打造 · 免后台重复登录 · 内外网自动切换")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 10)

                    BentoCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("连接地址", systemImage: "network")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(OAFTheme.primaryIndigo)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("局域网地址（必填或与外网二选一）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("例如 http://192.168.10.1", text: $lanURL)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(12)
                                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("外网 / DDNS 地址（选填，4G/5G 在外自动切换）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("例如 https://home.example.com:8443", text: $wanURL)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(12)
                                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            Toggle(isOn: $allowInsecureTLS) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("允许自签名 HTTPS 证书")
                                        .font(.subheadline)
                                    Text("OpenWrt 默认 HTTPS 证书建议保持开启")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tint(OAFTheme.primaryIndigo)
                        }
                    }

                    BentoCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("登录凭据（安全存储于系统钥匙串）", systemImage: "lock.shield.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(OAFTheme.primaryIndigo)

                            HStack(spacing: 12) {
                                Text("用户名")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .leading)
                                TextField("root", text: $username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(11)
                                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            HStack(spacing: 12) {
                                Text("密　码")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .leading)
                                SecureField("路由器后台密码", text: $password)
                                    .padding(11)
                                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundStyle(OAFTheme.coralRose)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(OAFTheme.coralRose)
                            Spacer()
                        }
                        .padding(12)
                        .background(OAFTheme.coralRose.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    VStack(spacing: 12) {
                        Button {
                            Task { await connectNow() }
                        } label: {
                            HStack(spacing: 8) {
                                if isTesting {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "bolt.horizontal.circle.fill")
                                }
                                Text(isTesting ? "正在验证连接..." : "连接并保存")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white)
                            .background(OAFTheme.heroGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .disabled(isTesting)

                        Button {
                            store.enterDemoMode()
                            dismiss()
                        } label: {
                            Text("先体验内置演示数据")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 6)
                        }
                    }
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !store.devices.isEmpty || store.isDemoMode {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
            }
            .onAppear {
                lanURL = store.profile.lanURL
                wanURL = store.profile.wanURL
                username = store.profile.username
                password = store.password
                allowInsecureTLS = store.profile.allowInsecureTLS
            }
        }
    }

    private func connectNow() async {
        errorMessage = nil
        isTesting = true
        var updated = store.profile
        updated.lanURL = lanURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.wanURL = wanURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.username = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "root" : username.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.allowInsecureTLS = allowInsecureTLS

        let ok = await store.saveConnectionAndConnect(newProfile: updated, newPassword: password)
        isTesting = false
        if ok {
            dismiss()
        } else {
            errorMessage = store.lastError ?? "连接失败，请检查 IP、端口与密码"
        }
    }
}
