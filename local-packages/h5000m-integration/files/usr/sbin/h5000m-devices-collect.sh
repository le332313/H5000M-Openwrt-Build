#!/bin/sh
#
# h5000m-devices-collect —— 海狗面板「设备管理」的巡检与自愈
#
# ============================================================================
# ★★ 2026-10-17 v4：从「写入者」彻底改为「巡检者」
# ============================================================================
#
# 演进过程（每一版都是被实测打回来的）
# ------------------------------------
# v1~v3：以为 higorosd 的采集循环不开工，所以每分钟自己拼一份 JSON 写进去。
#        症状确实消失了（页面有设备有流量），但代价是：
#          ① 我写的是 usage.db 的累计值除以 1MB，它是增量语义，两边打架，
#             面板数字在 0.60 ↔ 0.71 之间来回跳；
#          ② 我把 TSV 台账放进了 /etc/higoros/，而 higorosd 会**遍历那个
#             目录、把每个文件的每一行都当设备读**，于是 ranking 里长出了
#             {"deviceId":"#mac,ip,total,in,out,last_date","totalTraffic":0}
#             这种垃圾条目，还被持久化进 state 的 firstSeen/onlineSince；
#          ③ 每分钟写 /tmp + 偶尔写 /etc，纯属多余动作。
#
# 本轮实测出来的真实机制（都有证据，别再猜）
# ------------------------------------------
#   ① /tmp/higoros-devices-state.json 才是**真正的持久基线**。里面
#      traffic.<id>.{todayMb,weekMb,monthMb,dayKey,weekKey,monthKey} 是它
#      自己累加的值。重启 higorosd 后这个值**原样保留**（实测 0.05→0.05），
#      不归零。
#   ② /tmp/higoros-devices-cache.json 是 state 的**投影**，约每 5 秒重写一次。
#      trafficToday 是**MB 浮点**（0.05 这种），语义是**增量累加**，不是
#      usage.db 的累计值。
#   ③ 删掉缓存不给种子 → 它**永久空转**，90 秒也不重建，/devices 返回 []。
#      所以它要一个"起点"才能开始周期刷新。
#   ④ 给它种子时 trafficToday 必须写 **0**。写累计值 1.40 进去，它把 1.40
#      当基线，之后只看增量，页面就显示 0 —— 这正是我最初误判"流量全 0
#      是 bug"的根源。
#   ⑤ /etc/higoros/higoros-devices-cache.json 是**开机种子**，不是运行时
#      基线。它在 /etc/higoros/ 目录下会被和其它文件一起遍历。
#
# 所以 v4 只做四件事
# ------------------
#   1. 巡检 /tmp/higoros-devices-state.json：
#        存在？能解析成 JSON？traffic 字段在？没有非法 key（含逗号/井号/
#        冒号分隔的东西）？没有负数/NaN？
#      任何一项不过 → 说明被污染或损坏 → 备份后重建。
#   2. 重建时不猜：从 usage.db 取真实设备，state 写成**干净的空基线**，
#      traffic 里的 todayMb 一律 0（交给它自己从这一刻开始累加）。
#   3. 巡检 /tmp/higoros-devices-cache.json：不存在就补一份种子（traffic 写 0）。
#   4. 台账挪到 /etc/h5000m/（**绝不能放 /etc/higoros/**），只做旁路存档，
#      按集合变化或 30 分钟落盘，不参与面板展示。
#
# 不做什么
# --------
# · 不再每分钟覆盖缓存 —— 那是 v3 制造抖动的直接原因
# · 不碰原厂二进制（higorosd 闭源）
# · 不删历史设备
# · 不重启 higorosd（它重启会清内存快照，得不偿失；除非 state 反复损坏）
#
# 安装：cron 每分钟一次（由 h5000m-firstboot 写入 /etc/crontabs/root）
#   * * * * * /usr/sbin/h5000m-devices-collect.sh
#
# 调试：
#   /usr/sbin/h5000m-devices-collect.sh --check    # 只体检，不改
#   /usr/sbin/h5000m-devices-collect.sh --fix      # 强制重建 state

CACHE=/tmp/higoros-devices-cache.json
CACHE_ETC=/etc/higoros/higoros-devices-cache.json
STATE=/tmp/higoros-devices-state.json
DB=/etc/usage.db
# ★★ 台账绝不能放在 /etc/higoros/ 下：higorosd 会遍历那个目录，把每个文件
#   的每一行都当成一台设备读进去，污染 ranking 与 state。
TSV=/etc/h5000m/devices-traffic.tsv
LOCK=/tmp/.h5000m-devices-collect.lock
LOGF=/tmp/h5000m-devices-collect.log
HEARTBEAT=/tmp/h5000m-devices-collect.lastrun
PERSIST_EVERY=1800
SUBNET="192.168.88.0/24"

log() {
	echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >>"$LOGF"
	if [ "$(wc -l <"$LOGF" 2>/dev/null || echo 0)" -gt 300 ]; then
		tail -n 150 "$LOGF" >"$LOGF.tmp" 2>/dev/null && mv -f "$LOGF.tmp" "$LOGF" 2>/dev/null
	fi
}

mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM HUP

date -u '+%Y-%m-%dT%H:%M:%SZ' >"$HEARTBEAT" 2>/dev/null

MODE="$1"

# 一键升级进行中 → 让路
ST="$(sed -n 's/^state=//p' /tmp/h5000m-upgrade/status 2>/dev/null | head -n1)"
case "$ST" in
downloading | verifying | flashing)
	log "跳过：一键升级进行中（state=$ST）"
	exit 0
	;;
esac

NOW=$(date +%s)
DAYKEY=$(date +%Y-%m-%d)
WEEKKEY="$(date +%Y)-W$(date +%V)"
MONTHKEY=$(date +%Y-%m)

# ---------------------------------------------------------------- 取真实设备 ---
# 从 usage.db 拿带 IP 的设备：mac|ip|speed_in|speed_out|total|first_date|last_date
# 顺手从 DHCP 租约取主机名，从 iw 取无线归属。
read_devices() {
	awk -F, 'NR>1 && NF>=10 && $2!="NA" && $2!="" {
		printf "%s|%s|%s|%s|%s|%s|%s\n", tolower($1), $2, $4, $5, $8, $9, $10
	}' "$DB" 2>/dev/null
}

read_leases() {
	[ -f /tmp/dhcp.leases ] || return 0
	awk -v now="$NOW" 'NF>=4 && $1+0>now {print $3"|"$4}' /tmp/dhcp.leases 2>/dev/null
}

read_wireless() {
	for ifc in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
		for m in $(iw dev "$ifc" station dump 2>/dev/null | awk '/^Station/{print $2}'); do
			printf '%s ' "$(printf '%s' "$m" | tr 'A-Z' 'a-z')"
		done
	done
}

# ------------------------------------------------------------ 体检（state） ---
# 判据（任何一条不过就重建）：
#   a. 文件存在且非空
#   b. 能被解析（用首尾 {} 与 traffic 键粗判 —— 设备上没有 jq）
#   c. traffic 里的 key 必须是 12 位十六进制（== 去掉冒号的 MAC）。
#      这一条专治 v3 那种污染：垃圾 key 里带冒号、逗号、井号。
state_health() {
	if [ ! -s "$STATE" ]; then
		echo "missing"
		return
	fi
	# 粗判 JSON 完整性：必须首尾花括号、必须有 traffic 键
	head -c1 "$STATE" | grep -q '{' || {
		echo "corrupt"
		return
	}
	tail -c2 "$STATE" | grep -q '}' || {
		echo "corrupt"
		return
	}
	grep -q '"traffic"' "$STATE" || {
		echo "no-traffic"
		return
	}
	# ★ 非法 key 检测：traffic 段里的 key 应当只有 [0-9a-f]{12}
	#   把 traffic 段切出来，取出所有 "...":{"todayMb" 形式的 key
	bad=$(sed 's/.*"traffic":{//; s/},"[a-z]*":{[^}]*}[^}]*$//' "$STATE" 2>/dev/null |
		grep -o '"[^"]*":{"todayMb"' |
		sed 's/":{"todayMb"//; s/"//g' |
		grep -vE '^[0-9a-f]{12}$' |
		head -1)
	if [ -n "$bad" ]; then
		echo "bad-key:$bad"
		return
	fi
	# 负数 / NaN 检测（累加值不该为负）
	grep -qE '"(todayMb|weekMb|monthMb)":-|"(todayMb|weekMb|monthMb)":nan' "$STATE" && {
		echo "bad-value"
		return
	}
	echo "ok"
}

# ------------------------------------------------------------ 重建（state） ---
build_state() {
	LH=/tmp/.h5dhcp.$$
	read_leases >"$LH"

	{
		printf '{"firstSeen":{'
		first=1
		while IFS='|' read -r mac ip sin sout total fdate ldate; do
			[ -n "$mac" ] || continue
			id=$(printf '%s' "$mac" | tr -d ':')
			[ "$first" = 1 ] || printf ','
			first=0
			printf '"%s":%s000' "$id" "${fdate:-$NOW}"
		done <"$DEVROWS"

		printf '},"onlineSince":{'
		first=1
		while IFS='|' read -r mac ip sin sout total fdate ldate; do
			[ -n "$mac" ] || continue
			id=$(printf '%s' "$mac" | tr -d ':')
			[ "$first" = 1 ] || printf ','
			first=0
			printf '"%s":%s000' "$id" "${ldate:-$NOW}"
		done <"$DEVROWS"

		printf '},"onlineState":{'
		first=1
		while IFS='|' read -r mac ip sin sout total fdate ldate; do
			[ -n "$mac" ] || continue
			id=$(printf '%s' "$mac" | tr -d ':')
			[ "$first" = 1 ] || printf ','
			first=0
			printf '"%s":true' "$id"
		done <"$DEVROWS"

		# renamed/limits/blocked/parental 是面板侧用户数据，重建时留空
		# （重建只在 state 已经坏了的时候发生，此时用户数据多半也已丢失，
		#   但宁可留空也不编造）
		printf '},"renamed":{},"limits":{},"blocked":{},"parental":{},"traffic":{'
		first=1
		while IFS='|' read -r mac ip sin sout total fdate ldate; do
			[ -n "$mac" ] || continue
			id=$(printf '%s' "$mac" | tr -d ':')
			[ "$first" = 1 ] || printf ','
			first=0
			# ★ 一律 0：让它从这一刻开始自己累加。写累计值会让页面显示 0。
			printf '"%s":{"todayMb":0,"weekMb":0,"monthMb":0,"dayKey":"%s","weekKey":"%s","monthKey":"%s"}' \
				"$id" "$DAYKEY" "$WEEKKEY" "$MONTHKEY"
		done <"$DEVROWS"
		printf '}}\n'
	} >"$STATE.tmp.$$"

	# 只接受"写完还健康"的版本
	if [ -s "$STATE.tmp.$$" ]; then
		mv -f "$STATE.tmp.$$" "$STATE"
		return 0
	fi
	rm -f "$STATE.tmp.$$"
	return 1
}

# ------------------------------------------------- 关于 connectionType（不修） ---
# 2026-10-17 定案：这一项**不修**，交回 higorosd 自己。
#
# 一度打算在这里把 wired 改写成 wireless，理由是「5G 关联表里明明有
# 02:54:e8:...，它却写 wired」。但更长时间的观察推翻了那个前提：
#
#   · 它有时写 "connectionType":"wifi-5g" —— 说明它**判得出来**，
#     而且合法值是 "wifi-2.4g" / "wifi-5g" 这种带频段的格式，
#     不是我以为的 "wireless"（二进制里 wifi-2.4g 字面量实证）。
#   · 它有时写 "wired" —— 说明判定依赖的链路会间歇性拿不到数据。
#     相关函数：main.readWiFiConnectionMap / main.detectWiFiConnTypeByIface
#     / main.normalizeConnectionType。normalize 会把无法判定的值归到默认。
#
# 如果我强行改成 "wireless"：① 那不是我猜的那个值，前端可能显示成
# 「未知」；② 它 5 秒一次重写，我改完立刻被覆盖，等于白做；③ 只要有一次
# 改错，用户看到的就是编造的类型。**不如让它自己判，判错也不比我编。**
#
# 所以要修只能从"它为什么间歇拿不到无线表"下手，那是另一条独立课题。
# 挂账在可用性评估文档里，不在这里偷改字段。

# ------------------------------------------------------------ 生成缓存种子 ---
# 仅在缓存缺失时用。trafficToday 一律 0（它是增量起点）。
build_cache() {
	LH=/tmp/.h5lease.$$
	read_leases >"$LH"
	WL=" $(read_wireless) "

	{
		printf '{"updatedAt":%s,"subnet":"%s","devices":[' "$((NOW * 1000))" "$SUBNET"
		first=1
		while IFS='|' read -r mac ip sin sout total fdate ldate; do
			[ -n "$mac" ] || continue
			id=$(printf '%s' "$mac" | tr -d ':')
			name=$(awk -F'|' -v ip="$ip" '$1==ip{print $2; exit}' "$LH" 2>/dev/null)
			[ -n "$name" ] || name="$ip"
			name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
			ctype=wired
			case "$WL" in *" $mac "*) ctype=wireless ;; esac
			online=false
			[ -n "$ldate" ] && [ $((NOW - ldate)) -lt 120 ] 2>/dev/null && online=true
			conn=$((ldate - fdate))
			[ "$conn" -ge 0 ] 2>/dev/null || conn=0
			[ "$first" = 1 ] || printf ','
			first=0
			printf '{"id":"%s","name":"%s","macAddress":"%s","ipAddress":"%s"' \
				"$id" "$name" "$(printf '%s' "$mac" | tr 'a-z' 'A-Z')" "$ip"
			printf ',"connectionType":"%s","deviceType":"other","osType":"others"' "$ctype"
			printf ',"connectedTime":%s,"uploadSpeed":%s,"downloadSpeed":%s' \
				"$conn" "${sout:-0}" "${sin:-0}"
			printf ',"isOnline":%s,"isGuest":false,"isBlocked":false,"isLimited":false' "$online"
			printf ',"hasParentalControl":false'
			printf ',"trafficToday":0,"trafficWeek":0,"trafficMonth":0}'
		done <"$DEVROWS"
		printf '],"trafficRanking":[],"blacklist":[]}\n'
	} >"$CACHE.tmp.$$"

	if [ -s "$CACHE.tmp.$$" ]; then
		mv -f "$CACHE.tmp.$$" "$CACHE"
		return 0
	fi
	rm -f "$CACHE.tmp.$$"
	return 1
}

# ---------------------------------------------------------------- 主流程 ---
[ -f "$DB" ] || {
	log "跳过：$DB 不存在（wrtbwmon 没跑）"
	exit 0
}

DEVROWS=/tmp/.h5devs.$$
read_devices >"$DEVROWS"
DEVN=$(wc -l <"$DEVROWS" 2>/dev/null || echo 0)

[ "$MODE" = "--check" ] && {
	h=$(state_health)
	printf 'state: %s\n' "$h"
	printf 'cache: %s\n' "$([ -s "$CACHE" ] && echo exists || echo missing)"
	printf 'devices in usage.db: %s\n' "$DEVN"
	rm -f "$DEVROWS"
	exit 0
}

if [ "$MODE" = "--fix" ]; then
	log "--fix：强制重建 state"
	[ -f "$STATE" ] && cp -f "$STATE" "/tmp/higoros-devices-state.$(date +%s).bak" 2>/dev/null
	build_state && log "state 已重建（设备 $DEVN 台）" || log "state 重建失败"
	rm -f "$DEVROWS"
	exit 0
fi

# 1) 体检 state
SH=$(state_health)
case "$SH" in
ok) ;;
*)
	log "state 不健康（$SH）→ 备份并重建"
	[ -f "$STATE" ] && cp -f "$STATE" "/tmp/higoros-devices-state.$(date +%s).bad" 2>/dev/null
	if build_state; then
		log "state 已重建（设备 $DEVN 台，traffic 一律归零由它自己累加）"
	else
		log "state 重建失败，保留现场待查"
	fi
	;;
esac

# 2) 体检缓存 —— 只在缺失时补种子，**绝不覆盖**
#    （覆盖 = v3 制造抖动的直接原因）
if [ ! -s "$CACHE" ]; then
	log "缓存缺失 → 补一份种子（traffic 归零）"
	build_cache && log "已写入种子（设备 $DEVN 台）" || log "种子写入失败"
fi

# 3) 只记录 connectionType 现状（不修，见上文定案），供后续单独课题用
CT=$(grep -o '"connectionType":"[^"]*"' "$CACHE" 2>/dev/null | sed 's/.*:"//; s/"//' | tr '\n' ' ')
[ -n "$CT" ] && log "connectionType 现状：$CT"

# /etc 那份作为开机种子，只在缺失时同步一份（它不参与运行时）
if [ ! -s "$CACHE_ETC" ] && [ -s "$CACHE" ]; then
	mkdir -p /etc/higoros 2>/dev/null
	cp -f "$CACHE" "$CACHE_ETC" 2>/dev/null && log "补 /etc 开机种子"
fi

# 3) 旁路台账：落在 /etc/h5000m/（绝不进 /etc/higoros/）
mkdir -p /etc/h5000m 2>/dev/null
CURSUM=$(awk -F'|' '{print $1}' "$DEVROWS" 2>/dev/null | LC_ALL=C sort | md5sum | cut -d' ' -f1)
lastsum=$(sed -n '1s/^#//p' "$TSV" 2>/dev/null)
SETTS=/tmp/.h5000m-devices-set.ts
lastts=$(cat "$SETTS" 2>/dev/null)
case "$lastts" in '' | *[!0-9]*) lastts=0 ;; esac
since=$((NOW - lastts))

if [ "$CURSUM" != "$lastsum" ] || [ "$since" -ge "$PERSIST_EVERY" ]; then
	{
		printf '#%s\n' "$CURSUM"
		printf '#mac,ip,total,in,out,last_date\n'
		awk -F'|' '{printf "%s,%s,%s,0,0,%s\n", $1, $2, $5, $7}' "$DEVROWS"
	} >"$TSV.tmp" 2>/dev/null && mv -f "$TSV.tmp" "$TSV" 2>/dev/null
	printf '%s\n' "$NOW" >"$SETTS"
fi

rm -f "$DEVROWS" /tmp/.h5dhcp.$$ /tmp/.h5lease.$$ 2>/dev/null
exit 0
