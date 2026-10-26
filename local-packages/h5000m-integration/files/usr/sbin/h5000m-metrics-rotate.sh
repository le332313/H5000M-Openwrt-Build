#!/bin/sh
# h5000m-metrics-rotate.sh —— 收敛 higorosd 的两个不滚动 JSON，防 tmpfs 被吃满
#
# 实测 2026-10-22：/tmp/higoros/resource-metrics-db.json 18 小时长到 1.9 MB
# （≈2.5 MB/天 ≈ 75 MB/月），/tmp 只有 492 MB 且是 tmpfs。它自己不滚动，
# 跑几个月会把 tmpfs 吃满，之后 higorosd 写失败又是一类「面板不动」的故障。
#
# 策略（都是保尾部、纯裁剪，不动结构）：
#   resource-metrics-db.json : samples 保留最近 1440 条（按 5 分钟采样 ≈ 5 天）
#                              daily  保留最近 30 天
#   cpe-speed-history.json   : history 保留最近 1440 条
# 只有真的超出阈值才重写，正常情况下本脚本是空操作。
set -u

D=/tmp/higoros
LOG=/tmp/h5000m-metrics-rotate.log
# samples 实测 5 秒一条、约 140 B/条：留 24 小时 = 17280 条 ≈ 2.4 MB，
# 面板的实时曲线够用，tmpfs 也不会再随开机时长线性膨胀。
# （不裁剪时 18 小时就 1.9 MB，一个月 75 MB。）
MAX_SAMPLES=${MAX_SAMPLES:-17280}
MAX_DAILY=${MAX_DAILY:-30}
MAX_HISTORY=${MAX_HISTORY:-1440}

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >>"$LOG"; }

[ -f /tmp/.h5000m-upgrade ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

rotate() {
    file="$1"
    expr="$2"
    [ -f "$file" ] || return 0
    jq -e . "$file" >/dev/null 2>&1 || { log "$file 解析失败，跳过"; return 0; }
    before=$(wc -c <"$file")
    tmp="$file.tmp"
    jq -c "$expr" "$file" >"$tmp" 2>/dev/null || { rm -f "$tmp"; log "$file 裁剪失败，保持原样"; return 0; }
    after=$(wc -c <"$tmp")
    # 只有变小才替换；变大的说明表达式有问题，宁可不动
    if [ "$after" -lt "$before" ]; then
        mv -f "$tmp" "$file"
        log "$file 收敛：${before}B -> ${after}B"
    else
        rm -f "$tmp"
    fi
}

rotate "$D/resource-metrics-db.json" "
  .samples = ((.samples // []) | if length > $MAX_SAMPLES then .[length-$MAX_SAMPLES:] else . end)
  | if (.daily | type) == \"object\" then
      .daily = ((.daily | to_entries | sort_by(.key) | if length > $MAX_DAILY then .[length-$MAX_DAILY:] else . end) | from_entries)
    else . end
"

rotate "$D/cpe-speed-history.json" "
  .history = ((.history // []) | if length > $MAX_HISTORY then .[length-$MAX_HISTORY:] else . end)
"

exit 0
