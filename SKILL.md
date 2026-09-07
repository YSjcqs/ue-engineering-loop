---
name: ue-engineering-loop
description: >-
  在 UE4/UE5 C++/蓝图工程中执行需求澄清、最小实现、构建验证、bug 修复、证据交付和长任务交接时使用；当环境为 Windows + UE 5.8 + RiderMCP + ModelContextProtocol/AllToolsets + Workbench 时，还可启用 Slate ref 自动化、headless Spec 与 MCP 四通道流程。不覆盖纯美术资产创作、材质表达式调试和非 UE 工程。
description_en: >-
  Use for requirements, minimal implementation, builds, bug fixing, evidence-based validation, and handoff in UE4/UE5 C++ or Blueprint projects. Enable the Slate ref, headless Spec, and four-channel MCP profile only on Windows with UE 5.8, RiderMCP, ModelContextProtocol/AllToolsets, and Workbench. Not for pure art creation, material-expression debugging, or non-UE projects.
version: "1.1.0"
engine_version: "UE4/UE5 core; UE 5.8 automation profile"
min_rider_version: "2025.2 for RiderMCP profile"
last_updated: "2026-09-07"
agent_created: true
---

# ue-engineering-loop — UE 工程闭环与自动化协议

> **优先级：用户显式约束 > 仓库规则 > 本技能默认流程。** 只读任务不得写文件或提交；Git commit 仅在用户明确授权或仓库规则明确要求时执行。某 Gate 不适用于当前任务时，标记 `N/A` 并说明理由，不得静默跳过。
>
> 本技能由两层组成：① UE4/UE5 通用工程闭环；② 仅在能力探测满足条件时启用的 Windows + UE 5.8 + Rider/MCP 自动化配置。工具链条件不满足时保留验证义务，但改走项目已有构建、测试和日志路径。
>
> 它 = 工程闭环方法论（清晰意图 × 可执行计划 × 分层证据 × 经验复利）
> × UE 领域版本化经验（编译 / 运行时 / 进程卫生；高风险结论按 `references/CLAIM_EVIDENCE_REGISTRY.md` 复核）
> × 条件化 Slate 自动化能力（ref 级控件树操作）。
> 违反适用 Gate 的产出一律视为「未完成」。
>
> **文档分层（按需加载）**：本文件只放每次必读的骨架与红线；完整说明、模板、踩坑清单一律在 `references/`。
>
> **★ Quick Start**：先判 profile。通用 core：读取仓库规则 → §1 路由 → state-back → 使用项目现有构建/测试入口 → 按风险完成证据层 → 交接。仅当 Windows + UE5.8 + Rider/MCP 工具链已配置时，额外运行 `scripts/env_health_check.ps1 -ProjectPath <Project>` 并启用 §2.1 的自动化通道。

---

## 0. 效率观（一页读懂本技能）

**效率的本质不是生成速度，而是偏差被发现并纠正的速度。**

- 工程闭环：**Oracle（正确性基线）→ Slice（最小切片）→ Gate（分层验证）→ Evidence（可信交付）**
- 完成的定义 = **可复现证据**，不是模型信心。No-Go、Deferred、Blocked 也是有效进展。
- UE 特殊性：编译成本极高（增量 40~90s，全量可达 1.5h）、运行时正确性无法静态判断——所以强制「先读后写、一次写对、闭环验证」。
- **Rebuild 红线（R8）**：UE 全量重编代价巨大，本技能**禁止自主发起任何 clean/rebuild/全量编译**（§编译纪律）。

**解决的痛点**：①不读代码瞎猜 API；②修 bug 不读日志；③脱离验收标准；④验证手段单层；⑤长任务上下文丢失；⑥引擎自动化通道时序误判；⑦失败后无新证据地「继续」打补丁；⑧Slate 控件在快照里隐形/坐标操作不可靠。

---

## 1. 任务路由（★ 触发后先查这里，别通读全篇）

| 任务类型 / 症状 | 走哪里 |
|---|---|
| 新功能 / 新阶段 / 长任务规划 | §2 骨架 + `references/WORKFLOW_STATE_MACHINE.md` |
| 写任务 Prompt / 合同模板 | `references/PROMPT_CONTRACTS.md` |
| 跨天/换会话/上下文压缩/漂移 | `references/CONTEXT_MANAGEMENT.md` |
| 验证设计（跑 Spec / Python / 证据阶梯） | §2.4 + `references/QA_EVIDENCE_LADDER.md` |
| Bug 修复 | §4 Bug 修复协议 |
| 编译报错 / 编译起不来 / 编译入口 | §编译纪律 + `references/UE_BUILD_PITFALLS.md` |
| **想 clean/rebuild/全量重编** | **§编译纪律 R8（先读，多为禁止项）** |
| 运行时崩溃 / 序列化 / 接口 / 多态 / API 真名 | `references/UE_RUNTIME_GOTCHAS.md` + `references/CLAIM_EVIDENCE_REGISTRY.md` |
| Spec 编写 / headless / Python 边界 | `references/AUTOMATION_TESTING.md` |
| MCP 连不上 / 排查树 / 配置与启用 | `references/MCP_CHANNELS.md` |
| **启动引擎后卡住 / 疑似弹窗 / 崩溃报告器 / 循环等待无响应** | `references/STARTUP_STUCK_DIAGNOSIS.md`（截图→日志→决策表） |
| **Slate 控件树自动化 / 编辑器 UI 操作 / 自定义工具调试** | `references/SLATE_AUTOMATION.md`（骨架速查见 §3.4） |
| Slate 控件在快照里隐形 / MCP 全超时疑似死锁 | `references/PITFALLS_SLATE_UI.md` |
| 多 Agent / 并行任务编排 | `references/PARALLEL_ORCHESTRATION.md` |
| 残留进程 / 误杀风险 / 窗口 overlay | `references/PROCESS_HYGIENE.md` |
| 特定环境首次接入 / 可粘贴配置 / 插件启用 | `references/MCP_CHANNELS.md` §接入 |
| 实测案例锚点（引擎在跑但通道连不上） | `references/CASE_STUDY_UEMCP_OUTAGE.md` |
| **按症状查经验** | `references/EXPERIENCE_INDEX.md` |
| 任务结束沉淀经验 | `references/SKILL_DISTILLATION.md` |

---

## 2. 核心协议骨架（每次必读）

### 2.1 Profile 判定与能力通道

1. 检查操作系统、UE 版本、仓库构建入口与可用工具。
2. 不满足 Windows + UE5.8 + Rider/MCP 条件时选择 **core profile**：保留 Gate、状态机、证据和 R8；跳过 PowerShell/MCP/Slate 专用步骤，使用仓库已有构建与测试入口。
3. 条件满足时选择 **automation profile**，再启用下表。不得因 profile 不匹配中断一个本可用项目原生工具完成的任务。**当前 Automation Profile 状态为 Preview**：`scripts/mcp_catalog.json` 标记 `provenance_complete=false`，短 toolset 名默认禁用；正式发布前必须在目标 UE 环境用 `dump_mcp_catalog.py` 重新生成并通过 `validate_skill.py --release`。

| 通道 | 职责 | 默认实例 | 健康判据 |
|---|---|---|---|
| **IDE/构建通道** | 编译、运行配置、静态检查 | RiderMCP `127.0.0.1:64482/stream` | GET 200 |
| **引擎内通道** | 引擎内测试、编辑器操作、Python、Slate 控件树 | UnrealEngineMCP `127.0.0.1:8000/mcp`（仅 UE5.8 原生 `ModelContextProtocol` 插件，不用社区方案） | 200/405 |
| **实机通道** | 截图、按键、窗口管理、**死锁救援** | Workbench `127.0.0.1:3939/mcp` | 405（只收 POST，正常） |
| **日志终审** | 一切结论的最终裁判 | 直接读 `<Project>/Saved/Logs/*.log` | 不依赖任何通道 |

> 换环境时改端点即可（`env_health_check.ps1 -Endpoints` 参数化），纪律不变。排查树/配置/启用 → `MCP_CHANNELS.md`。

### 2.2 五个 Gate（按任务适用性执行；不适用项必须标 N/A）

| Gate | 强制内容 | 违反后果 |
|---|---|---|
| **读门** | 改动前实际读取源码/知识文件并引用 `文件:行号`；跨会话重读，**禁止凭记忆写项目内/引擎 API** | 产出无效，回退重做 |
| **证据门** | 任何结论附证据（`文件:行号` / 日志原文 / 命令输出）。**禁止**「应该是/可能是」 | 产出无效，回退重做 |
| **验证门** | 改动后跑验证并**贴出真实输出**；UE = 编译 + 引擎内测试 + 实机/日志（§2.4） | 标记未完成，不得交付 |
| **需求门** | 开工前复述目标与验收标准（state-back）；完工后逐条勾选 ✅/❌ | 不得宣布完成 |
| **交接门** | 阶段结束/会话中断前形成 Current Truth；允许写文件时更新 STATUS/工作日志，否则写入最终回复 | 不得丢失当前事实与下一步 |

### 2.3 六阶段状态机（精简；完整版见 `WORKFLOW_STATE_MACHINE.md`）

| 阶段 | 名称 | Exit Gate（不过则停留） |
|---|---|---|
| **M0** | 定位事实 | 根因/目标状态可解释；具备稳定红测试、缺失能力证明或可重复现状基线之一 |
| **M1** | 冻结合同 | 目标/非目标/不变量/回退策略明确；Oracle 唯一 |
| **M2** | 最小实现 | Diff 小且可解释；失败用例由红转绿；回滚路径存在 |
| **M3** | 机械验证 | 编译 + focused/full Automation，测试来自最后源码修改之后 |
| **M4** | 真实验证 | 高价值真实用户链通过；未执行项显式标 NOT RUN |
| **M5** | 复用收口 | 接手者 10 分钟内能找到下一最小动作 |

> 状态只用五种：Done / In progress / Next / Blocked / Deferred。**高层失败不能用更多低层绿灯抵消。**

### 2.4 UE 测试闭环（按风险选择最低证据层；细则见 `QA_EVIDENCE_LADDER.md`）

```
① 编译（IDE/构建通道，build_solution_start 主入口；贴真实输出）
    ↓
② 启动/确认引擎（新产物启动；headless 跑 Spec 可直接替代②③④；
   ★ 迟迟无窗口/疑似弹窗 → 启动卡死协议：Workbench 截图 + 窗口枚举 + 日志取证，
     禁止盲等或重发启动 → references/STARTUP_STUCK_DIAGNOSIS.md）
    ↓
③ 等待引擎自动化通道链接（★ 轮询：探测→等5s→再探测，最多10次；
   前置条件 = 编译成功 + 新产物启动；链接后必须做工具级握手）
    ↓
④ 引擎内测试（Automation Spec headless 优先 → Python/PIE 交互）
    ↓
⑤ 实机验证（截图/按键/视口——行为级证据；headless 无法覆盖时必做）
    ↓
⑥ 日志取证（Saved/Logs/*.log：先 tail 再 grep，引用原文）
    ↓
⑦ 验收勾选（对照验收标准逐条 ✅/❌ + 证据引用）
    ↓
⑧ 复盘交接（Current Truth + 工作日志 + 勘误候选）
```

**规则（R1–R8）**：
- **R1 编译必须真实执行**：禁止「我觉得能编译过」，须贴出编译输出。
- **R2 引擎未启动时**：启动或请用户启动；不得跳过引擎直接宣称测试通过。
- **R3 等待链接必须轮询**：最多 10 次×5s；**禁止**「连不上→放弃→口头说应该没问题」。
- **R4 测试优先自动化**：跑 Spec 优先 headless；必须检查完整退出码契约（0 通过；1 测试/编辑器失败；2 零测试；3 无本轮日志；4 参数错误；5 超时；6 runner 基础设施失败）。自动化不可达时按风险退到实机+日志。
- **R5 日志是最终裁判**：行为正确性结论必须能引用日志/截图/测试输出之一；三样都没有 = 未验证。
- **R6 一个闭环 = 一次验收**：未走完闭环的任务不得标记完成。
- **R7 放弃某一通道 ≠ 跳过验证**：改走降级路径，验证义务不豁免，交付说明中注明原因。
- **R8 Rebuild 禁令**：见 §编译纪律——**禁止自主发起任何 clean/rebuild/全量重编**。

### 2.5 MCP 纪律硬规则（合并实测事故）

1. **先检查后使用**：仅 automation profile 在进入对应通道前运行 `scripts/env_health_check.ps1 -ProjectPath <Project>`；core profile 使用仓库已有检查。**编译阶段禁止探测/断言引擎内通道**——此时 8000 无监听不构成降级证据。
2. **引擎在跑 ≠ 引擎内通道可用**：进程 + MCP 插件启用 + AutoStart + 端口监听 + **工具集插件（AllToolsets）启用**，缺一不可，逐一验证（新项目启用 MCP 后工具集默认为空，`SlateInspectorToolset` 等随 AllToolsets 提供，见 `MCP_CHANNELS.md` §6.3）。
3. **项目路径显式传参**：严禁照抄配置里的 `IJ_MCP_SERVER_PROJECT_PATH`；以实际 `.uproject` 为准；双 mcp.json 漂移（.workbuddy/.codebuddy）要提醒用户。
4. **调用超时 ≠ 失败**：先查进程与日志再决定是否重试，否则制造双引擎/双编译实例。`engine_pid_tracker.ps1 -Action diff` 只报告候选 PID，**不能证明所有权**；只有启动器返回并经 `register` 登记的精确 PID 才可由 cleanup 处理。`-WaitMutex` = UBT 互斥锁被占，等待勿重发。
5. **RiderMCP = 编译最高优先级**（详见 §编译纪律）；不可达 → 中断请用户裁决，默认不擅自命令行。
6. **编译前卫生**：只读确认 `cl.exe`/`UnrealBuildTool`/`MSBuild`/`Build.bat` 的 PID、父进程、命令行与项目归属；未知进程不得终止，Rider 管理的队列走 IDE 取消接口或交用户。外部 UBT/全量构建前必须关当前项目 UnrealEditor；明确走 Live Coding/Hot Reload 时可保持运行。
7. **插件未启用 → 征求用户**：仅在时序前提满足时触发；拒绝则放弃该通道走降级验证并明示，不纠缠、不假装。
8. **MCP 调用约定三套并存**（易混淆，统一走 `mcp_call.py`/`wb_call.py`）：SlateInspectorToolset 用全限定 toolset 名 + 短 tool_name；desktool 用短名 + `desktool.` 前缀 tool_name；editor_toolset 全限定 + 短名。调用器仅在握手、JSON-RPC 与 tool 结果均成功时退出 0；任何非零都不得当成功。业务返回中的 `{"returnValue":...}` 仍需二次解析。
9. **疑似模态框死锁**：引擎内 MCP 全部超时时，将模态框列为高优先级候选，但先用截图、窗口枚举、进程和日志确认；确认是无害关闭类后才执行 `{Escape}`，随后验证并 `window_release`（见 `PITFALLS_SLATE_UI.md` §3）。
10. **窗口与进程卫生**：用过 `window_control` 必须 `window_release`；引擎清理只处理 `snapshot → 精确启动 PID → register → cleanup` 的登记记录，必须带 `-ProjectPath` 与 `-RunId`，**禁按名杀、禁用时间差推断所有权**。
11. **headless 优先**：跑 Spec 默认 `run_spec_headless.ps1`；任何非零退出码都按失败或阻塞处理，仅 0 可作为通过。仅需引擎内 Python 交互才走 MCP 模式。
12. **链接 ≠ 可用**：探测 200/405 只说明端口活着，链接成功后必须做**工具级握手**（调用只读工具确认返回），否则不得宣称「已链接」。
13. **引擎启动卡死 → 截图取证，不盲等**：编译成功后 5 分钟无主窗口 / 进程在但 :8000 不通且排查树正常 / 启动调用超时但进程在 / headless 超时数倍 / 用户报有弹窗——任一命中即走启动卡死协议：**实机通道截图 + 窗口枚举 + 日志取证 → 按弹窗决策表处置**（无害关闭类 AI 自动；有状态选择类/崩溃类取证后交用户）。轮询必须有上限，禁止把等待当处理（详见 `STARTUP_STUCK_DIAGNOSIS.md`）。

---

## 3. 编译纪律（★ 本技能核心裁决区）

### 3.1 编译入口优先级

```
需要编译
├─ core profile → 使用仓库已声明的原生入口（CI 脚本、IDE、BuildGraph、Build.bat 等）
│                  不自行替换入口；破坏性/全量动作仍受 R8 与用户授权约束
└─ automation profile
      ├─ RiderMCP 可用 → build_solution_start 主入口；build_solution_state 轮询
      │                  execute_run_configuration / get_file_problems 仅作辅助
      └─ RiderMCP 不可达 → 报告能力缺口；改用其他入口前按仓库规则或向用户确认
```

> 无论走哪个 profile，必须从实际输出确认构建了哪些 target；“方案构建成功”不自动等于 Editor + Game 全部覆盖。

- **RiderMCP 调用必须带项目路径参数**；`build_solution_start` 是**异步**的（立即返回 sessionId，用 `build_solution_state` 轮询到 `Completed` + `buildIsSuccess`；已有构建在跑会直接报错）；**`rebuild` 参数默认 false=增量，传 `rebuild:true` 即触发 R8 报备流程**。
- 实测（2026-09）：引擎级增量构建以分钟计（2 分钟+ 属正常），轮询间隔 20~30s，不因慢重发；`get_run_configurations` 会列出引擎全部 Program target 配置（`BaseTextureBuildWorker`/`ChaosVisualDebugger`…），选运行配置时只选当前项目同名配置——误选这些配置正是旧记载「编译风暴/无限队列」的根源。
- 引擎弹出 `Missing Modules — Would you like to rebuild them now?` 是 UE 标准路径，**交给用户在引擎/Rider 点 Yes**，AI 不绕路跑脚本。
- MCP 会话不能跨进程复用（`Streamable HTTP session not found`）：用 `scripts/rider_call.py` 在同进程完成握手+调用（HTTP 直连场景）。

### 3.2 ★ R8：禁止自动全量 rebuild（红线）

> 背景：UE 编译成本极高（增量 40~90s，全量可达 1.5h）；实测 `Build.version is newer` 触发 makefile 重建 = **4517 个 action**。AI 一次「顺手 rebuild」可能吃掉用户数小时。
>
> **R8 对应红线 `BUILD-REBUILD-01`**。本节为速记入口，完整规则、报备话术、违反后果与相关实测见 `references/UE_BUILD_PITFALLS.md` §1.6。

**速记三句话**：
1. **禁止自主发起任何 clean / rebuild / 全量重编**——含删除 `Intermediate/`/`Binaries/`/`Saved/`、`Build.bat -clean`、UBT `-Rebuild`、改动 `Build.version` 等一切形式。默认只允许增量编译。
2. **禁止把「删中间产物重编」当排错手段**——编译报错读原文 → 查 `UE_BUILD_PITFALLS.md` → 修根因（如 LNK1136 加 `-NoUBA`，不是 rebuild）。
3. **用户明确要求才可全量/rebuild，且一次一确认**——先报备（触发原因 / 预估 action 规模与时长 / 影响范围）→ 获针对该一次操作的明确同意 → 执行；同意不延续、不得批量预授权。

> 报备话术（完整版见 `UE_BUILD_PITFALLS.md` §1.6）：「编译需要全量 rebuild：原因 X，预估 N 个 action / 约 M 分钟，影响范围 Y。是否执行？(是/否)」
>
> 违反后果：该次编译结果无效，视为未验证（与所有 Gate 违反一致）。超时/卡住不是 rebuild 理由——`-WaitMutex` 等锁、IDE 排队、超时后查进程——一律等待或排查。

### 3.3 零引擎侵入（红线）

- **默认禁止修改引擎源码**（`Engine/` 树内任何文件）。一切能力扩展优先在**项目侧**实现。
- Slate role 注册走项目侧公开 API（`RegisterWidgetRole`/`RegisterLabelExtractor`，见 `SLATE_AUTOMATION.md`）；改引擎补丁只作备选存档（`PITFALLS_SLATE_UI.md` 附录），**须用户逐次明确授权**。

### 3.4 Slate 自动化速查（完整见 `SLATE_AUTOMATION.md`）

- 引擎内通道提供 **ref 级 Slate 控件树操作**（Observe/Snapshot/Click/Hover/Drag），适用于编辑器任意窗口与自定义 Slate 工具；**蓝图图表只是已验证案例**。
- **ref 优先于坐标**：坐标点击在 graph 类控件上不可靠（pin 几何在节点框外），一律用快照 ref 操作。
- 快照前先 `Observe`（maxDepth 40）+ sleep 3，否则树浅且被截断。
- **所有引擎内 MCP 全部超时** → 将模态框列为高优先级候选；先用截图/窗口/进程/日志确认，再按硬规则 9 处置。

---

## 4. Bug 修复协议（强制顺序）

```
复现（稳定失败用例）→ 读日志（Saved/Logs/*.log，先 tail 再 grep）→ 证据根因（文件:行号，事实/推断分栏）
    → 最小修复（只改一个 seam）→ 编译（§3 入口）→ 引擎内回归（§2.4 闭环）→ 复盘沉淀
```

任何一步缺失 = 未完成。**明确禁止**：未读日志直接诊断；跳过复现直接改；「先改一下试试」；修复后不编译不回归就宣布完成；失败后无新证据地反复「继续」（每次重试必须携带新证据或作废的假设）。

---

## 5. 标准开发工作流（需求 → 交付）

```
① 会话启动：判定 core/automation profile；读取存在且相关的仓库知识文件，automation profile 再跑 env_health_check
② 需求门：复述目标与验收标准（state-back），确认后开工
③ M0 只读调查：读源码引用 文件:行号，事实/推断分栏，列出消费者与 owner
④ M1 冻结合同：目标/非目标/不变量/验收，写入 Plan
⑤ M2 实现：最小切片，只改授权文件
⑥ M3+M4 验证：§2.4 闭环，T0→T4 按风险升级
⑦ 需求门：验收标准逐条 ✅/❌ + 证据
⑧ 交接门：形成 Current Truth；获授权时更新 STATUS/工作日志并提交，未授权或只读任务则写入回复；清理已登记进程/窗口/测试资产
```

---

## 6. 五大红线（★ 最优先记忆，完整 27 条见 `references/TABOO_LIST.md`）

> 所有 27 条禁忌都是红线，违反任意一条按 Gate 违反处理（产出无效、回退重做）。以下五条单列是因为代价灾难性，且 AI 在疲劳或上下文压缩时最易遗忘。

| # | 红线 | 代价 | 权威位置 |
|---|---|---|---|
| `BUILD-REBUILD-01` | **自主 clean/rebuild/全量重编**，或删除中间产物当排错手段 | 用户数小时 | §3.2 R8 / `UE_BUILD_PITFALLS.md` §1.6 |
| `VALIDATE-RUNTIME-01` | **未达到任务最低证据层就宣称功能正确**；把零测试当通过 | 假成功 | §2.4 / `QA_EVIDENCE_LADDER.md` |
| `ENGINE-SOURCE-01` | **未经用户逐次授权修改引擎源码** | 引擎污染、升级丢失 | §3.3 |
| `UI-MODAL-01` | **替用户点击有状态弹窗按钮** | 破坏性操作、状态污染 | `STARTUP_STUCK_DIAGNOSIS.md` §2.3 |
| `RETRY-EVIDENCE-01` | **失败后无新证据地重试** | 错误方向扩大、补丁堆叠 | `PROMPT_CONTRACTS.md` §5 |

> 完整 27 条（含上述五条的展开与其他 22 条：读门/证据门/MCP 通道/进程卫生/Slate UI/范围/并行等主题）见 `references/TABOO_LIST.md`，每条标注编号 + 关联 Gate + 文件位置，便于追溯根因。

---

## 7. 文件结构

```
ue-engineering-loop/
├── SKILL.md                          # 本文件（协议总纲 + 五大红线 + Quick Start，每次必读）
├── references/                       # 按需查阅
│   ├── TABOO_LIST.md                 # ★ 完整 27 条禁忌清单（按主题分组 + 关联 Gate/文件位置）
│   ├── MCP_CHANNELS.md               # 四通道能力/连接检查/排查树/配置启用/环境接入（三源合一）
│   ├── SLATE_AUTOMATION.md           # ★ 通用 Slate 控件树自动化（能力 + 项目侧 role 注册 + 蓝图参考案例）
│   ├── PITFALLS_SLATE_UI.md          # Slate 自动化踩坑全集（隐形控件/死锁救援/输入；改引擎补丁=备选附录）
│   ├── UE_BUILD_PITFALLS.md          # 编译踩坑全集（UHT/UBT/构建通道/★ R8 权威位置 §1.6）
│   ├── UE_RUNTIME_GOTCHAS.md         # 运行时版本化观察（DllMain/序列化/接口/多态/API 真名）
│   ├── CLAIM_EVIDENCE_REGISTRY.md    # 高影响结论的版本、证据状态与复核入口
│   ├── QA_EVIDENCE_LADDER.md         # T0-T4 证据阶梯 + 测试闭环细则 + 失败场景速查 + Automation 设计法
│   ├── STARTUP_STUCK_DIAGNOSIS.md    # ★ 引擎启动卡死与弹窗排查（截图取证/弹窗决策表/崩溃取证/禁止盲等）
│   ├── AUTOMATION_TESTING.md         # 自动化验证手册（headless Spec/Spec 编写/Python 边界）
│   ├── WORKFLOW_STATE_MACHINE.md     # 六阶段状态机详解 + Plan/Gate 模板 + GO/NO-GO
│   ├── PROMPT_CONTRACTS.md           # 任务合同七要素 + 可复制 Prompt 模板
│   ├── CONTEXT_MANAGEMENT.md         # 上下文工作集/真包/压缩/恢复 + 长任务文档体系 + 勘误候选机制
│   ├── PARALLEL_ORCHESTRATION.md     # 并行按冲突域（lane/barrier/单一集成者）
│   ├── SKILL_DISTILLATION.md         # 经验→Skill 提炼协议
│   ├── PROCESS_HYGIENE.md            # 进程与窗口卫生（PID 跟踪/清理清单）
│   ├── EXPERIENCE_INDEX.md           # ★ 最值得记住十条 + 案例锚点（症状路由见 SKILL.md §1）
│   └── CASE_STUDY_UEMCP_OUTAGE.md    # 实测案例锚点（引擎在跑但通道连不上）
├── scripts/
│   ├── env_health_check.ps1          # 分层能力探测 + 精确状态码 + 配置路径漂移
│   ├── engine_pid_tracker.ps1        # snapshot/register/diff/cleanup；只清理精确登记 PID
│   ├── run_spec_headless.ps1         # headless Spec；队列终止标记、互斥、同源 SelfTest
│   ├── mcp_common.py                 # MCP 握手/解析/错误码/原子输出共享实现
│   ├── dump_mcp_catalog.py           # 全量 schema 校验后原子更新 catalog
│   ├── rider_call.py                 # RiderMCP 严格调用器
│   ├── mcp_call.py                   # UnrealEngineMCP 严格调用器
│   ├── wb_call.py                    # Workbench MCP 严格调用器
│   ├── validate_skill.py             # frontmatter/链接/catalog/规则 ID 质量门
│   └── mcp_catalog.json              # 历史工具目录；provenance_complete=false 时只允许全限定 toolset 名
├── tests/
│   ├── test_mcp_common.py            # MCP 客户端、工具集解析与 catalog 单元测试
│   ├── test_powershell_contracts.py  # Windows PowerShell 错误码与 SelfTest 契约
│   └── test_validate_skill.py        # 质量门自测
└── .github/workflows/quality.yml     # Windows/Linux、Python 3.10/3.13 与可选 release gate
```

> **详细流程速记**：进入 UE 项目 → 判定 core/automation profile → 按 §1 路由 → 需求门 state-back → M0 只读调查 → 使用 profile 对应构建入口并遵守 R8 → 按风险完成 §2.4 证据层 → 交接门收口。仅 automation profile 运行 `env_health_check.ps1` 与 MCP/Slate 流程。
>
> **维护约定**：SKILL.md 只放「每次必读」的骨架与红线；详细话术、完整说明、踩坑清单一律放 `references/`。领域实测结论标注适用版本（多数为 UE 5.x 实测，跨版本使用前先小成本验证）。
