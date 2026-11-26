#!/bin/sh
# One-line installer for OAF Pulse Router Bark Agent (OpenWrt / LibWrt / ImmortalWrt + OAF 7.0+)
set -e

REPO_RAW="https://raw.githubusercontent.com/csjoyxy/oaf-monitor-ios/main/router-agent"
TS="$(date +%s 2>/dev/null || echo 1)"

echo "==> [OAF Pulse] 正在安装/更新超轻量上下线 Bark 通知组件..."

fetch_file() {
    src="$1?t=$TS"
    dst="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -m 20 "$src" -o "$dst"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -T 20 -O "$dst" "$src"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 20 -O "$dst" "$src"
    else
        echo "错误：未找到 curl / uclient-fetch / wget，无法下载脚本。" >&2
        exit 1
    fi
}

[ -x /usr/bin/lua ] || {
    echo "错误：未检测到 /usr/bin/lua。" >&2
    exit 1
}

mkdir -p /usr/bin /usr/libexec/rpcd /usr/share/rpcd/acl.d /etc/init.d /etc/config

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo "")"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/oaf-barkd.lua" ]; then
    cp "$SCRIPT_DIR/oaf-barkd.lua" /usr/bin/oaf-barkd
    cp "$SCRIPT_DIR/oaf-feature-tool.lua" /usr/bin/oaf-feature-tool
    cp "$SCRIPT_DIR/rpcd-oaf-bark.lua" /usr/libexec/rpcd/oaf_bark
    cp "$SCRIPT_DIR/oaf-bark.init" /etc/init.d/oaf-bark
    cp "$SCRIPT_DIR/oaf-bark.acl.json" /usr/share/rpcd/acl.d/oaf-bark.json
else
    fetch_file "$REPO_RAW/oaf-barkd.lua" /usr/bin/oaf-barkd
    fetch_file "$REPO_RAW/oaf-feature-tool.lua" /usr/bin/oaf-feature-tool
    fetch_file "$REPO_RAW/rpcd-oaf-bark.lua" /usr/libexec/rpcd/oaf_bark
    fetch_file "$REPO_RAW/oaf-bark.init" /etc/init.d/oaf-bark
    fetch_file "$REPO_RAW/oaf-bark.acl.json" /usr/share/rpcd/acl.d/oaf-bark.json
fi

chmod 0755 /usr/bin/oaf-barkd /usr/bin/oaf-feature-tool /usr/libexec/rpcd/oaf_bark /etc/init.d/oaf-bark
chmod 0644 /usr/share/rpcd/acl.d/oaf-bark.json

if [ ! -f /etc/config/oaf_bark ]; then
    cat > /etc/config/oaf_bark <<'EOF'
config global 'main'
	option enabled '0'
	option bark_server 'https://api.day.app'
	option bark_key ''
	option poll_interval '15'
	option offline_debounce '90'
	option watch_mode 'selected'
	option notify_online '1'
	option notify_offline '1'
	option include_summary '1'
	option quiet_enable '0'
	option quiet_start '23:30'
	option quiet_end '07:00'
EOF
fi

# Self-test rpcd plugin output before restarting rpcd
if ! /usr/libexec/rpcd/oaf_bark list >/dev/null 2>&1; then
    echo "错误：/usr/libexec/rpcd/oaf_bark 自检失败：" >&2
    /usr/libexec/rpcd/oaf_bark list || true
    exit 1
fi

/etc/init.d/rpcd restart >/dev/null 2>&1 || {
    /etc/init.d/rpcd stop >/dev/null 2>&1 || true
    sleep 1
    /etc/init.d/rpcd start >/dev/null 2>&1 || true
}
sleep 1

/etc/init.d/oaf-bark enable >/dev/null 2>&1 || true
/etc/init.d/oaf-bark restart >/dev/null 2>&1 || true

if ubus list oaf_bark >/dev/null 2>&1; then
    echo "==> [OAF Pulse] ✓ 安装成功，ubus 接口 (oaf_bark) 已注册就绪！"
    echo "    请打开手机上的 OAF Pulse App ->「提醒与设置」点击「我已安装，重新检测」（或杀掉 App 重进一次以刷新权限会话）。"
else
    echo "==> [OAF Pulse] 警告：rpcd 尚未列出 oaf_bark，尝试强制重启 rpcd..."
    killall -9 rpcd >/dev/null 2>&1 || true
    /etc/init.d/rpcd start >/dev/null 2>&1 || true
    sleep 1
    ubus list oaf_bark
    echo "==> [OAF Pulse] ✓ ubus 接口 (oaf_bark) 已就绪！"
fi
