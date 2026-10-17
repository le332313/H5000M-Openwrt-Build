# CI/CD 规范与门禁（GitHub Actions 治理 / 供应链安全）

本文是**已生效门禁**的说明，不是提案。每一项都指向仓库里真实存在的文件与
设置，并解释它在这个 H5000M 固件项目里解决什么问题。

一个前提：本项目产出的是**要刷进路由器的固件**和**设备 `apk add` 的软件源**。
威胁模型与普通 Web 项目不同，三条真实风险决定了下面所有取舍：

1. 构建作业持有 `contents: write` 与**签名密钥**，同时下载约 150 个上游
   tarball 和十几个第三方 git 树。被投毒的 action 或上游会继承这一切。
2. 发布出去的 apk 索引是设备信任的根。若它可被替换，所有装包设备都被接管。
3. workflow 自身是攻击面（模板注入、凭据持久化、权限过宽）。

---

## 一、代码规范与提交规约

| 术语 | 落地位置 | 在本项目的作用 |
| --- | --- | --- |
| **Conventional Commits** | `commitlint.config.mjs` | 提交日志在本项目**就是发布日志**：Release Please 由它推导版本号与 changelog，`build.yml` 又用 tag 命名固件。类型写错 → release note 写错。 |
| **Commitlint** | `commitlint.config.mjs` + `checks.yml::commitlint` | CI 门禁（Required Check）。含本项目 **17 个 scope 枚举**（`kmods`/`ebpf`/`fullcone`/`wwan`/`wifi`/`fan`/`accel` 等），scope 自由填写会在一周内漂移、失去可检索性。校验 PR 的**整个提交区间**而非仅 HEAD。 |
| **Release Please** | `.github/workflows/release-please.yml` | 维护 release PR + `CHANGELOG.md`，合并后才打 tag。`release-type: simple`，因为产物不是 npm/pypi 包；tag 与 `build.yml` 的 `v*` 触发对齐。 |
| **pre-commit** | `.pre-commit-config.yaml` | 6 个 hook，**每个都镜像一条已存在的 CI 检查**。规则：CI 不跑的 hook 不加——否则等于训练人绕过 CI。含 `check-added-large-files`（防固件/构建树被提交，本仓库必须保持纯源码）。 |
| **actionlint** | pre-commit hook + 本地 | 校验 GitHub 特有 schema。本轮它抓出了 **3 个真实缺陷**：`workflow_dispatch` 输入超 10 个上限、`uses` 与 `run` 冲突、注释吞掉 `- name:` 导致解析失败——这些 PyYAML 全部看不到。 |
| **zizmor** | `.github/zizmor.yml` + `security.yml::zizmor` | 专门审计 workflow 自身：未钉 action、**模板注入**、凭据持久化、权限过宽、已知 pwn-request。SARIF 上报 code scanning。按版本 pip 安装而非用浮动 action——审计器自身也要守同样的供应链纪律。 |

## 二、质量门禁（Ruleset 已真实生效）

Ruleset `master-protection`，**id `23816928`**，`current_user_can_bypass: never`。

| 规则 | 配置 | 为什么 |
| --- | --- | --- |
| **Required Status Checks** | 5 条，`strict`（要求分支最新） | 见下表。**刻意不含** `Build firmware`：完整固件构建 2–3 小时，不适合每个 PR。 |
| **Required Linear History** | 启用 | 固件按 commit 溯源，线性历史让 `git bisect` 与发布对应关系成立。 |
| **Pull Request** | 必需、必须解决全部 review thread、仅允许 squash/rebase | 保证每个进入 master 的提交都过了门禁。 |
| **Deletion / Non-fast-forward** | 禁止 | 防止误删 master 或强推覆盖历史。 |
| **Required Signatures** | ✅ 已启用 | 本机已生成专用 SSH 签名密钥并注册到 GitHub（实测提交 `verified=true, reason=valid`）。**合并方式收窄为 squash-only**——见下方说明。 |

五个 Required Status Checks 及其归属：

| Check | 来源 | 耗时 |
| --- | --- | --- |
| Repository and host checks | `checks.yml::check` | 分钟级 |
| Conventional Commits | `checks.yml::commitlint` | 分钟级 |
| Configuration coverage | `coverage.yml::coverage` | ~4 分钟 |
| Workflow static analysis (zizmor) | `security.yml::zizmor` | 分钟级 |
| Dependency review | `security.yml::dependency-review` | 分钟级 |

> 注意：一个 Ruleset 只能要求 **PR 上真的会跑**的检查。这三个 workflow 原先
> 没有 `pull_request` 触发器，导致 Required Checks 永不可能通过、PR 永久
> `blocked`——这是本轮修掉的真实缺陷（`checks.yml`/`coverage.yml` 已补）。

| 术语 | 落地 | 作用 |
| --- | --- | --- |
| **Rulesets** | API 创建，id 23816928 | 比旧 Branch Protection 更强、可导出、可审计，且能设 bypass 名单。 |
| **Merge Queue** | 未启用（单人仓库） | 多人协作时它保证"PR 通过检查"与"合并后 master 仍通过"一致。单维护者场景收益低于复杂度，故暂缓；Ruleset 的 `strict` 已覆盖主要风险。 |
| **CODEOWNERS** | `.github/CODEOWNERS` | 标注**决定"什么被签进固件"的路径**：`/.github/`、`/configs/`、`/patches/`、fullcone 四层补丁、`local-packages/`（设备上以 root 运行的脚本）。 |
| **Concurrency Groups** | 5 个 workflow | 防重复运行互相抢 ghcr.io 缓存 tag 与 Release。`build` 在 **tag 上不取消**（release 必须跑完），其余按 ref 取消旧运行。 |

## 三、供应链安全

| 术语 | 落地 | 在本项目的作用 |
| --- | --- | --- |
| **Least Privilege Permissions** | 顶层 `contents: read`，按 job 放宽 | **本轮价值最高的改动**：`build.yml` 顶层原为 `contents: write`，意味着每个 job、每个第三方 action 都能推 master。现仅 `build` job 可写（发 Release），`publish-apk-repo` 仅 Pages。 |
| **OIDC** | attestation / Scorecard 用 `id-token: write` | 签发证明与发布 Scorecard 结果**无需长期密钥**——没有可泄漏、可轮换的签名 secret。 |
| **Dependency Review** | `security.yml::dependency-review` | PR 引入 high 及以上漏洞依赖即失败。带 **Dependency Graph 前置探测**：未启用时明确告警并跳过，启用后自动生效（刻意不用 `continue-on-error`，否则会连真实漏洞一起吞掉）。 |
| **CodeQL** | `security.yml::codeql` | `actions` + `javascript-typescript` 双语言矩阵，`security-extended`。产物在路由器上以 root 运行，值得更严格的查询集。 |
| **Secret Scanning** | 仓库已启用 | provider patterns + **push protection** 均已开启（实测确认），密钥在推送时就被拦下。 |
| **OpenSSF Scorecard** | `security.yml::scorecard` | 独立第三方视角检查仓库卫生（危险 workflow、未钉 action、分支保护）。仅默认分支运行，结果经 OIDC 发布。 |
| **SLSA / Artifact Attestations** | `build.yml::Attest the firmware and the apk repository` | 为 `*squashfs-sysupgrade.bin` 与 `apk-repo/<abi>/packages.adb`（以及站点根的兼容副本）签发 **build provenance**，任何人事后可验证"这个索引确实由该 commit 的该次运行产出"。 |
| **SBOM** | `security.yml::attest` | 生成 SPDX SBOM 并随证明一起签发、作为 artifact 保留 90 天。 |
| **Action Pinning** | 全部 workflow | **16 个 action 全部钉到 commit SHA**（tag 仅作注释）。已用 API 逐个核验 SHA 可解析回自身。Dependabot 每周分组升级——**SHA 钉定的可持续性依赖它**，否则会变成会腐烂的快照。 |

## 四、复用与编排

| 术语 | 落地 | 选择理由 |
| --- | --- | --- |
| **Reusable Workflows** | `.github/workflows/reusable-script-test.yml`（`workflow_call`）+ `build.yml::script-test` 调用 | 需要**独立 job/runner/权限边界**的单元。用真实 aarch64 `uci`（qemu）跑首启脚本——本仓库已经因此类 bug 被咬过一次（值存成 `'0'` 而非 `0`：配置看似正确、射频始终不启）。调用方**不传 secrets**（`secrets: inherit` 会无谓扩大暴露面）。 |
| **Composite Actions** | `.github/actions/verify-repo/action.yml` | 只需**步骤序列**、不需要独立 runner 的单元，复用 apk 仓库校验。用 reusable workflow 会为 5 秒的检查白起一个 runner。 |
| **Matrix Strategy** | `security.yml::codeql`（`fail-fast: false`） | 两种语言各自独立分析；`fail-fast: false` 保证一个失败不掩盖另一个。 |

## 五、文件结构

```
.github/
├── CODEOWNERS                       # 敏感路径的复核归属
├── dependabot.yml                   # 每周分组升级 actions（含 SHA 更新）
├── zizmor.yml                       # workflow 审计器配置与例外说明
├── actions/
│   └── verify-repo/action.yml       # Composite Action：apk 仓库校验
└── workflows/
    ├── build.yml                    # 固件构建 + 发布 + 证明（3 job）
    ├── checks.yml                   # 仓库/主机检查 + commitlint（Required）
    ├── coverage.yml                 # ENABLE_* 配置覆盖矩阵（Required）
    ├── security.yml                 # zizmor / CodeQL / DepReview / Scorecard / attest
    ├── release-please.yml           # release PR + changelog + tag
    └── reusable-script-test.yml     # Reusable Workflow（workflow_call）
.pre-commit-config.yaml              # 本地钩子（全部镜像 CI 检查）
commitlint.config.mjs                # Conventional Commits 规则与 scope 枚举
docs/ci.md                            # 本文
```

## 六、Signed Commits（已启用）

本机已生成专用 SSH 签名密钥并注册到 GitHub，`required_signatures` 已生效。

```
密钥      ~/.ssh/id_ed25519_signing（无口令，供自动化使用）
GitHub id 1194013
配置      gpg.format=ssh  user.signingkey=<pub>  commit.gpgsign=true
实测      verified=true, reason=valid
```

### 为什么合并方式必须是 squash-only

squash 合并时 GitHub 用 **web-flow 密钥重新签名**合并结果，所以 master 上的
提交天然是 verified 的；而 **rebase 会把 PR 内的提交原样落到 master**——若其中
有未验证的提交（例如别人在网页上编辑产生的），master 就会混入未签名历史。
因此 Ruleset 的 `allowed_merge_methods` 限定为 `["squash"]`。

### 换机器或密钥失效时

```sh
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519_signing.pub
git config commit.gpgsign true
git config tag.gpgsign true
gh auth refresh -h github.com -s admin:ssh_signing_key
gh ssh-key add ~/.ssh/id_ed25519_signing.pub --type signing --title "H5000M build machine"
```

验证：`git log --format='%h %G?' -1` 应为 `G`；推送到 GitHub 后
`verified` 应为 `true`。

## 七、本地开发

```sh
pipx install pre-commit
pre-commit install --install-hooks
pre-commit install --hook-type commit-msg

./actionlint .github/workflows/*.yml   # GitHub Actions schema 校验
pre-commit run --all-files             # 全部钩子
```

---

## 八、签名提交状态

本机已生成专用 SSH 签名密钥（`~/.ssh/id_ed25519_signing`），并配置：

```
gpg.format         = ssh
user.signingkey    = ~/.ssh/id_ed25519_signing.pub
commit.gpgsign     = true
tag.gpgsign        = true
```

本地验证为 `G`（good signature）。**公钥尚未上传到 GitHub**，因此远端提交
暂时不会显示 Verified 徽章；上传后 `required_signatures` 规则即可启用。

上传（需要 `admin:ssh_signing_key` scope 的 token）：

```sh
gh auth refresh -h github.com -s admin:ssh_signing_key
gh api --method POST user/ssh-signing-keys \
  -f title="H5000M build machine (commit signing)" \
  -f key="$(cat ~/.ssh/id_ed25519_signing.pub)"
```
