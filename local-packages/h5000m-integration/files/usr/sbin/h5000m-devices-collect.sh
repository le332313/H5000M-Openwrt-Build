#!/bin/sh
#
# h5000m-devices-collect —— 海狗面板「设备管理」的兜底采集器
#
# 为什么需要它
# ------------
# /api/v1/devices 不实时采集，只读 /etc/higoros/higoros-devices-cache.json
# 这个台账。而 higorosd 里负责写台账的设备采集循环在本机不开工：
# 开机跑一阵后停住（或根本没写第一笔），重启也不恢复。
# 已排除「缺种子文件」这个假说（实验 A：放空骨架 + 重启，十分钟内
# 采集循环连一笔都没写，而 modem/speed/traffic 三个循环都在正常刷新）。
#
# 数据其实都现成：
#   /etc/usage.db         wrtbwmon 的台账，10 列：
#                         mac,ip,iface,speed_in,speed_out,in,out,total,first_date,last_date
#   /tmp/dhcp.leases      租约，五列：expiry mac ip hostname clientid
#   iw dev <ifc> station  无线关联表，用来区分有线/无线
# 所以这是「没人去采」，不是「采不到」。
#
# 它做什么
# --------
# 每分钟把上面三个源拼成 higorosd 期望的 JSON 台账，写到它读的那个路径。
# 面板照样读文件，文件对了页面就出数。**不碰原厂二进制**——HigoOS 前端要
# 保持可用，而 higorosd 是闭源的，改不了。
#
# 它不做什么
# ----------
# · 不写 higoros-devices-state.json（除非文件不存在，才放一个空骨架）。
#   那个文件里有 renamed / parental / limits / blocked，是面板侧用户数据；
#   采集器不产生它们，也就不该覆盖它们。
# · 不删除任何历史设备。台账是累积的（原厂那份含 108 台），消失的设备
#   只标记 isOnline=false。
#
# 单位约定
# --------
# usage.db 的 in/out/total 是**字节**；cache 里 trafficToday/Week/Month
# 原厂样本是 0，按 MB 整数处理。speed_in/speed_out 是 B/s，直接透传。
#
# 安装：cron 每分钟一次（由 h5000m-firstboot 写入 /etc/crontabs/root）
#   * * * * * /usr/sbin/h5000m-devices-collect.sh
# keep.d 白名单：/etc/higoros/h5000m-devices-traffic.tsv（累积基线，丢了
# 只是当日流量从零算，不影响设备列表）
#
# ★ 与 rpcd 看门狗同套路：放在 /usr/sbin（squashfs，随新镜像更新），
#   不放在 /etc（overlay 上会被 sysupgrade 当用户改动永远留住第一版）。

DB=/etc/usage.db
LEASES=/tmp/dhcp.leases
# higorosd 里两个路径都在（strings 实证）：
#   /tmp/higoros-devices-cache.json      tmpfs，运行时/高频
#   /etc/higoros/higoros-devices-cache.json  overlay（在 flash 上），持久台账
# 每分钟写 /etc 会持续磨损 eMMC，所以两份分工：
#   /tmp 每分钟更新（实时在线状态与速率）
#   /etc 只在「设备集合变化」或超过 30 分钟时同步（重启后的基线）
CACHE=/tmp/higoros-devices-cache.json
CACHE_ETC=/etc/higoros/higoros-devices-cache.json
STATE=/etc/higoros/higoros-devices-state.json
TSV=/etc/higoros/h5000m-devices-traffic.tsv
SETSUM=/tmp/.h5000m-devices-set.sum
SETTS=/tmp/.h5000m-devices-set.ts
PERSIST_EVERY=1800
LOCK=/tmp/.h5000m-devices-collect.lock
LOGF=/tmp/h5000m-devices-collect.log
HEARTBEAT=/tmp/h5000m-devices-collect.lastrun
SUBNET="192.168.88.0/24"

log() {
	echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >>"$LOGF"
	if [ "$(wc -l <"$LOGF" 2>/dev/null || echo 0)" -gt 300 ]; then
		tail -n 150 "$LOGF" >"$LOGF.tmp" 2>/dev/null && mv -f "$LOGF.tmp" "$LOGF" 2>/dev/null
	fi
}

# 并发保护：cron 每分钟一次，而写台账可能跨分钟
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM HUP

date -u '+%Y-%m-%dT%H:%M:%SZ' >"$HEARTBEAT" 2>/dev/null

# 一键升级进行中 → 让路。判据读 status 的 state=，不要用目录是否存在
# （那个目录平时就存着 latest.json，用它判会让采集器永久失效）。
ST="$(sed -n 's/^state=//p' /tmp/h5000m-upgrade/status 2>/dev/null | head -n1)"
case "$ST" in
downloading | verifying | flashing)
	log "跳过：一键升级进行中（state=$ST）"
	exit 0
	;;
esac

[ -f "$DB" ] || {
	log "跳过：$DB 不存在（wrtbwmon 没跑）"
	exit 0
}

mkdir -p /etc/higoros 2>/dev/null

NOW=$(date +%s)
DAY=$(date +%Y%m%d)
WEEK=$(date +%Y-W%V)
MONTH=$(date +%Y%m)

# ---------------------------------------------------------------- 在线来源 ---
# 无线关联：把 MAC 收进来，用来把 connectionType 判成 wireless。
# iw 对非无线接口会报错，全部 2>/dev/null。
WL=" "
for ifc in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
	for m in $(iw dev "$ifc" station dump 2>/dev/null | awk '/^Station/{print $2}'); do
		WL="$WL$(printf '%s' "$m" | tr 'A-Z' 'a-z') "
	done
done

# 租约：ip->hostname，以及 mac 是否还在租期内。
# 用两个临时文件而不是关联数组 —— busybox ash 没有 declare -A。
LH=/tmp/.h5000m-lease-host.$$
LI=/tmp/.h5000m-lease-on.$$
: >"$LH"
: >"$LI"
if [ -f "$LEASES" ]; then
	# ★ 变量不能叫 exp —— 那是 awk 的内置函数名（exp()），busybox awk 会
	#   报 "Unexpected token" 并且被 2>/dev/null 吞掉，症状就是静默拿不到
	#   主机名、全部退回成 IP。这一版之前正是这么错的。
	awk -v now="$NOW" -v lh="$LH" -v li="$LI" '
		NF >= 4 {
			expt = $1 + 0; mac = tolower($2); ip = $3; host = $4
			if (expt > now) { print mac, ip > li; print ip, host > lh }
		}
	' "$LEASES"
fi
trap 'rmdir "$LOCK" 2>/dev/null; rm -f "$LH" "$LI"' EXIT INT TERM HUP

# ---------------------------------------------------------------- 读旧基线 ---
# TSV 列：id mac lastIp total dayKey todayB weekKey weekB monthKey monthB firstSeen lastSeen
[ -f "$TSV" ] || : >"$TSV"

old_field() { # <id> <列号>
	awk -F'\t' -v id="$1" -v c="$2" '$1==id{print $c; exit}' "$TSV" 2>/dev/null
}

# ---------------------------------------------------------------- 生成台账 ---
OUT=/tmp/.h5000m-devices-cache.$$
NEWTSV=/tmp/.h5000m-devices-tsv.$$
: >"$OUT"
: >"$NEWTSV"

n=0
first=1
{
	printf '{\n'
	printf '  "updatedAt": %s,\n' "$(($(date +%s) * 1000))"
	printf '  "subnet": "%s",\n' "$SUBNET"
	printf '  "devices": ['
} >"$OUT"

# 先处理 usage.db 里现役的设备，再补上历史台账里已消失的。
# awk 输出：mac|ip|iface|speed_in|speed_out|in|out|total|first_date|last_date
awk -F, '
	NR == 1 && /^#/ { next }
	NF >= 10 {
		mac = tolower($1); ip = $2
		if (ip == "NA" || ip == "") next
		print mac "|" ip "|" $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" $8 "|" $9 "|" $10
	}
' "$DB" 2>/dev/null >/tmp/.h5000m-usage.$$

while IFS='|' read -r mac ip iface sin sout bin bout total fdate ldate; do
	[ -n "$mac" ] || continue
	id="$(printf '%s' "$mac" | tr -d ':')"

	# 主机名：租约优先，否则用 IP（原厂样本也是这么兜的）
	name="$(awk -v ip="$ip" '$1==ip{print $2; exit}' "$LH" 2>/dev/null)"
	[ -n "$name" ] && [ "$name" != "*" ] || name="$ip"

	# 在线判定：租约未过期，或 usage.db 的 last_date 在两分钟内
	online=false
	if grep -qxF "$mac $ip" "$LI" 2>/dev/null; then
		online=true
	elif [ -n "$ldate" ] && [ $((NOW - ldate)) -lt 120 ] 2>/dev/null; then
		online=true
	fi

	ctype=wired
	case "$WL" in
	*" $mac "*) ctype=wireless ;;
	esac

	# 流量：total 是累计字节。增量按 day/week/month 各自归零累加。
	pid_t=$(old_field "$id" 4)
	pday=$(old_field "$id" 5)
	ptoday=$(old_field "$id" 6)
	pweek=$(old_field "$id" 7)
	pweekb=$(old_field "$id" 8)
	pmonth=$(old_field "$id" 9)
	pmonthb=$(old_field "$id" 10)
	pfirst=$(old_field "$id" 11)

	[ -n "$pid_t" ] || pid_t=0
	[ -n "$ptoday" ] || ptoday=0
	[ -n "$pweekb" ] || pweekb=0
	[ -n "$pmonthb" ] || pmonthb=0

	# 跨日/跨周/跨月先归零
	[ "$pday" = "$DAY" ] || ptoday=0
	[ "$pweek" = "$WEEK" ] || pweekb=0
	[ "$pmonth" = "$MONTH" ] || pmonthb=0

	delta=$((total - pid_t))
	[ "$delta" -ge 0 ] 2>/dev/null || delta=0
	todayb=$((ptoday + delta))
	weekb=$((pweekb + delta))
	monthb=$((pmonthb + delta))

	[ -n "$pfirst" ] || pfirst="$fdate"
	connected=$((ldate - pfirst))
	[ "$connected" -ge 0 ] 2>/dev/null || connected=0

	today_mb=$((todayb / 1048576))
	week_mb=$((weekb / 1048576))
	month_mb=$((monthb / 1048576))

	# JSON 字符串里只允许安全字符，主机名来自 DHCP 客户端、不可信
	safe_name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"

	[ "$first" = 1 ] || printf ',' >>"$OUT"
	first=0
	{
		printf '\n    {"id":"%s","name":"%s","macAddress":"%s","ipAddress":"%s"' \
			"$id" "$safe_name" "$(printf '%s' "$mac" | tr 'a-z' 'A-Z')" "$ip"
		printf ',"connectionType":"%s","deviceType":"other","osType":"others"' "$ctype"
		printf ',"connectedTime":%s,"uploadSpeed":%s,"downloadSpeed":%s' \
			"$connected" "${sout:-0}" "${sin:-0}"
		printf ',"isOnline":%s,"isGuest":false,"isBlocked":false,"isLimited":false' "$online"
		printf ',"hasParentalControl":false'
		printf ',"trafficToday":%s,"trafficWeek":%s,"trafficMonth":%s}' \
			"$today_mb" "$week_mb" "$month_mb"
	} >>"$OUT"

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$id" "$mac" "$ip" "$total" "$DAY" "$todayb" "$WEEK" "$weekb" \
		"$MONTH" "$monthb" "$pfirst" "$NOW" >>"$NEWTSV"

	n=$((n + 1))
done </tmp/.h5000m-usage.$$

# 历史设备：TSV 里有、usage.db 里已经没有的，保留但标离线。
# 这就是原厂那份 108 台台账的行为——累积而不是快照。
awk -F'\t' '{print $1}' "$NEWTSV" >/tmp/.h5000m-seen.$$
while IFS="$(printf '\t')" read -r id mac lastip total dk tb wk wb mk mb fs ls; do
	[ -n "$id" ] || continue
	grep -qxF "$id" /tmp/.h5000m-seen.$$ && continue

	pday=$dk
	ptoday=$tb
	pweek=$wk
	pweekb=$wb
	pmonth=$mk
	pmonthb=$mb
	[ "$pday" = "$DAY" ] || ptoday=0
	[ "$pweek" = "$WEEK" ] || pweekb=0
	[ "$pmonth" = "$MONTH" ] || pmonthb=0

	[ "$first" = 1 ] || printf ',' >>"$OUT"
	first=0
	{
		printf '\n    {"id":"%s","name":"%s","macAddress":"%s","ipAddress":"%s"' \
			"$id" "$lastip" "$(printf '%s' "$mac" | tr 'a-z' 'A-Z')" "$lastip"
		printf ',"connectionType":"wired","deviceType":"other","osType":"others"'
		printf ',"connectedTime":0,"uploadSpeed":0,"downloadSpeed":0'
		printf ',"isOnline":false,"isGuest":false,"isBlocked":false,"isLimited":false'
		printf ',"hasParentalControl":false'
		printf ',"trafficToday":%s,"trafficWeek":%s,"trafficMonth":%s}' \
			"$((ptoday / 1048576))" "$((pweekb / 1048576))" "$((pmonthb / 1048576))"
	} >>"$OUT"

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$id" "$mac" "$lastip" "$total" "$DAY" "$ptoday" "$WEEK" "$pweekb" \
		"$MONTH" "$pmonthb" "$fs" "$ls" >>"$NEWTSV"
	n=$((n + 1))
done <"$TSV"

printf '\n  ]\n}\n' >>"$OUT"

# 落盘：/tmp 每次都写；/etc 只按「集合变化 / 超时」同步，避免每分钟擦 flash。
# 集合指纹只取 id 排序列表 —— 流量数字每分钟都变，拿整份文件做指纹等于每次
# 都判「变了」，那 30 分钟的门就形同虚设。
mv -f "$NEWTSV" "$TSV" 2>/dev/null
setsum="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$OUT" | LC_ALL=C sort | md5sum | cut -d' ' -f1)"
lastsum="$(cat "$SETSUM" 2>/dev/null)"
lastts="$(cat "$SETTS" 2>/dev/null)"
# 文件可能被半写、也可能从没写过：非纯数字一律当 0，否则算术会在这里炸掉
case "$lastts" in '' | *[!0-9]*) lastts=0 ;; esac
since=$((NOW - lastts))

cp -f "$OUT" "$CACHE" 2>/dev/null || log "写 $CACHE 失败"

if [ "$setsum" != "$lastsum" ] || [ "$since" -ge "$PERSIST_EVERY" ]; then
	mkdir -p /etc/higoros 2>/dev/null
	if cp -f "$OUT" "$CACHE_ETC" 2>/dev/null; then
		printf '%s\n' "$setsum" >"$SETSUM"
		printf '%s\n' "$NOW" >"$SETTS"
		log "持久化到 $CACHE_ETC（设备 $n 台，距上次 ${since}s）"
	fi
fi

rm -f "$OUT"
chmod 0644 "$CACHE" "$CACHE_ETC" 2>/dev/null

# state 只在完全不存在时放空骨架。已有内容一律不动——
# 里面有 renamed/parental/limits/blocked，是面板侧用户数据。
if [ ! -f "$STATE" ]; then
	printf '{"firstSeen":{},"traffic":{},"renamed":{},"parental":{},"limits":{},"blocked":{},"onlineState":{},"onlineSince":{}}\n' >"$STATE"
fi

# 空列表要留痕：设备页空着时，最想知道的就是「采集器到底跑没跑」。
[ "$n" -eq 0 ] && log "台账为空（usage.db 里没有带 IP 的设备）"

rm -f /tmp/.h5000m-usage.$$ /tmp/.h5000m-seen.$$
exit 0
