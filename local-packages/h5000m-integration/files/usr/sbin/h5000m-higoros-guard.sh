#!/bin/sh
#
# h5000m-higoros-guard —— higorosd 流量循环看门狗
#
# 背景（2026-10-21 实机）：
#   新固件把 wrtbwmon 的库钉到 /tmp/usage.db（higorosd 硬编码路径）之后，
#   流量列在人动手重启 higorosd 之后是正常的，但**开机后大概率不动**：
#   实测 5 次开机里 4 次 state 文件 mtime 冻结在开机后几秒（todayMb 恒 0），
#   而 /tmp/usage.db 仍在每 5 秒累加真实流量。手工 `/etc/init.d/higoros restart`
#   之后 6 次全部正常，且 todayMb 立即按库里的累计值算出来（不丢数据）。
#
#   已经排除过的假设（都做过对照实验，别再走一遍）：
#     · 「库只有表头」          —— 手工写表头后启动，正常推进
#     · 「库被截成 0 字节」      —— 截 2 秒再恢复，仍推进
#     · 「state/cache 被删」     —— 单删、双删都试过，正常推进
#     · 「wrtbwmon 起得比它晚」  —— 把 wrtbwmon 提前到 START=90，仍冻结
#     · 「启动太早」            —— 给 higoros 加 sleep 30，仍冻结
#     · 「采集器 cron 干扰」     —— 关掉后仍冻结（且 firstboot 会把 cron 写回来，
#                                  那次实验本身无效）
#   根因尚未定位（二进制内部行为，无日志可读）。本脚本是**止血**：
#   它不掩盖故障 —— 每次重启都写日志，日志里能看出自愈频率。
#
# 判据用 state 的 mtime，不用 todayMb：没流量的空闲设备 todayMb 本该是 0，
# 但 mtime 每 5 秒必跳；mtime 不跳 = 循环死了，这是唯一可靠的信号。
#
# 安装：cron 每分钟（由 h5000m-firstboot 写入 /etc/crontabs/root）
#   * * * * * /usr/sbin/h5000m-higoros-guard.sh

STATE=/tmp/higoros-devices-state.json
LOGF=/tmp/h5000m-higoros-guard.log
LOCKD=/tmp/.h5000m-higoros-guard.lock
STATUS=/tmp/h5000m-upgrade/status
STALE="${H5000M_HIGOROS_STALE:-120}"     # 秒。正常 5 秒一次，120 秒说明已经死透
MAXPERHR="${H5000M_HIGOROS_MAX:-6}"      # 每小时最多重启次数，防重启风暴

log() {
	echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >>"$LOGF"
	if [ "$(wc -l <"$LOGF" 2>/dev/null || echo 0)" -gt 300 ]; then
		tail -n 150 "$LOGF" >"$LOGF.tmp" 2>/dev/null && mv -f "$LOGF.tmp" "$LOGF" 2>/dev/null
	fi
}

# 升级进行中一律让路（升级会重启服务，别和它抢）
if [ -f "$STATUS" ] && grep -qiE 'running|flashing|downloading' "$STATUS" 2>/dev/null; then
	exit 0
fi

# 防止上一轮还没跑完（脚本本身很轻，但 cron 撞车时会叠）
if ! mkdir "$LOCKD" 2>/dev/null; then
	exit 0
fi
trap 'rmdir "$LOCKD" 2>/dev/null' EXIT INT TERM

NOW=$(date +%s)

# state 不存在：可能刚开机还没写出来，给 180 秒宽限（用开机时长判断）
if [ ! -f "$STATE" ]; then
	UP=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
	if [ "${UP:-0}" -lt 180 ]; then
		exit 0
	fi
	log "state 文件不存在且已开机 ${UP}s —— 重启 higorosd"
else
	MT=$(stat -c %Y "$STATE" 2>/dev/null || echo 0)
	AGE=$((NOW - MT))
	if [ "$AGE" -lt "$STALE" ]; then
		exit 0
	fi
	log "state 已 ${AGE}s 未更新（阈值 ${STALE}s）—— 重启 higorosd"
fi

# 每小时限次（时间戳文件，一小时内的时间戳行数）
STAMPF=/tmp/h5000m-higoros-guard.stamps
: >>"$STAMPF" 2>/dev/null
awk -v t="$NOW" '$1 > t-3600' "$STAMPF" >"$STAMPF.tmp" 2>/dev/null
mv -f "$STAMPF.tmp" "$STAMPF" 2>/dev/null
N=$(wc -l <"$STAMPF" 2>/dev/null || echo 0)
if [ "${N:-0}" -ge "$MAXPERHR" ]; then
	log "本小时已重启 ${N} 次，达到上限 ${MAXPERHR}，本轮跳过（需要人工看一眼）"
	exit 0
fi
echo "$NOW" >>"$STAMPF"

/etc/init.d/higoros restart >/dev/null 2>&1
sleep 8
MT2=$(stat -c %Y "$STATE" 2>/dev/null || echo 0)
if [ "$MT2" -gt "$MT" ] 2>/dev/null; then
	log "重启后 state 已恢复更新（mtime $MT -> $MT2）"
else
	log "重启后 state 仍未更新（mtime $MT2）—— 下一轮再试，若连续失败请人工检查"
fi
exit 0
