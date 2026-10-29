# kitty Agent 状态监听对齐 herdr 技术方案

本文基于本机 herdr 0.9.5 实物证据（磁盘 manifest、二进制符号、运行中 server、CHANGELOG、live CLI 输出），对比 kitty 当前实现，给出对齐方案。**本文不含代码改动。**

## 结论

kitty 当前的状态监听与 herdr 的差异不是"规则写得不够多"，而是**架构缺三层**：

1. **没有 region（区域）概念** —— herdr 每条规则只在一个命名区域内匹配；kitty 在"末 12 行小写全文"里做全局子串匹配。
2. **没有优先级裁决** —— herdr 是「所有规则求交集 → 取 priority 最高者」；kitty 是 Python `if` 短路，第一个命中即返回，顺序即优先级，且顺序与 herdr 相反。
3. **没有 authority 仲裁与 skip 语义** —— herdr 区分 full-lifecycle hook 权威 / 屏幕回退，且有 `skip_state_update` 保持前态；kitty 让 OSC 7501 无条件覆盖屏幕，且没有"保持前态"这个状态。

此外有 4 个会直接导致可见错态的实现 bug（§3）。要效果一致，必须按 herdr 的数据驱动模型重建，而不是继续加 `if`。

## 1. herdr 实际实现（已验证）

### 1.1 数据位置与分发

| 事实 | 证据 |
|---|---|
| 规则是 TOML manifest，每 agent 一个文件 | `~/.local/state/herdr/agent-detection/remote/*.toml`，22 个 |
| 二进制内置 21 份同格式 manifest，remote 可覆盖 | `strings herdr` 得 `id = "claude"` … 共 21 个 id |
| 分发目录 | 二进制内 `https://herdr.dev/agent-detection/index.toml`，env `HERDR_AGENT_DETECTION_MANIFEST_CATALOG_URL` |
| 本地缓存状态 | `status.toml`：`last_check_unix` / 每 agent `cached_version`、`last_result` |
| 引擎版本门禁 | manifest 字段 `min_engine_version`（实测取值 1/2/3）；二进制含报错 `: uses top_non_empty_lines but min_engine_version is below ` |
| 非法 region 会被拒 | 二进制含 ` uses invalid region: ` |
| 未知 agent 的 remote manifest 被丢弃 | server log `skipping unknown remote manifest agent agent="qwen"` |
| 许可证 | Apache-2.0（`.brew/herdr.rb`、LICENSE）→ 与 kitty GPLv3 单向兼容，可带署名移植 |

### 1.2 Manifest DSL

根字段：`id`、`version`、`min_engine_version`、`updated_at`、`aliases`、`[[rules]]`。

规则字段（二进制 `ManifestRule` 结构体符号确认全集）：
`state`、`priority`、`region`、`visible_idle`、`visible_blocker`、`visible_working`、`skip_state_update`，外加 gate 字段。

gate 字段（二进制 `ManifestGate` 符号确认全集）：`all`、`any`、`not`、`contains`、`regex`、`line_regex`。

组合语义：

| 构造 | 语义 |
|---|---|
| `contains = [a, b]` | **AND**，全部子串都要出现 |
| `regex = [p1, p2]` | **OR**，整区域匹配，多行需显式 `(?m)`/`(?s)` |
| `line_regex = [p1, p2]` | **OR**，逐行匹配，`^`/`$` 绑定行边界 |
| `any = [g1, g2]` | OR |
| `all = [g1, g2]` | AND |
| `not = [g1, g2]` | NOR，任一命中即整条规则失败 |
| 同一规则上的多个同级字段 | 隐式 **AND** |

gate 可无限嵌套（codex `trust_directory` 深 3 层）。

**大小写（实机推翻了此前推断）**：`contains` 是**大小写不敏感**的。此前从 manifest 字面混用 `"Action Required"` 与 `"esc to cancel"` 推断为大小写敏感，实测证伪 —— 用一个假 `claude` 进程打印真实审批提示文本：

```
$ herdr agent explain wR:p1
agent: claude
state: blocked
rule: generic_permission_prompt (region=after_last_horizontal_rule priority=840)
evidence: "Do you want to proceed?\n❯ 1. Yes\n  2. No\nesc to cancel\n"
```

规则里写的是小写 `"do you want to proceed?"`，屏幕上是首字母大写的 `"Do you want to proceed?"`，仍然命中。若按字面比较，Claude 的审批提示会被判成 idle —— 这是个会直接导致错态的差异。regex 则保持大小写敏感，需要忽略时显式写 `(?i)`。

### 1.3 region 全集（必须全部实现）

二进制与 manifest 双向确认，共 12 种形态：

```
osc_title
osc_progress
whole_recent
whole_recent_without_current_prompt_marker
prompt_box_body
last_non_empty_above_prompt_box
after_last_horizontal_rule
after_last_prompt_marker
before_current_prompt_marker
top_non_empty_lines(N)        # 实测 N=20
bottom_non_empty_lines(N)     # 实测 N ∈ {1,2,3,4,5,6,8,12,14,16,20,24,30}
bottom_lines                  # 二进制符号中存在，现网 manifest 未使用
```

分三类：

- **缓冲区窗口**：`bottom_non_empty_lines(N)` / `top_non_empty_lines(N)` / `bottom_lines` / `whole_recent`。注意是**非空行计数**，不是物理行计数。
- **结构区域**：`prompt_box_body`（输入框内部）、`last_non_empty_above_prompt_box`、`after_last_horizontal_rule`（最后一条 `───` 之后）、`after_last_prompt_marker` / `before_current_prompt_marker` / `whole_recent_without_current_prompt_marker`（围绕当前 prompt 标记切分）。
- **转义序列区域**：`osc_title`（OSC 0/1/2 标题）、`osc_progress`（OSC 9;4 中 `9;` 之后的**原始载荷**，如 `4;1;-1`、`4;0;0`、`4;3`）。

检测读的缓冲区在 CLI 里是一等概念：`herdr pane read --source visible|recent|recent-unwrapped|detection`，内置文档原文：

> `detection`: the plain-text bottom-buffer snapshot used for agent detection.
> `visible`: the currently rendered viewport.

即**检测快照独立于用户视口**，用户回滚 scrollback 不影响检测。CHANGELOG line 1125 亦印证：「Agent state detection is now more reliable when panes are scrolled back」。

### 1.4 状态与裁决

状态集合 5 个：`idle working blocked done unknown`（CLI `agent wait --until` 枚举）。其中 manifest 只能产出 `idle/working/blocked/unknown`；**`done` 只由生命周期层产生，屏幕规则永不断言 done**。

裁决顺序（实测 + 符号）：

1. 前台进程识别出 agent 身份（进程身份只回答"是谁"，不回答"在干什么"）。
2. 若该 agent 装有 **full-lifecycle** 集成 → hook 权威，跳过屏幕检测。实测 live 输出：
   ```
   $ herdr agent explain wV:p1
   agent: omp
   state: working
   manifest: none unknown
   rule: none
   screen_detection_skip_reason: full_lifecycle_hook_authority
   ```
   二进制中该字段枚举值即 `full_lifecycle_hook_authority`。
3. 否则走 manifest：对全部规则求值，取 priority 最高的命中者。
4. 命中规则带 `skip_state_update` → **保持前态**，不写入。
5. 无规则命中 → `default_known_agent_idle_fallback`（二进制字符串）。

关键细节：**hook 权威不是无条件的**。full-lifecycle 白名单很小（CHANGELOG line 712：Pi、OMP、OpenCode、Kilo、Hermes、自定义 socket 可报状态；Claude、Codex、Copilot、Droid、Kimi、Qoder 只报 session 身份，状态仍由屏幕检测）。且可见 UI 可以推翻过期 hook 状态（line 829：Codex plan-mode 问题提示覆盖 stale integration `working`；Claude 取消后 idle prompt 回归时清除 stale hook `working`；line 391：Hermes 因 hook 不完整改回屏幕检测）。

`visible_*` 标记的作用：标注该命中属于"可见证据"。manifest 注释原文「Visible activity outranks idle OSC signals: disabling title updates can…」—— 可见活动证据压过 OSC idle 信号。

### 1.5 稳定化

| 项 | 值 | 证据 |
|---|---|---|
| OMP 集成 idle 去抖 | 默认 **250ms**，`HERDR_OMP_IDLE_DEBOUNCE_MS` | `~/.omp/agent/extensions/herdr-omp-agent-state.ts:75` |
| 恢复 agent 启动间隔 | 100ms/agent，`[session] startup_per_agent_delay_ms` | CHANGELOG `[0.9.4]` |
| `agent prompt --wait` 停滞判定 | 5s 无状态变化 → `agent_prompt_stalled` | CHANGELOG `[0.7.5]` |
| 事件 settle / 串行化 | Pi 用 settled events 防止 turn 中途发 idle；OpenCode 报告串行化防乱序 | CHANGELOG line 444/446 |
| 短时抖动平滑 | 「smoothing short busy/idle flicker during screen updates」 | CHANGELOG line 1337 |
| 启动期信号保持 | 只在启动时设一次 title/progress 的 agent，首次识别后不丢该信号 | CHANGELOG line 222（#3326）|
| idle pane 降频轮询 | 有，未给具体值 | CHANGELOG line 637/798 |

事件通道：`pane_agent_detected`（身份变化）、`pane_agent_status_changed`（状态变化），带 `state_label`、`display_agent`。身份变化在 server log 以 INFO 落盘：

```
2026-08-11T02:48:00.894498Z INFO herdr::pane: agent changed pane=2 previous_agent=None agent=Some(Codex) process=codex pgid=Some(66885)
```

逐 tick 的 idle/working 转换在默认日志级别不落盘，故**无法从日志反推轮询周期**；具体毫秒常量是编译期立即数，`strings` 不可见。规则防误判靠 manifest 里的 `not` gate 而非时间窗（§1.6）。

> 说明：现有 `docs/herdr-agent-state-research.md` 中列出的 `PendingIdleConfirmation` 三次 100ms 确认、700ms 上限、`STABLE_VISIBLE_SIGNAL_REFRESH` 800ms、`AGENT_STARTUP_GRACE_WINDOW` 3s 等常量，在本机可达的全部实物证据中**均未能证实**。本方案不依赖这些数值。

### 1.6 防误判手法（manifest 内，可直接复用）

- **成对要求**：单个短语不足以断言。claude `live_blocked_form` 要求 `esc to cancel` 同时出现 confirm 提示、或 select 提示 + 导航提示，因为 `esc to cancel` 在 working 期间也会出现。muse 注释说明「任何单个短语都可能作为普通助手文本出现在回合结束后」。
- **结构锚定**：claude `background_mcp_task_working` 要求活动摘要在第 0 列、续行缩进，防止用户输入的文本冒充信号。
- **过期标记排除**：codex `weak_blocker` 的 `not` 排除「`›` + braille 的 stale prompt」，注释「A later response marker makes that prompt stale」。
- **终态排除**：codex `screen_working_fallback` 的 `not` 排除 `Reconnect failed …`，因为失败重连仍保留计时器但已不在工作。
- **启动画面排除**：grok 的 working 规则锚在 `[stop]` 芯片而非裸 spinner，因为启动 splash 用 braille 画 logo。
- **idle 空 prompt 排除**：claude `legacy_no_prompt_blocker` 的 `not = [regex '(?m)^\s*❯\s*$']`，裸 `❯` 是 idle 不是 blocked。
- **后台任务不算 working**：grok/agy/claude 注释一致（#1217、#4735）—— 回到 prompt 后仍有后台 subagent 运行，状态仍是 idle。
- **overlay 保持前态**：transcript viewer、model picker、菜单叠层用 `skip_state_update`，避免用户翻阅记录时把 working 翻成 idle。

优先级分带（实测范围 −10 … 1400）：

| 带 | 内容 |
|---|---|
| 1200–1400 | OSC 派生的 blocked / progress（最权威、与语言无关）|
| 1000–1190 | OSC title spinner、transcript skip、强可见 blocker |
| 900–990 | 可见 blocker 面板、主 working 状态行 |
| 840–890 | 次级审批、OSC idle、prompt box idle |
| 500–800 | 回退 working/idle 启发式、weak blocker |
| 100–400 | 遗留 footer 提示、简单 spinner |
| ≤0 | 兜底（letta `no_live_state_evidence`=0，cline `default_cline_working`=−10）|

注意同一 agent 内 blocker 常**高于** title working：grok 注释说明 `Action Required` 前缀在未聚焦时会闪烁，可能被采样错过，故可见 blocker 规则优先级要压过 title spinner。

## 2. kitty 现状

全部实现集中在 `kitty/agents.py`（238 行）：

| 环节 | 位置 | 做法 |
|---|---|---|
| 身份识别 | `agents.py:89` `detect_agent` | 遍历前台进程 cmdline[0]（解释器则看 cmdline[1]），查 `AGENT_EXECUTABLES` 字典 |
| 屏幕判定 | `agents.py:98` `screen_state_for_agent` | 取 `screen_text.splitlines()[-12:]` 小写后拼成 `tail`，一串 `if` 子串/正则判断 |
| 裁决 | `agents.py:135` `state_from_signals` | OSC 7501 记录 → 屏幕 → `at_prompt` → 硬编码 agent 默认值 |
| 缓存与刷新 | `agents.py:176` `AgentTracker` | 按 window 缓存 snapshot + 上次 screen_text，脏集合合并 |
| 触发 | `boss.py` / `window.py` | 1.0s 定时器全量刷新；focus 变化、program_status 变化、cmd start/stop 打脏标记 |
| 快照来源 | `agents.py:197` | `window.as_text()` |

身份覆盖对比（kitty 23 项 vs herdr 22 项）：

- herdr 有 kitty 无：`agy`（kitty 用 `antigravity` 命名）、`maki`、`qodercli`（kitty 用 `qoder`）
- kitty 有 herdr 无：`mastracode`、`omp`（二者在 herdr 中通过 integration 走 hook 通道，`herdr integration status` 可见 `mastracode`、`omp` 条目，无屏幕 manifest）

命名需统一到 herdr 的 manifest `id`，并用 `aliases` 承载 `antigravity`/`qoder`/`cursor-agent` 等别名，否则 manifest 无法按 id 查表。

## 3. 差异与缺陷（按影响排序）

### 3.1 架构缺失

| # | herdr | kitty 现状 | 后果 |
|---|---|---|---|
| A | 12 种 region | 仅"末 12 行"一种 | 无法表达 `prompt_box_body`、`after_last_horizontal_rule`、`before_current_prompt_marker` 等，claude/codex 的主力规则全部无法移植 |
| B | 全规则求值 + priority 取最大 | `if` 短路，顺序即优先级 | kitty 把 blocked 判断放在 working 之前（`agents.py:100`），顺序恰与 herdr 的「可见 blocker > title working」一致属巧合；但一旦规则增多，无优先级就无法稳定裁决 |
| C | `skip_state_update` 保持前态 | 无此概念 | 用户在 claude 里翻 transcript、开 model picker 时，状态会被误判为 idle |
| D | hook 权威 + 可被可见 UI 推翻 | OSC 7501 无条件最高优先 | 过期的 `working` 记录会一直压住真实的 idle/blocked 屏幕证据 |
| E | `done` 仅来自生命周期层 | 把 OSC 的 `error`/`done` 都映射成 `done` | 语义尚可，但 `error` 丢失（herdr 无 error 态，kitty 可保留，需明确这是 kitty 扩展）|

### 3.2 可见错态 bug

| # | 位置 | 问题 | herdr 的做法 |
|---|---|---|---|
| 1 | `agents.py:99` `splitlines()[-12:]` | 取**物理末 12 行**。agent TUI 底部常有空行填充，末 12 行可能几乎全空，footer 被挤出窗口 → 漏判 | `bottom_non_empty_lines(N)` 数**非空行** |
| 2 | `agents.py:197` `window.as_text()` | `as_text` 走 `get_visual_line`（`screen.c:5281`），**受 `scrolled_by` 影响**。用户回滚 scrollback 时读到的是历史内容 → 误判 | 独立的 `detection` 快照，不随视口；CHANGELOG line 1125 专门修过此问题 |
| 3 | `agents.py:99` 全文 `.lower()` + 子串 | 不分区域的全局 `in` 让用户输入的文本可冒充信号；且 regex 在小写化后的文本上跑，大小写敏感的模式无法表达 | 按区域匹配；`contains` 大小写不敏感（见 §1.2），regex 在**原文**上跑并保持大小写敏感；`not` gate 排除冒充 |
| 4 | `agents.py:155-158` | `at_prompt` 为假时对 `opencode`/`omp` 直接返回 `working` —— 把"无证据"当成"在工作" | 无证据 → `default_known_agent_idle_fallback`（idle），working 必须有可见标记 |

补充：`agents.py:98` 的 `screen_changed` 参数被 `state_from_signals`/`screen_state_for_agent` 接收但从未使用（`agents.py:140`、`162`）。herdr 也不把"屏幕有变化"当作 working 证据 —— 这一点现状反而是对的，但该参数应删除而非留着误导。

以上 4 项均已在本机构建的 kitty 上实测复现（`kitty +launch`，一次性脚本，已删除）：

**bug 1** —— claude 活动状态行上方有 14 行空白填充时：
```
--- kitty today: raw last 12 physical lines ---
'\n\n\n\n\n\n\n\n\n\n\n'
state  -> None
--- herdr: bottom_non_empty_lines(12) ---
'user: refactor the parser\n✳ Thinking… (12s · esc to interrupt)'
contains working marker -> True
```
kitty 漏判为"无状态"，herdr 的非空行窗口能看到 working 标记。

**bug 2** —— 5 行屏幕写入 10 行输出后回滚 6 行：
```
scrolled_by = 0
  as_text            : 'line6\n\n\nline7\n…\nESC to interrupt'
  as_text_non_visual : 'line6\n\n\nline7\n…\nESC to interrupt'
after scrollback, scrolled_by = 6
  as_text            : 'line0\n\n\nline1\n\n\nline2\n\n\nline3\n\n\nline4'
  as_text_non_visual : 'line6\n\n\nline7\n…\nESC to interrupt'

as_text drifts under scrollback      : True
as_text_non_visual stable            : True
footer still seen by detection       : non_visual= True  as_text= False
```
确认 `as_text` 随 `scrolled_by` 漂移、`as_text_non_visual` 稳定，即 4.2 选 `as_text_non_visual` 正确。

**bug 4** —— 零证据输入（无 OSC 记录、无可见标记、非 shell prompt）：
```
omp       no-evidence -> working
opencode  no-evidence -> working
claude    no-evidence -> idle
```
同一 agent 群体行为不一致，且 `omp`/`opencode` 把"无证据"报成 working。

**缺口 D** —— 过期 OSC 记录压住实时屏幕证据：
```
claude stale-done + live spinner -> done
```
屏幕明确在 working（`✳ Thinking… (3s · esc to interrupt)`），但过期的 `done` 记录胜出。

### 3.3 OSC 通道缺口

`osc_title` 区域：kitty 有 `window.child_title`（`window.py:1650`），可直接供给。

`osc_progress` 区域：**当前无法供给原始载荷**。`window.py:1453` 把 OSC 9;4 载荷 `map(int, ...)` 解析后只留前两个字段喂给 `Progress`。grok 的 `^4;1;-1$`、kiro 的 `^4;3;?$` 这类规则需要**原始字符串**（含第三字段 `-1`）。需在 `Window` 上保留一份原始 `9;4` 载荷字符串（如 `self.last_progress_payload`），不改变现有 `Progress` 行为。

## 4. 目标设计

### 4.1 总体

把 `kitty/agents.py` 拆成三块，数据与引擎分离：

```
kitty/agents.py              身份识别 + 裁决 + AgentTracker（状态机）
kitty/agent_manifest.py      manifest 解析 + region 切分 + gate 求值（纯函数，可单测）
kitty/agent_manifests/*.toml 规则数据，每 agent 一个文件
```

`agent_manifests/` 直接采用 herdr 的 TOML 格式与规则内容（Apache-2.0 → GPLv3 单向兼容，文件头保留来源与署名）。好处：

- 规则是数据，审查/修订不碰 Python；
- 与 herdr 上游格式一致，上游修规则时可直接比对；
- `tomllib` 是 Python 3.11+ 标准库，kitty 要求 `>=3.12`（`pyproject.toml:2`），**无新依赖**。

不做的事：不实现 herdr 的远程 manifest 下载与 `min_engine_version` 门禁。kitty 随版本发布规则文件即可；manifest 里保留 `min_engine_version` 字段仅作兼容性标注。

### 4.2 检测快照（修 bug 2）

新增一个不受视口影响的快照取法。`screen.as_text_non_visual` 走 `get_range_line`（`screen.c:5286`），不读 `scrolled_by`，正是所需语义。

快照结构（一次采集，供所有 region 复用）：

| 字段 | 来源 |
|---|---|
| `lines: tuple[str, ...]` | `as_text_non_visual` 的行序列，**不做小写化** |
| `title` | `window.child_title` |
| `progress_payload` | 新增的原始 OSC 9;4 载荷 |

行数预算：取屏幕行数即可（最大 region 需求 `bottom_non_empty_lines(30)` + 结构区域需要找到最后一条 `───` 和 prompt 标记）。先按"整屏 + 不进 scrollback"实现；若 `top_non_empty_lines(20)` 在高窗口下不够用再评估。

### 4.3 region 实现

| region | 实现 |
|---|---|
| `whole_recent` | 整快照 join |
| `bottom_non_empty_lines(N)` | 自底向上收集 N 个非空行（`strip()` 非空），保持原序 |
| `top_non_empty_lines(N)` | 自顶向下同理 |
| `bottom_lines(N)` | 物理末 N 行（二进制有此符号，现网未用；为格式兼容实现，成本极低）|
| `osc_title` | 快照 `title` |
| `osc_progress` | 快照 `progress_payload` |
| `after_last_horizontal_rule` | 找最后一个"横线行"（`─` 占该行非空字符主体）之后的内容 |
| `prompt_box_body` | 定位输入框：自底向上找框线（`╰`/`└` 底边 → `╭`/`┌` 顶边），取框内行 |
| `last_non_empty_above_prompt_box` | prompt box 顶边之上第一个非空行 |
| `after_last_prompt_marker` / `before_current_prompt_marker` / `whole_recent_without_current_prompt_marker` | 定位当前 prompt 标记行（行首 `›`/`❯`/`>`，按 agent 配置字符集），分别取其后 / 其前 / 剔除该行 |

每个 region 必须返回"是否存在"而非空串：区域不存在（如没有 prompt box）时规则直接不命中，不能退化成"在空串里匹配"。

### 4.4 gate 求值

纯函数递归，对应 `ManifestGate`：

```
contains   : 全部子串 in 区域文本（大小写不敏感，实测确认）
regex      : 任一 re.search 命中（预编译）
line_regex : 任一模式在任一行上 re.search 命中
all/any/not: 递归 AND / OR / NOR
同级字段   : AND
```

正则方言差异需在加载时处理（已实测，Python 3.15.1）：

| Rust `regex` 写法 | Python `re` | 处理 |
|---|---|---|
| `\x{2800}` | 不支持，`bad escape \x` | **必须转换**。`\x{...}` → `chr(int(hex,16))` 后 `re.escape`，braille/半圆字符集匹配正确 |
| `\u{fe0f}` | 不支持，`incomplete escape \u` | **必须转换**（同上）。hermes 的 `⚠`/`⏳`/`✓` 规则用它吸收变体选择符 |
| `\p{Alphabetic}` | 不支持，`bad escape \p` | **必须转换**为 `[^\W\d_]`。实测该类覆盖全部 alphabetic 码点，仅多收 1154 个 No/Nl 类数字符号（如 `²` `½`），对"活动标签里要有字母"这类规则不影响结论。cursor、qodercli 的 spinner 规则用到 |
| `\uXXXX`（4 位，无花括号）| **原生支持** | 无需转换 |
| `\z` | **3.12+ 原生支持，语义与 Rust 一致**（`abc\z` 不匹配 `'abc\n'`）| 无需转换 |
| `(?i)` `(?m)` `(?s)` 内联标志 | 一致 | 无需处理 |
| 回溯引用 / lookaround | Rust `regex` 不支持，故 manifest 中不会出现 | 无需处理 |

转换在加载时做（而非改写 TOML），以保持与上游文件逐字可比对。

### 4.5 裁决（修 A/B/C/D）

```
1. agent = detect_agent(前台进程)        # None → unknown，非 agent 窗口不显示
2. authority = hook_authority(agent)      # 见 4.6
3. 若 authority 为 full-lifecycle 且记录新鲜：
       state = 该记录状态；skip_reason = full_lifecycle_hook_authority
4. 否则：对该 agent 的全部规则求值
       命中集合按 priority 降序，取第一条
       命中条带 skip_state_update → 保持前态
       无命中 → idle（default_known_agent_idle_fallback）
5. 可见证据推翻过期 hook：若 hook 报 working，而命中规则带 visible_blocker 或 visible_idle
       → 采用屏幕结果并清除该 hook 记录
```

第 5 步是 herdr 行为的关键（CHANGELOG line 829 明确此逻辑），也是 kitty 当前缺口 D。

### 4.6 hook 权威范围

kitty 的 OSC 7501 与 herdr 的 socket hook 是等价语义通道，但**不能都当成 full-lifecycle**。白名单是**运行期强制的**，已实测验证：

向 codex（仅身份类）用 hook 通道报 `blocked`：
```
$ herdr pane report-agent wR:p1 --source probe:test --agent codex --state blocked
$ herdr agent explain wR:p1
state: idle
rule: osc_title_idle (region=osc_title priority=100)
evidence: "Count 1 to 40 slowly | tmp"
```
hook 报的 blocked **被直接丢弃**，屏幕结论 idle 保持。同时 `agent list` 里该 pane 的 `screen_detection_skipped` 为 `None`。

对比 omp（full-lifecycle 类）：`screen_detection_skipped=True`、`screen_detection_skip_reason=full_lifecycle_hook_authority`，屏幕检测完全不跑。

| 类别 | agent | kitty 处理 |
|---|---|---|
| full-lifecycle（可报状态并取得权威）| opencode、omp、pi、kilo、hermes、自定义 socket 集成 | OSC 7501 记录优先，跳过屏幕规则 |
| 仅身份（状态必须走屏幕）| claude、codex、copilot、droid、kimi、qoder、cursor、qwen、grok、letta、devin | **即使有 OSC 记录也不赋予权威**，记录仅用于 session 身份 |

**修正**：此前认为"不必硬编码两张表、对所有 agent 统一应用可见证据推翻"即可。实测表明 herdr 的行为更强 —— 仅身份类 agent 的 hook 状态**根本不参与裁决**，而非"参与后被推翻"。kitty 要效果一致，必须显式维护这张白名单（放在 manifest 根字段，如 `state_authority = "full_lifecycle" | "identity_only"`，随规则数据一起版本化）。

这也顺带解释了 §3.2 缺口 D 的现状为何有害：kitty 让任意 OSC 记录无条件胜出，相当于把所有 agent 都当 full-lifecycle。

### 4.7 稳定化

只实现有实证支撑的部分：

| 项 | 方案 |
|---|---|
| working → idle 去抖 | 参照 OMP 集成的 250ms（唯一可证实的去抖常量）：working 转 plain idle（无 `visible_idle` 证据）时延迟确认；带 `visible_idle`/`visible_blocker` 证据的转换立即生效 |
| overlay 保持前态 | `skip_state_update` |
| 启动期信号保持 | title/progress 只在启动设一次的 agent，首次识别时沿用已有 title/payload（kitty 天然满足：title 和 payload 是 Window 上的持久字段，非事件流）|
| 轮询 | 保留现有 1.0s 定时器 + 事件打脏；额外在 `title_changed` 处打脏（OSC title 区域需要），idle 窗口可降频 |

不实现未经证实的 700ms 上限 / 800ms 刷新 / 3s 启动宽限。

## 5. 实施阶段

| 阶段 | 内容 | 验收 |
|---|---|---|
| P1 | `agent_manifest.py`：TOML 加载、Rust→Python 正则转换、gate 求值、全部 12 种 region 切分 | 纯函数单测：每种 region 的边界（区域缺失、非空行计数、框线定位）；gate 的 AND/OR/NOR 与嵌套 |
| P2 | 检测快照改用 `as_text_non_visual`；新增原始 OSC 9;4 载荷字段；`title_changed` 打脏 | 回滚 scrollback 时状态不变（现状会变）|
| P3 | 移植 claude / codex / opencode 三份 manifest（覆盖面最大、规则最复杂，能验证全部 region 与 gate 构造）| 用真实 TUI 截屏文本做表驱动测试，断言命中的 rule id 与 state |
| P4 | 裁决重写：priority 取最大、`skip_state_update`、可见证据推翻 hook、idle 兜底；删除 `screen_changed` 死参数与硬编码 agent 默认 working | 现有 `kitty_tests/agents.py` 的 `test_agent_state_precedence` 需随语义更新（`omp` 无证据应为 idle，不再是 working）|
| P5 | 补齐其余 19 份 manifest；agent id 与 aliases 对齐 herdr 命名 | 每 agent 至少一条 idle / working / blocked 样本断言 |
| P6 | 稳定化：250ms idle 去抖；idle 窗口降频 | working↔idle 抖动不产生可见闪烁 |

每阶段结束跑 `./test.py agents`。P3 起需人工在真实 agent 会话里对照 `herdr agent explain` 的 rule id 交叉验证。

## 6. 风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| region 结构定位不准 | `prompt_box_body`、`after_last_prompt_marker` 依赖各 agent 的框线/标记字符，herdr 的具体实现细节不可见（编译期逻辑） | 以 manifest 注释中描述的 UI 形状为准（claude/agy/qwen 注释对框线与 footer 位置有明确描述）；用真实截屏回归 |
| 规则随 agent 版本失效 | herdr 每周更新 manifest（实测 `version` 到 2026.10.11） | 规则为独立数据文件，更新不涉及代码；接受落后于 herdr 上游 |
| 正则性能 | 每次刷新对多条规则跑正则 | 预编译；manifest 按 agent 分表，单个窗口只跑其 agent 的规则（实测各 manifest 规则数：claude 17、grok 13、qwen/letta 10、codex/hermes 9，22 份共 143 条）；仅脏窗口求值 |
| OSC 载荷改动影响现有 progress | 新增字段而非改解析 | `window.py:1453` 的 `Progress` 路径不动，仅旁路保存原始字符串 |

## 7. 实机交叉验证（herdr 0.9.5 运行期）

用 `herdr agent explain` 取得引擎自身的裁决轨迹，作为 kitty 实现的**参考基准**。完整 idle→working→idle 周期（codex，实时采样）：

```
t=0    state: idle     rule: osc_title_idle     (region=osc_title priority=100)   evidence: "tmp"
t=4s   state: working  rule: osc_title_working  (region=osc_title priority=1050)  evidence: "⠏ ⠏ | tmp"
t=8s   state: working  rule: osc_title_working  (region=osc_title priority=1050)  evidence: "⠏ | tmp"
t=12s  state: working  rule: osc_title_working  (region=osc_title priority=1050)  evidence: "⠋ | tmp"
t=16s  state: idle     rule: osc_title_idle     (region=osc_title priority=100)   evidence: "Count 1 to 40 slowly | tmp"
manifest: remote:…/remote/codex.toml 2026.10.11.1
```

验证到的事实：

1. **输出格式即契约**：`state` / `matched_rule` / `region` / `priority` / `evidence` / `manifest` 六元组，与二进制符号 `matched_rule`、`region_preview`、`manifest_source` 对应。kitty 实现 P3 起可逐条比对。
2. **OSC title 是 codex 的主力信号**：braille spinner 走 `osc_title_working`(1050)，无 spinner 走 `osc_title_idle`(100)。屏幕回退规则 `screen_working_fallback`(500) 在本次采样中从未命中 —— 说明 title 可用时根本不读屏幕。这给 kitty 一个重要的实现优先级：**先把 `osc_title` 区域做对，收益最大**。
3. **检测快照确认为纯文本、保留空行、不含 ANSI、与视口无关**：`--source detection` 实测 63 行中 17 行为空行，`grep -c $'\x1b'` 为 0，且与 `--source visible` 内容一致但语义独立。这证实 §4.2 的快照设计（`as_text_non_visual` + 保留空行 + 不小写化）正确，也再次印证 `bottom_non_empty_lines(N)` 必须数非空行。
4. **prompt box 框线字符已确定**：实测 omp pane 底部为 `╭`(U+256D) `─`(U+2500) `╮`(U+256E) / `╰`(U+2570) `╯`(U+256F)，即 §4.3 的 `prompt_box_body` 可按这组圆角框线定位（claude 同族 UI 一致）。
5. **hook 白名单运行期强制**（见 §4.6 实验）。

操作备注：探测用 pane 已恢复为普通 shell，未留残留进程。

## 8. 遗留不可知项

以下为本机实物证据仍无法回答、需实现期以行为对照方式确定：

- 屏幕检测的具体轮询周期与 idle 降频倍数（编译期常量，未落日志；实测 `explain` 采样间隔 3–4s 均能跟上状态变化，说明周期 ≤1s 量级）。
- `prompt_box_body` 的容错策略（框线字符已确定，但窄 pane 下框线被截断时的行为未知）。
- `after_last_prompt_marker` 的 prompt 标记字符集（codex 实测为 `›` U+203A，其余 agent 需逐个确认）。
- `bottom_lines` 的确切语义（符号存在，现网 22 份 manifest 均未使用；可不实现）。
