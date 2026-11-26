# OAF Pulse · OpenAppFilter (7.0+) 原生 iOS 统计查看器 & Bark 上下线提醒

专为 **OpenWrt + OpenAppFilter（OAF `7.0.x` 新版 `fwx` 接口）** 打造的**巨魔（TrollStore）原生 SwiftUI 客户端**与**超低负载路由器端上下线 Bark 推送脚本**。

无需每次手动登录路由器 LuCI 后台，点开桌面图标 0.5 秒直达每台手机的应用访问统计；支持在锁屏直接点击 Bark 上下线通知秒跳对应手机详情页。

---

## ✨ 核心特性

### 📱 iOS 原生查看端（`OAF Pulse`）
- **原生适配 OAF `7.0+` (`fwx.common`)**：解决官方 iOS 版 App 暂未适配 OAF `7.0.2` 提示「插件版本过高」且无法查看单机统计的问题。
- **完美支持 iOS 16.0+（含 iOS 16.4.1 巨魔 TrollStore）**：使用 `ldid` 预置权限打包 `.tipa` / `.ipa`，巨魔一键安装永久不掉签。
- **真正 0 登录感 & 内外网无感切换**：
  - 密码安全保存在 iOS 钥匙串（Keychain），`/ubus` 会话过期后台自动无感续期。
  - 同时支持填写 **局域网 IP** 与 **外网 DDNS/域名**（在家走内网毫秒响应，出门 `4G/5G` 自动切外网），原生支持放行 OpenWrt 自签名 HTTPS 证书。
- **纯粹现代的统计体验**：
  - **终端统计首页**：一眼查看每台手机「当前正在刷的 App + 实时上下行网速 + 今日活跃总时长 + 今日总流量」，支持按活跃/时长/流量/网速排序与筛选。
  - **单机深度详情**：交互式应用时长环形图、各 App 时长占比排行、**24 小时分段活跃/流量柱状图（点选任意小时可看该时段具体刷了哪些 App）**、应用访问流水（首次/最近访问时间、持续时长）、上下线历史时间轴、设备备注改名。
  - **全网实时动态**：查看全网正在发生的活跃 App 会话与全网 24 小时流量趋势。

### 🔔 路由器端极轻量 Bark 上下线守护（`router-agent/`）
专为**低配置路由器**设计，不增加路由器负担：
- **单 Lua 进程常驻内存**：直接通过进程内 `ubus` Unix Socket 读取 OAF 状态，**空闲时 0 子进程创建、不扫 ARP、0 闪存（Flash）写入**（运行状态全在 `/tmp` 内存盘），CPU 占用 **< 0.01%**、内存 **< 1 MB**。
- **防 iPhone 锁屏休眠误报**：内置离线防抖窗口（默认 `90 秒`，可在手机 App 内自由调节），过滤 iPhone 锁屏省电短暂断 Wi-Fi 导致的频繁上下线误报。
- **离线附带今日 OAF 摘要**：下线通知自动汇总本次在线时长与今日最常使用的前 3 款 App（如：`本次在线 1小时24分 · 今日常用：抖音(48m)、微信(25m)`）。
- **深度链接联动**：点击 iPhone 锁屏上的 Bark 通知（`oafpulse://device?mac=...`），直接唤醒 **OAF Pulse** 跳进该台手机的统计详情页。
- **App 内全图形化管理**：安装后无需再碰命令行，直接在手机 App 里填 Bark Key、勾选需要监控的手机、开关夜间免打扰、一键发送测试推送。

---

## 🚀 快速使用指南

### 第一步：安装手机端巨魔 App
1. 前往本仓库 [**Releases 页面**](https://github.com/csjoyxy/oaf-monitor-ios/releases)（或 Actions 最新构建产物）下载 **`OAFPulse-TrollStore.tipa`**。
2. 在 iPhone 上将 `.tipa` 分享至 **TrollStore（巨魔）** 完成安装。
3. 打开 **OAF Pulse**，填入路由器地址（如 `http://192.168.10.1`）及后台密码即可秒看统计。

### 第二步：在路由器安装上下线 Bark 轻量脚本（可选）
SSH 登录你的 OpenWrt 路由器，执行以下一行命令（纯 Lua 脚本免编译，通吃所有芯片架构与第三方编译固件，同时自动补齐 `fwx` 的 `rpcd` 权限）：

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/csjoyxy/oaf-monitor-ios/main/router-agent/install.sh)"
```

安装完成后：
1. 在 iPhone App Store 安装免费的 **Bark**，复制你的专属 Key。
2. 打开 **OAF Pulse** → **「提醒与设置」**，粘贴 Bark Key，勾选要关注的手机，点击 **「保存配置到路由器」**，再点一下 **「测试推送」** 即可体验！

如需卸载路由器脚本：
```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/csjoyxy/oaf-monitor-ios/main/router-agent/uninstall.sh)"
```

---

## 🛠 自行编译说明

仓库已配置好 GitHub Actions（[`.github/workflows/ios.yml`](.github/workflows/ios.yml)），每次推送到 `main` 分支或手动触发 `workflow_dispatch` 都会在 `macos-15` 上自动构建 `.tipa` 与 `.ipa`。

本地 macOS 编译：
```bash
brew install xcodegen ldid
bash scripts/build-tipa.sh
```
产物位于 `dist/OAFPulse-TrollStore.tipa` 与 `dist/OAFPulse-unsigned.ipa`。
