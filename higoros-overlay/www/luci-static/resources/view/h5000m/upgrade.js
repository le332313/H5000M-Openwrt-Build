'use strict';
'require view';
'require rpc';
'require ui';

/*
 * 固件升级 —— H5000M 一键升级页（8080 端口 LuCI）。
 *
 * 数据面全在后端 luci.h5000m_upgrade：本页只负责显示、触发和轮询。
 * 下载是 ~80 MB，ubus 调用不可能等它结束，所以后端把下载放到脱离进程里跑，
 * 这里每 2 秒问一次进度。
 *
 * 刷写前**必定**再确认一次：升级会重启整台设备（它同时是网络出口），
 * 所以「下载并升级」的第二次点击是安全闸门，不是多余的步骤。
 */

var callStatus = rpc.declare({ object: 'luci.h5000m_upgrade', method: 'status', expect: {} });
var callCheck  = rpc.declare({ object: 'luci.h5000m_upgrade', method: 'check', expect: {} });
var callStart  = rpc.declare({ object: 'luci.h5000m_upgrade', method: 'start', params: [ 'url' ], expect: {} });
var callFlash  = rpc.declare({ object: 'luci.h5000m_upgrade', method: 'flash', expect: {} });
var callCancel = rpc.declare({ object: 'luci.h5000m_upgrade', method: 'cancel', expect: {} });

function fmtBytes(n) {
	n = parseInt(n || 0, 10);
	if (!n || n < 0)
		return '-';
	var u = [ 'B', 'KB', 'MB', 'GB' ], i = 0;
	while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
	return (i === 0 ? n : n.toFixed(1)) + ' ' + u[i];
}

function shortRev(r) {
	if (!r || r === 'unknown')
		return r || '-';
	return r.length > 12 ? r.substring(0, 12) : r;
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function () {
		/* 两件事都做：状态用于显示，check 用于判断是否有新版本。
		   check 会联网，失败不该让整页打不开，所以各自兜底。 */
		return Promise.all([
			callStatus().catch(function () { return {}; }),
			callCheck().catch(function () { return { ok: 0, message: '检查更新失败' }; })
		]);
	},

	render: function (data) {
		this.st = data[0] || {};
		this.ck = data[1] || {};
		this.timer = null;

		this.nodeVersions = E('div');
		this.nodeProgress = E('div');
		this.nodeMessage = E('div', { 'style': 'margin:.6em 0;color:#555' });

		var view_ = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('固件升级')),
			E('div', { 'class': 'cbi-map-descr' },
				_('从固件发布站点下载最新镜像并就地升级。镜像下载后会校验 sha256，校验不通过绝不刷写；' +
				  '升级会保留现有配置（/etc/config、AdGuard Home、PassWall 节点）。')),
			this.nodeVersions,
			this.renderSource(),
			this.renderActions(),
			this.nodeProgress,
			this.nodeMessage
		]);

		this.refresh(data[0] || {});
		if (this.st.state === 'downloading' || this.st.state === 'verifying')
			this.startPolling();

		return view_;
	},

	row: function (label, value) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '30%' }, label),
			E('td', { 'class': 'td left' }, value == null || value === '' ? '-' : value)
		]);
	},

	badge: function (ok, text) {
		return E('span', {
			'style': 'display:inline-block;padding:.15em .6em;border-radius:.25rem;font-size:.85em;' +
				(ok ? 'background:#e7f4e4;color:#2b6b3a;border:1px solid #b7ddb0'
					: 'background:#fdecea;color:#8a2b21;border:1px solid #f2b8b1')
		}, text);
	},

	renderSource: function () {
		this.inputUrl = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%',
			'placeholder': this.st.base_url || 'https://…',
			'value': ''
		});
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('升级源')),
			E('div', { 'class': 'cbi-map-descr' },
				_('留空即使用固件内置地址（与软件包源同一站点）。填其它地址可走镜像站。')),
			E('div', { 'style': 'display:flex;gap:.5em;align-items:center;margin:.5em 0' }, [
				E('label', { 'style': 'white-space:nowrap' }, _('自定义地址')),
				this.inputUrl
			])
		]);
	},

	renderActions: function () {
		this.btnCheck = E('button', {
			'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleCheck')
		}, _('检查更新'));

		this.btnUpgrade = E('button', {
			'class': 'btn cbi-button-action important', 'click': ui.createHandlerFn(this, 'handleUpgrade')
		}, _('下载并升级'));

		this.btnCancel = E('button', {
			'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleCancel'), 'style': 'display:none'
		}, _('取消'));

		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;margin:.5em 0' },
				[ this.btnCheck, this.btnUpgrade, this.btnCancel ])
		]);
	},

	/* ------------------------------------------------------------ 显示刷新 -- */

	refresh: function (st) {
		this.st = st || this.st || {};
		var ck = this.ck || {};

		var upd = ck.update_available;
		/* 上游 revision 相同却提示有更新，看着像矛盾，其实是最常见的一种情况：
		   pinned 构建每次都编同一个 upstream revision，真正在动的是构建仓自己
		   的提交（overlay/配置/补丁）。这里明说，省得被当成误报。 */
		var sameRev = upd && ck.latest_revision ===
			(st.current_revision || ck.current_revision);
		var badge;
		if (!ck.ok)
			badge = this.badge(false, ck.message || _('未知'));
		else if (upd)
			badge = this.badge(false, sameRev
				? _('有新版本（上游版本相同，镜像内容已更新）')
				: _('有新版本'));
		else
			badge = this.badge(true, _('已是最新'));

		dom.content(this.nodeVersions, E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('版本')),
			E('table', { 'class': 'table' }, [
				this.row(_('当前版本'), shortRev(st.current_revision || ck.current_revision)),
				this.row(_('当前发布号'), st.display_revision),
				this.row(_('当前镜像构建于'), ck.installed_built),
				this.row(_('最新版本'), shortRev(ck.latest_revision) + ' '),
				this.row(_('内核'), ck.latest_kernel),
				this.row(_('发布时间'), ck.latest_date),
				/* 版本判定的依据。摆出来是为了让"已是最新"可以被核对：只看
				   revision 会漏掉"同一上游版本的新镜像"，那正是升级页存在的
				   意义。 */
				this.row(_('构建提交'), shortRev(ck.installed_build_commit) + ' → ' +
					shortRev(ck.latest_build_commit)),
				this.row(_('镜像大小'), fmtBytes(ck.latest_size)),
				this.row(_('状态'), E('span', {}, [ badge ]))
			])
		]));

		/* 已经下载好就不要再走一次下载。 */
		if (this.btnUpgrade)
			this.btnUpgrade.firstChild.data =
				(st.state === 'ready') ? _('立即刷写') : _('下载并升级');

		if (this.btnCancel)
			this.btnCancel.style.display =
				(st.state === 'downloading' || st.state === 'verifying') ? '' : 'none';
	},

	renderProgress_: function (st) {
		st = st || {};
		var pct = Math.max(0, Math.min(100, parseInt(st.percent || 0, 10)));
		var label = st.message || _('就绪');

		var html = [
			E('h3', {}, _('进度')),
			E('div', { 'style': 'margin:.4em 0' }, label),
			E('div', { 'style': 'background:#e6e6e6;border-radius:.35rem;height:1.1em;overflow:hidden' },
				E('div', {
					'style': 'height:100%;width:' + pct + '%;background:#3f8f4f;transition:width .4s'
				})),
			E('div', { 'style': 'margin:.4em 0;color:#666;font-size:.9em' },
				st.total ? (fmtBytes(st.received) + ' / ' + fmtBytes(st.total) + '  (' + pct + '%)') : '')
		];

		if (st.state === 'ready' && st.sha256)
			html.push(E('div', { 'style': 'font-size:.85em;color:#666;word-break:break-all' },
				'sha256 ' + st.sha256));

		dom.content(this.nodeProgress, E('div', { 'class': 'cbi-section' }, html));
	},

	message_: function (text, isError) {
		dom.content(this.nodeMessage, E('span', {
			'style': isError ? 'color:#8a2b21' : 'color:#2b6b3a'
		}, text || ''));
	},

	/* -------------------------------------------------------------- 轮询 -- */

	stopPolling: function () {
		if (this.timer) {
			window.clearInterval(this.timer);
			this.timer = null;
		}
	},

	startPolling: function () {
		var self = this;

		self.stopPolling();
		self.timer = window.setInterval(function () {
			callStatus().then(function (st) {
				self.refresh(st);
				self.renderProgress_(st);

				if (st.state === 'downloading' || st.state === 'verifying')
					return;

				/* 终态：停轮询，并按结果决定下一步。 */
				self.stopPolling();

				if (st.state === 'ready') {
					self.message_(_('下载完成并通过 sha256 校验。'));
					self.confirmFlash(st);
				}
				else if (st.state === 'error') {
					self.message_(st.message || _('失败'), true);
					ui.addNotification(null, E('p', {}, st.message || _('升级下载失败')));
				}
			}).catch(function () { /* 设备可能正在重启，忽略 */ });
		}, 2000);
	},

	/* -------------------------------------------------------------- 动作 -- */

	handleCheck: function () {
		var self = this;

		self.message_(_('正在检查更新…'));
		return callCheck().then(function (ck) {
			self.ck = ck || {};
			return callStatus();
		}).then(function (st) {
			self.refresh(st);
			self.renderProgress_(st);
			if (!self.ck.ok)
				self.message_(self.ck.message || _('检查失败'), true);
			else
				self.message_(self.ck.update_available
					? _('发现新版本。点「下载并升级」继续。')
					: _('当前已是最新版本。'));
		});
	},

	handleUpgrade: function () {
		var self = this;

		/* 已经下载校验过 → 直接进入确认刷写。 */
		if (this.st.state === 'ready')
			return this.confirmFlash(this.st);

		var url = this.inputUrl ? this.inputUrl.value : '';

		this.message_(_('正在开始下载…'));
		return callStart(url).then(function (r) {
			if (!r || r.ok != 1)
				throw new Error((r && r.message) || _('无法开始下载'));
			self.message_(r.message || _('正在下载…'));
			self.startPolling();
		}).catch(function (e) {
			self.message_(e.message || _('无法开始下载'), true);
		});
	},

	handleCancel: function () {
		var self = this;
		return callCancel().then(function () {
			self.stopPolling();
			self.message_(_('已取消'));
			return callStatus();
		}).then(function (st) {
			self.refresh(st);
			self.renderProgress_(st);
		});
	},

	confirmFlash: function (st) {
		var self = this;

		ui.showModal(_('确认升级'), [
			E('p', {}, _('镜像已下载并通过 sha256 校验，即将写入 flash 并重启设备。')),
			E('ul', {}, [
				E('li', {}, _('配置会被保留（/etc/config、AdGuard Home 屏蔽列表、PassWall 节点）。')),
				E('li', {}, _('设备同时是网络出口，升级期间全屋会断网约 1 分钟。')),
				E('li', {}, _('写入过程中请勿断电。')),
				E('li', {}, _('如果新固件起不来，按住 reset 上电可进入 U-Boot 救援页面 192.168.9.1。'))
			]),
			E('div', { 'style': 'text-align:right;margin-top:1em' }, [
				E('button', {
					'class': 'btn', 'click': ui.hideModal
				}, _('取消')),
				' ',
				E('button', {
					'class': 'btn cbi-button-negative important',
					'click': ui.createHandlerFn(self, 'doFlash')
				}, _('刷写并重启'))
			])
		]);
	},

	doFlash: function () {
		var self = this;

		ui.hideModal();
		ui.showModal(_('正在刷写'), [
			E('p', { 'class': 'spinning' },
				_('正在写入 flash 并重启，请勿断电。约 1 分钟后本页会自动重连；' +
				  '若没有自动跳转，请手动刷新页面。'))
		]);

		return callFlash().then(function (r) {
			if (!r || r.ok != 1)
				throw new Error((r && r.message) || _('刷写未启动'));

			/* 尽力自动重连；失败也不影响——设备重启后刷新即可。 */
			window.setTimeout(function () {
				try {
					ui.awaitReconnect(window.location.host, '192.168.88.1', '192.168.88.1');
				} catch (e) {
					try { window.location.reload(); } catch (e2) {}
				}
			}, 45000);
		}).catch(function (e) {
			ui.hideModal();
			self.message_(e.message || _('刷写未启动'), true);
			ui.addNotification(null, E('p', {}, e.message || _('刷写未启动')));
		});
	},

	destroy: function () {
		this.stopPolling();
	}
});
