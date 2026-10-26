#!/bin/sh
#
# h5000m-rpcd-guard —— rpcd 内存看门狗
#
# 背景：rpcd 对「外部脚本型」ubus 方法（qmodem = /usr/libexec/rpcd/qmodem）
# 的输出缓冲在请求结束后不释放，且泄漏量与方法返回体积挂钩
# （实测：qmodem info 返回 7837 B 时约 40 kB/次；原生方法 system board 零泄漏）。
#
# 触发方 = qmodem-worker，它每 WORKER_INTERVAL 秒把 qmodem 的 24 个方法整套采一轮。
# 实测冻结它之后 qmodem 调用从 102 次/30s 掉到 2 次（-98%），
# 因此本机的泄漏速率基本由它的采集周期决定：
#   15 s（上游默认）         370~524 kB/min ≈ 31 MB/h ≈ 750 MB/天
#   60 s（本固件默认）       约 1/4，见 /etc/qmodem-worker.conf
# 曾累积到 619 MB，导致 available 跌到 18 MB、io 等待 36%、load 21。
# 详见 5G-CPE-H5000M/巡检发现-rpcd内存膨胀-根因定位-20261016.md
#
# 这是「止血」而非治本：治本要上游修 rpcd 的缓冲释放。
# /etc/init.d/rpcd restart 的副作用已验证为零 —— 64 个 ubus 对象全部恢复，
# 无线 / 5G / 一键升级通道均不受影响，只断在途的 ubus 会话（页面重试一次即可）。
#
# 安装：cron 每分钟调用一次（由 h5000m-firstboot 写入 /etc/crontabs/root）
#   * * * * * /usr/sbin/h5000m-rpcd-guard.sh
# 阈值可用环境变量覆盖（仅用于测试）：H5000M_RPCD_GUARD_KB=1000 /usr/sbin/h5000m-rpcd-guard.sh
#
# ★ 放在 /usr/sbin 而不是 /etc：/usr 是镜像的 squashfs，升级时随新镜像更新；
#   /etc 在 overlay 上，同名的旧文件会在 sysupgrade 时被当作用户改动保留下来，
#   于是脚本永远停在第一版。设备侧的真机踩坑记录见部署文档。

THRESHOLD_KB="${H5000M_RPCD_GUARD_KB:-65536}"   # 64 MB；正常值 3~4 MB，危及整机约 600 MB
LOGF="/tmp/h5000m-rpcd-guard.log"
LOCKD="/tmp/.h5000m-rpcd-guard.lock"
STATUS="/tmp/h5000m-upgrade/status"
HEARTBEAT="/tmp/h5000m-rpcd-guard.lastrun"

log() {
	echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >>"$LOGF"
	# 日志留在 tmpfs，限行数避免无界增长
	if [ "$(wc -l <"$LOGF" 2>/dev/null || echo 0)" -gt 300 ]; then
		tail -n 150 "$LOGF" >"$LOGF.tmp" 2>/dev/null && mv -f "$LOGF.tmp" "$LOGF" 2>/dev/null
	fi
}

# 并发保护：cron 每分钟一次，而 restart 可能跨分钟
mkdir "$LOCKD" 2>/dev/null || exit 0
trap 'rmdir "$LOCKD" 2>/dev/null' EXIT INT TERM HUP

# 心跳：无论是否触发都更新（每分钟一次、仅写 tmpfs），运维时一眼可确认 cron 在调用
date -u '+%Y-%m-%dT%H:%M:%SZ' >"$HEARTBEAT" 2>/dev/null

# 一键升级进行中 → 让路。
# state 取值见 /usr/libexec/rpcd/luci.h5000m_upgrade：
#   downloading / verifying / ready / error / flashing / idle
# ★ 不要用「/tmp/h5000m-upgrade 是否存在」判 —— 该目录存着 latest.json，平时就在，
#   那样会让看门狗永久失效。
ST="$(sed -n 's/^state=//p' "$STATUS" 2>/dev/null | head -n1)"
case "$ST" in
	downloading|verifying|flashing)
		log "跳过：一键升级进行中（state=$ST）"
		exit 0
		;;
esac

P="$(pidof rpcd)"
[ -z "$P" ] && exit 0   # rpcd 不在，不插手

V="$(awk '/^VmRSS/{print $2}' "/proc/$P/status" 2>/dev/null)"
case "$V" in
	''|*[!0-9]*) exit 0 ;;
esac

[ "$V" -le "$THRESHOLD_KB" ] && exit 0

UP="$(cut -d. -f1 /proc/uptime)"
logger -t rpcd-guard "VmRSS=${V}kB > ${THRESHOLD_KB}kB, restarting rpcd (uptime=${UP}s)"
log "触发：VmRSS=${V}kB > ${THRESHOLD_KB}kB（pid=$P, uptime=${UP}s）→ restart rpcd"

/etc/init.d/rpcd restart >/dev/null 2>&1
sleep 3

NP="$(pidof rpcd)"
if [ -n "$NP" ]; then
	NV="$(awk '/^VmRSS/{print $2}' "/proc/$NP/status" 2>/dev/null)"
	case "$NV" in
		''|*[!0-9]*) log "完成：新 pid=$NP（VmRSS 读不到）" ;;
		*)           log "完成：新 pid=$NP, VmRSS=${NV}kB, 回收 $((V - NV)) kB" ;;
	esac
else
	log "异常：restart 后 rpcd 未起来，需人工介入"
fi

exit 0
