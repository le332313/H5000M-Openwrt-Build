#!/bin/sh
# HigoOS 保真 overlay —— 首次启动配置（uci-defaults，只跑一次）
# 目标：与原厂 HigoOS 的出厂网络状态一致 —— LAN 192.168.88.1，
#       海狗前端占 80，传统 LuCI(uhttpd) 在 8080。

# 1) 启用海狗后端与风扇服务
[ -x /etc/init.d/higoros ] && /etc/init.d/higoros enable
[ -x /etc/init.d/fancontrol ] && /etc/init.d/fancontrol enable

# 1b) QModem 模组支持库的**提前合并**（START=78，早于 qmodem_init 的 80）
#     modem_scand 只在启动时读一次支持库并缓存，而库的镜像版本不含 RG520N-CN
#     （那一条由 luci-app-qmodem-generic 的 S90 服务运行时 merge）。不提前合并，
#     daemon 就带着「不认识这块模组」的库启动，之后所有补扫都报 profile not matched。
#     该服务同步执行注入器，且注入器幂等，因此 S90 那一遍自然退化为空操作。
[ -x /etc/init.d/qmodem-support-early ] && /etc/init.d/qmodem-support-early enable

# 1c) QModem 模组识别补扫服务
#     镜像里确实出现过 S92 软链，但仓库里没有任何一行显式启用它（uci-defaults 与
#     构建脚本都没有），说明它靠的是构建期的隐式行为。这里显式补上，不再依赖隐式：
#     脚本自带 START=92，enable 会生成 S92/K08。
#     注意：uci-defaults 跑在 /etc/init.d/boot (START=10) 内，而 rcS 在开始时就
#     展开了一次 /etc/rc.d/S* 列表 —— 所以**刷机后的首次开机**这一轮可能不在列表里，
#     第二次开机起必然生效（与原有的隐式机制行为一致）。
[ -x /etc/init.d/qmodem-rescan ] && /etc/init.d/qmodem-rescan enable

# 1d) 流量统计 wrtbwmon —— 镜像只提供文件，不会自动建开机链接。
#     原厂靠出厂时就存在的 /etc/rc.d/S99wrtbwmon；我们的 overlay 是纯文件级复制，
#     必须显式 enable。它驱动 HigoOS 的「流量统计」页与 higorosd 的
#     /devices/traffic/ranking。
#     wrtbwmon 是纯 shell，账本走 `iptables -t RRDIPT`；iptables-nft 由
#     REQUIRED_PACKAGES 带进镜像（缺它时脚本"成功"但永远只记 0 字节）。
#     ★ 它只修流量统计本身 —— 2026-10-13 实测：补上 iptables 并 enable 本服务后，
#     /devices 仍返回空列表，设备发现的缺失另有原因，别把这条当成那个修复。
[ -x /etc/init.d/wrtbwmon ] && /etc/init.d/wrtbwmon enable

# 1e) AdGuard Home —— 保命服务之一，无条件建开机链接。
#     二进制已编进镜像（build.yml 的 ENABLE_ADGUARDHOME）。
#     未走过初始化向导时它只监听 Web(3000)，不监听 5335，也不会碰 dnsmasq ——
#     这一点是实测过的（2026-10-13 装机时 :::3000 在听、53 未被动过），
#     所以全新刷机也能安全 enable。
#     /etc/rc.d/ 不在任何 keep.d 的保护范围内，升级后链接必丢，必须在这里补。
[ -x /etc/init.d/adguardhome ] && /etc/init.d/adguardhome enable

# 1f) PassWall —— 保命服务之二，但**只在确实已经配置过节点时才建开机链接**。
#     包自带的默认 /etc/config/passwall 是 `enabled '1'` 且一个节点都没有；
#     而"无节点时走一遍启动流程会不会改写 dnsmasq 上游"我没有实测依据，
#     万一会，那就是"刷完机 DNS 直接不通"的坑。用"存在节点 section"把它挡在外面，
#     代价只是全新刷机后要在 LuCI 里手动点一次启动；升级场景则有节点 ⇒ 正常自启。
if [ -f /etc/config/passwall ] && [ "$(uci -q show passwall 2>/dev/null | grep -c '=nodes')" -gt 0 ]; then
    /etc/init.d/passwall enable
fi

# 1g) Tailscale —— 远程访问（这台机器在 5G CGNAT 后面，没有公网端口可映射）。
#     镜像已烘入 tailscale + luci-app-tailscale-community（build.yml 的
#     ENABLE_TAILSCALE）。包安装时会自己建 S80 链接，但 /etc/rc.d/ 不在任何
#     keep.d 的保护范围内，升级后链接必丢 ⇒ 在这里显式补上，不再依赖隐式行为。
#     ★ 未登录的守护进程是惰性的（2026-10-14 实测：tailscaled 在跑但未登录时，
#     `ip route` 与 `nft list ruleset` 里 tailscale 条目都是 0，默认路由仍是 5G
#     via wwan0_1），所以全新刷机也能安全 enable；真正组网要等一次 `tailscale up`
#     （在 LuCI 的「网络 → Tailscale」页填 auth key，或命令行给 authkey）。
#     登录态在 /etc/tailscale/tailscaled.state，该目录是 tailscale 包的 conffile，
#     本平台会自动生成 /lib/upgrade/keep.d/tailscale ⇒ 刷机不需要重新登录。
[ -x /etc/init.d/tailscale ] && /etc/init.d/tailscale enable

# 2) 若底座带了其他风扇后台，禁掉，避免两个控制器抢 pwm
#    （海狗页 + /usr/bin/fancontrol v2 是唯一管理者）
for SVC in h5000m-fancontrol fancontrol-h5000m; do
    [ -x "/etc/init.d/$SVC" ] && /etc/init.d/"$SVC" disable 2>/dev/null
done

# 3) 网络：延续 HigoOS 出厂值 192.168.88.1
#    底座默认是 192.168.1.1，既不是原厂值、又和常见内网撞段，这里覆盖。
#    不在这里 restart network：uci-defaults 跑在 /etc/init.d/boot（START=10）里，
#    早于 network（START=20），落盘即可被后续启动流程读到。
uci -q set network.lan.proto='static'
uci -q set network.lan.ipaddr='192.168.88.1'
uci -q set network.lan.netmask='255.255.255.0'
uci -q set network.lan.ip6assign='60'
uci -q commit network

uci -q set dhcp.lan.interface='lan'
uci -q set dhcp.lan.start='100'
uci -q set dhcp.lan.limit='150'
uci -q set dhcp.lan.leasetime='12h'
uci -q set dhcp.lan.dhcpv4='server'
uci -q set dhcp.lan.dhcpv6='disabled'
uci -q set dhcp.lan.ra='server'
uci -q set dhcp.lan.ra_slaac='1'
uci -q set dhcp.lan.ra_flags='other-config'
uci -q set dhcp.lan.max_preferred_lifetime='2700'
uci -q set dhcp.lan.max_valid_lifetime='5400'
uci -q commit dhcp

# 主机名带空格，正是原厂值 —— 必须走 uci，不能用 hostname 命令
uci -q set system.@system[0].hostname='Hiveton H5000M'
uci -q commit system

# 4) 端口腾挪：higorosd 固定监听 :80（海狗前端），传统 LuCI(uhttpd) 挪 8080/8443
#    与原厂 24.10 布局一致：80 = 海狗，8080 = 传统 LuCI
if [ -f /etc/config/uhttpd ]; then
    uci -q set uhttpd.main.listen_http='0.0.0.0:8080'
    uci -q set uhttpd.main.listen_https='0.0.0.0:8443'
    uci -q commit uhttpd
    /etc/init.d/uhttpd restart 2>/dev/null
fi

# 5) U-Boot 环境文件 —— 「一句话进 failsafe」的前提
#    uboot-envtools 包只提供 fw_printenv/fw_setenv，不带 /etc/fw_env.config，
#    overlay 里已经放了一份；这里只在它缺失/指错设备时兜底重写。
#    偏移与大小是实测出来的（CRC32 反推 env_size=0x80000），不要改动。
if [ ! -s /etc/fw_env.config ] || ! grep -q 'mmcblk0p1' /etc/fw_env.config 2>/dev/null; then
    cat > /etc/fw_env.config <<'EOF'
# Hiveton H5000M — U-Boot environment (see higoros-overlay/etc/fw_env.config)
/dev/mmcblk0p1	0x0	0x80000	0x200	0x400
EOF
fi
[ -f /usr/bin/to-failsafe ] && chmod +x /usr/bin/to-failsafe 2>/dev/null

# 6) 无线兜底：保证 radio 使能、国家码 CN（mt76 首启一般会自动生成）
uci -q set wireless.radio0.country='CN' 2>/dev/null
uci -q set wireless.radio1.country='CN' 2>/dev/null
uci -q commit wireless 2>/dev/null

# 7) AdGuard Home 接管 LAN 的 DNS —— **只在 AGH 已经初始化过时**才动手。
#
#    AGH 刚装好、还没走过初始化向导时，/etc/adguardhome/adguardhome.yaml 不存在，
#    5335 端口也就没人监听。此时若把「53 -> 5335」的劫持规则装上，等于把全屋 DNS
#    指向一个空端口 —— 直接断网，比不装还糟。所以两条动作都以 yaml 存在为前提。
#
#    升级场景下 yaml 由 keep.d(adguardhome) 保留，于是规则与这个开关都自动恢复；
#    全新刷机则保持 dnsmasq 直连的干净默认状态，等用户配好 AGH 后再生效。
#
#    本脚本跑在 /etc/init.d/boot(START=10) 内，早于 firewall(START=19)，
#    所以复制完不需要额外 fw4 reload —— firewall 起来时会 include 到它。
if [ -s /etc/adguardhome/adguardhome.yaml ]; then
    # 7a) 安装 nft 劫持规则（priority -160，早于 PassWall 的 -151）
    if [ -f /etc/adguardhome/20-adguard-dns.nft ]; then
        mkdir -p /etc/nftables.d
        cp -f /etc/adguardhome/20-adguard-dns.nft /etc/nftables.d/20-adguard-dns.nft
    fi
    # 7b) 让 PassWall 别再抢 53：它默认 dns_redirect=1 会把 53 截到自己的
    #     chinadns-ng，与 AGH 的劫持互相打架（也只有 AGH 在用时才需要关）。
    if [ -f /etc/config/passwall ]; then
        uci -q set passwall.@global[0].dns_redirect='0'
        uci -q commit passwall
    fi
fi

# 8) AGH 的工作目录从 tmpfs 挪到持久位置 —— **无条件执行，不看是否已初始化**。
#
#    默认 work_dir=/var/lib/adguardhome，而 /var 是指向 /tmp 的软链（tmpfs）
#    ⇒ 每次重启整个目录清空。清空后 AGH 启动时要去下载屏蔽列表，而那一刻
#    chinadns-ng(15353) 常常还没起来 ⇒ 下载失败，且 AGH 不会重试 ⇒
#    规则表是空的 ⇒ **去广告静默失效**：DNS 照通、页面照开，只有广告不拦。
#
#    2026-10-13 刷机后实测踩到：www.baidu.com / www.google.com 解析正常，
#    而 doubleclick.net 返回 142.250.x.x 真地址（升级前是 0.0.0.0）。
#    日志铁证 —— filtering: updating filter url=... err="resolving ...
#    exchanging with 127.0.0.1:15353 ... connection refused"，prev_rules_count=0。
#
#    为什么不放在上面的 if 块里：全新刷机时 adguardhome.yaml 尚不存在（用户还没
#    走初始化向导），放进去就漏了这一支 —— 等用户配好 AGH、再一重启，同样中招。
#    所以这里只看「包在不在」，与是否已初始化无关。
#
#    配套 keep.d 条目见 higoros-overlay/lib/upgrade/keep.d/adguardhome-work：
#    重启靠 overlay 持久，刷机靠 keep.d 携带，两条路都不再需要
#    「启动后立刻联网下载」，竞态无从发生。
if [ -f /etc/config/adguardhome ]; then
    uci -q set adguardhome.config.work_dir='/etc/adguardhome/work'
    uci -q commit adguardhome
fi

exit 0
