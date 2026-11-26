#!/bin/sh
# Uninstaller for OAF Pulse Router Bark Agent
set -e

echo "==> [OAF Pulse] 正在卸载上下线 Bark 通知组件..."
/etc/init.d/oaf-bark stop >/dev/null 2>&1 || true
/etc/init.d/oaf-bark disable >/dev/null 2>&1 || true

rm -f /usr/bin/oaf-barkd \
      /usr/bin/oaf-feature-tool \
      /usr/libexec/rpcd/oaf_bark \
      /etc/init.d/oaf-bark \
      /usr/share/rpcd/acl.d/oaf-bark.json \
      /tmp/oaf_bark_state.json \
      /tmp/oaf_bark_events.json \
      /var/run/oaf-barkd.pid

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
echo "==> [OAF Pulse] 已卸载（配置文件 /etc/config/oaf_bark 已保留，如需彻底删除可执行 rm -f /etc/config/oaf_bark）。"
