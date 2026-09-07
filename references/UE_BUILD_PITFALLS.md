# UE 编译踩坑全集（UHT / UBT / 构建通道）

> 沉淀自 2026-08 ~ 2026-09 一次 12 阶段 UE 5.x 插件长任务开发的实战教训。
> **目的**：把「编译报错 → 反复试错」变成「先看本清单 → 一次写对」。UE 编译成本高（增量 40s~90s，全量可达 1.5h），试错代价极大。
> 版本说明：UHT/UBT 规则普遍适用于 UE4/UE5；标注「实测」的条目出自 UE 5.x，跨大版本使用前先小成本验证。

---

## 1. 构建通道语义（先于代码问题排查）

> 本技能把「编译入口」抽象为**构建通道**：优先使用 IDE 集成通道（如 RiderMCP / VisualStudio 集成 / 引擎 MCP），其产物是真实编译输出。通道语义的教训与具体工具无关。

### 1.1 调用超时 / `-32001 Internal server error` ≠ 失败

构建通道调用返回超时/内部错误时，**编译或启动进程可能已经成功**。

| 误判 | 后果 | 正确做法 |
|---|---|---|
| 超时就重试 | **双引擎实例 / 双编译实例**（实测发生过 2 次） | 先按 PID 确认进程是否已存在，再决定是否重试 |

**判定流程**：
```
构建调用超时
   ↓
查进程（UnrealEditor / cl / UnrealBuildTool 是否出现）
   ├─ 已出现 → 启动成功，不要重试，继续等结果
   └─ 未出现 → 真失败，重试一次；再失败转查 IDE/通道状态
```

### 1.2 通道工具必须带项目路径参数

IDE 集成通道的编译/运行配置/文件检查工具，凡涉及项目的调用均需**显式传项目路径**（`rootFolder` / `projectPath`）。
不传时可能返回**上一次会话/其他项目**的运行配置（实测返回过 `F:/Unreal/Demo` 而非当前 `F:/Unreal/Blank`）。

> 判断依据：返回的运行配置里应包含当前项目的 **Uproject 配置**。多配置文件（不同 AI 工具各一份）可能**漂移不一致**，以实际 `.uproject` 为准。

### 1.3 三类「编译起不来」的成因区分

| 现象 | 真因 | 处理 |
|---|---|---|
| 通道端点不可达（健康检查非 200） | IDE 集成通道未连接 | **中断并提示用户，等用户裁决**（SKILL.md §3.1）；未经用户授权不擅自命令行 |
| 端点可达，单次调用超时 | IDE 繁忙（索引/构建中） | 等待后重试；若只是跑 Spec，可直接改走 headless（`AUTOMATION_TESTING.md` §1）；**不属于「未连接」** |
| 调用返回 `-WaitMutex` / 长时间排队 | **UBT 全局互斥锁**被另一编译持有（如后台在跑 Game target 全量编译） | 等持锁编译结束；期间不要重复发起 |

### 1.4 Live Coding 锁

引擎正在运行且 Live Coding 活跃时，UBT 编译会失败（`.modules` / DLL 被占用）。
**全量编译前先关闭引擎进程**（用 PID 跟踪协议，见 `PROCESS_HYGIENE.md`）。

### 1.5 编译入口（★ 按项目所有者裁决：build_solution_start 主入口）

**编译入口优先级**（SKILL.md §3.1 的完整说明）：

| 优先级 | 入口 | 适用 |
|---|---|---|
| **主入口** | `build_solution_start`（方案级构建） | 日常/完整构建；项目解决方案与引擎解决方案均可（引擎/引擎插件改动同样覆盖） |
| 辅助 | `execute_run_configuration`（运行配置） | 按运行配置编译/启动（如 Uproject 配置、启动编辑器配置） |
| 辅助 | `get_file_problems` | 改完代码立即静态检查，辅助定位编译错误 |
| 兜底 | 命令行（Build.bat / UBT） | **仅当 RiderMCP 不可达 + 用户明确授权**；卫生细节见 §6 速查与 `PROCESS_HYGIENE.md` |

**观测提示（历史记载，非禁令）**：有记载称在引擎解决方案上做方案级构建时出现过「引擎所有目标排成长队列（`BaseTextureBuildWorker`/`BreakpadSymbolEncoder`/`ChaosVisualDebugger`…）+ MSBuild 缺 UBT include 产生海量假错误」的现象。以实测为准：若出现该症状，记录现象与判别特征（日志里出现大量与项目无关的引擎 Program/Worker 目标、多轮 5xx actions）并向用户报告，由用户裁决是否调整入口策略。

**★ 实测记录（2026-09-06，RiderMCP 2026.2.1，方案 = F:/Unreal/Blank 所在引擎解决方案）**：
1. `build_solution_start` 为**异步**设计：立即返回 `sessionId`，用 `build_solution_state` 轮询（`state`: Running/Completed/Cancelled/NotFound；`problems` 增量累计；完成后 `buildIsSuccess`）。**已有构建在跑时再次调用直接报错**（天然防重入）。
2. **`rebuild` 参数（默认 false=增量）就是 R8 的管辖入口**：任何 `rebuild:true` 调用前必须按 R8 向用户报备并一次一确认。
3. `get_run_configurations` 实测返回**海量引擎 Program target 的 "Uproject 配置"**（`BaseTextureBuildWorker`/`BenchmarkTool`/`BlankProgram`/`BreakpadSymbolEncoder`/`ChaosVisualDebugger`…）——**这正是旧记载「无限队列名单」的来源**：风暴根源是 `execute_run_configuration` 误选了引擎 Program 配置，不是方案级构建本身。选运行配置时只选**当前项目同名配置**（如 `Blank`）。
4. Unreal 语义：编辑器已连接且 Live Coding 可用 → Hot Reload 编译；否则 UBT 编主 Editor target。
5. **引擎级增量构建以十分钟计 + 活跃性判定（★ 2026-09-06 完整实测）**：引擎方案增量构建（426 actions，RenderCore/Renderer 等）从发起到 UBT 实际开工有 **~7 分钟排队**（20:21 发起 → 20:28 UBT 开始写日志），期间 `build_solution_state` 一直 `Running`。**关键语义：`problems` 只是错误/警告清单，不含进度——`Running + problems:[]` 不代表卡死**。构建活跃性用磁盘证据判定：
   ```bash
   tail -3 "Engine/Programs/UnrealBuildTool/Log.txt"          # [N/M] Compile/Link 行，N 递增 = 健康
   ls --time-style=full-iso -l "Engine/Programs/UnrealBuildTool/Log.txt"   # mtime 持续更新 = 在干活
   ```
   mtime 停滞数分钟 + [N/M] 不动 → 疑似真卡死（结合 `-WaitMutex` / 排队分析），报告用户。**不得因慢重发构建**（服务端会拒绝，语义上属重复发起）；长构建无需阻塞等待，凭 `sessionId` 随时恢复查询，构建在 Rider 内独立运行。
6. MCP 会话不能跨进程复用（`Streamable HTTP session not found`）——用 `scripts/rider_call.py` 在同进程完成握手+调用。

**能力边界分层**：

| 层级 | 内容 | 谁做 |
|---|---|---|
| **能力边界内** | 入口选择、只读报告编译 PID/父进程/命令行/锁状态、修复代码错误 | **AI 自己解决** |
| **能力边界外** | 终止未由当前 build session 精确登记的编译进程、Rider 管理的构建队列、通道不可达、引擎有状态弹窗 | **调用 IDE 的明确取消接口或请用户处理** |

**编译卡住/超时的处理**（长时间无新产物、无输出）：
1. **先自我诊断根因**；
2. 能力边界内 → 自己修；
3. 能力边界外 → **明确告知用户根因 + 具体动作**（如「请在 IDE 停止构建」）。

**严禁**：笼统推给用户 / 未经授权换命令行 / 重复启动编译实例。

**发起新编译前**必须只读确认是否存在 `cl.exe` / `UnrealBuildTool` / `Build.bat` / `MSBuild`，并记录 PID、父进程、命令行、项目路径和 Rider session。未知归属默认视为用户/IDE 所有，不得按名终止；只有当前 build session 精确登记的进程才可按其取消协议处理。

> **注意**：MSBuild 进程若处于「方案构建队列」中，杀掉会被 IDE 自动重启（实测），必须由用户在 IDE UI 停止。
> 但**与 UE 编译无关的**临时 MSBuild 进程（如跑 `.proj` 临时文件）**不影响 UE 编译**，不要误判为阻塞（曾误判过一次）。

### 1.6 ★ R8 Rebuild 禁令（`BUILD-REBUILD-01` 权威展开）

> **本节是 R8 的权威完整版**。SKILL.md §3.2 仅保留速记三句话 + 指针；本节含完整规则、报备话术、违反后果与相关实测。
>
> 背景：UE 编译成本极高（增量 40~90s，全量可达 1.5h）；实测 `Build.version is newer` 触发 makefile 重建 = 4517 个 action、二三十分钟起步。AI 一次「顺手 rebuild」可能吃掉用户数小时。

1. **禁止自主发起任何 clean / rebuild / 全量重编**：包括但不限于——删除 `Intermediate/`、`Binaries/`、`Saved/`、makefile，`Build.bat -clean`，UBT `-Rebuild`，改动 `Build.version` 等一切触发形式。**默认只允许增量编译**。
2. **禁止把「删中间产物重编」当排错手段**：编译报错的正确路径 = 读错误原文 → 查本清单 → 修根因（如 LNK1136 加 `-NoUBA`，而不是 rebuild）。
3. **用户明确要求时才可全量/rebuild，且一次一确认**：先报备——触发原因、预估 action 规模与时长、影响范围——获得**针对该一次操作的明确同意**后执行；同意不延续、不得批量预授权。
   > 报备话术：「编译需要全量 rebuild：原因 X，预估 N 个 action / 约 M 分钟，影响范围 Y。是否执行？(是/否)」
4. **超时/卡住不是 rebuild 理由**：`-WaitMutex` 等锁、IDE 排队、超时后查进程——一律等待或排查。
5. **违反后果**：该次编译结果无效，视为未验证。
6. **相关实测**：`Build.version is newer` 触发 makefile 重建、LNK1136 的 `-NoUBA` 解法、Live Coding 锁——分别见 §6 速查表、`PITFALLS_SLATE_UI.md` §6、§1.4。

---

## 2. UHT 规则全集（每条都是真报错）

> UHT（Unreal Header Tool）只解析头文件，且对**声明形式**有大量隐式约束。违反时报错位置常常与真实原因相距很远。

### 2.1 头文件与 generated.h

| 规则 | 违反症状 |
|---|---|
| 含 `UCLASS`/`USTRUCT`/`UENUM`/`UINTERFACE` 的头文件，**必须**在 include 列表**最后**包含 `<Name>.generated.h` | 链接错误 / 类型未注册 |
| **没有反射类型**的头文件（纯模板/宏）**不要** include `*.generated.h` | `Unable to find generated.h`（文件根本不存在） |
| 与某反射头**同名**的 `.cpp`，必须**第一个** include 该同名头 | UHT: `Expected <Name>.h to be first header included` |

### 2.2 类的强制形式

| 规则 | 违反症状 |
|---|---|
| `UCLASS` **只能声明在头文件**，不能放 `.cpp` | `C2084: 函数已有主体` |
| Actor 类名必须 **`A` 前缀**；UObject 必须 **`U` 前缀** | UHT 报错（不是警告） |
| `UINTERFACE` 的 interface 类用 `GENERATED_BODY()` 时，其**默认访问级是 private**，接口函数必须显式 `public:` | `A Private function cannot be a BlueprintNativeEvent` |
| legacy 宏 `GENERATED_UINTERFACE_BODY()` 需要在 `.cpp` 里定义构造 | `LNK2019 无法解析的外部符号` |
| 测试桩类（UCLASS 辅助类）必须放**头文件** | UHT 扫不到 `.cpp` 里的 UCLASS |

### 2.3 USTRUCT 的边界

| 结论（5.x 实测） | 说明 |
|---|---|
| **不支持** `Abstract` | 虚基类靠「虚析构 + 默认实现」表达 |
| **不支持引用类型 UPROPERTY** | 官方 Structs 文档明确禁止；用值成员 + 约定替代 |
| **支持虚函数**（含虚析构） | 引擎先例 `FGameplayEffectContext`；`TInstancedStruct` 拷贝走 ScriptStruct ops，虚表同类一致 |
| **不支持** `mutable` UPROPERTY | 需要 const 内写缓存时用 `const_cast`（见 `UE_RUNTIME_GOTCHAS.md` §7） |

### 2.4 宏与元数据

| 规则 | 违反症状 |
|---|---|
| `TInstancedStruct<T>` **禁止**显式写 `meta=(BaseStruct=...)` | UHT 报错（模板参数已隐式提供） |
| `WITH_EDITORONLY_DATA` 内的成员**禁止** `BlueprintReadWrite` | `Blueprint exposed struct members cannot be editor only` |
| `UI_COMMAND` 宏所在文件必须有 `LOCTEXT_NAMESPACE` 且成对 `#undef` | 编译错误 / 本地化失效 |
| 可变参数宏（`##__VA_ARGS__`）的默认值在 MSVC 下语义不稳定 | 传参时报「参数过多」→ **改用固定参数个数的宏** |
| 宏**体不含分号**，调用处必须补 `;` | `expected a ';'` |
| 前置声明的 `class`/`struct` 必须与实际定义**一致** | `C4099` 类型未定义 |

---

## 3. 错误链误导（最难排查的一类）

**症状**：报错内容与真实根因相距极远。

**真实例子**：某头文件 `ConditionSet.h` 未 include 枚举定义头 →

```
error: 'Logic' is not a member of 'FHadesSequenceConditionSet'
error: 'ReduceConditionResults': function does not take 2 arguments
```

报错指向**使用处**，根因却在**被 include 的头缺 include**。

**诊断法（固定套路）**：
```
1. 全盘搜该类型/枚举名，确认是否重复定义或定义缺失
2. 检查报错类型的头文件，逐个确认其成员的**定义是否已 include**
3. 若某类型在 UHT 里「能生成」但 MSVC 报「不是成员」→ 几乎一定是 include 缺失
   （UHT 不做类型检查，所以 UHT 通过不代表 C++ 通过）
```

> **推论**：UHT 无错误 ≠ 编译无错误。二者是两条独立的检查链路。

---

## 4. 编译目标与依赖

### 4.1 双 target 必须都过（编辑器插件尤其）

Editor 独有的 `WITH_EDITORONLY_DATA` 字段在 **Game target 下不存在**，任何直接引用（如 `GET_MEMBER_NAME_CHECKED(Struct, EditorOnlyField)`）都会编译失败。

> ⚠️ **target 编译路径**：
> - **Editor target → RiderMCP 主入口**（`build_solution_start` / `execute_run_configuration`）；
> - **Game target → 同样先走 RiderMCP**，但“方案构建成功”不证明 Game target 已被包含；必须从 build session 输出、明确 target 名和对应产物时间确认。未覆盖时标 NOT RUN；仅当 IDE 下确实无该 target 的构建途径时，才在**用户明确授权后**走命令行（见 §4.2）。

```powershell
# Editor target —— 用 IDE 主构建通道，不要照抄这条命令行
# Build.bat <Project>Editor Win64 Development -Project="<uproject>" -WaitMutex

# Game target —— IDE 无该配置时才用命令行（须满足 §4.2 的 4 项约束）
Build.bat <GameTargetName> Win64 Development -Project="<uproject>" -WaitMutex
```

> **Game target 名不是 `<Project>Game`**：先 `Get-ChildItem Source/*.Target.cs` 确认真实目标名（实测某项目就是 `<Project>` 本身）。
> 首次编 Game target 会全量编译引擎模块（实测 1164 obj / 423 模块 / ~1.5h），之后为增量（~90s）。

### 4.2 Game target 编译（含命令行兜底约束）

**为什么 Game target 容易被漏编**：UE 通常有两个 target——

| target 文件 | `Type` | 产物 | 构建途径 |
|---|---|---|---|
| `<Project>Editor.Target.cs` | `TargetType.Editor` | `UnrealEditor-<Project>.dll` | ✅ RiderMCP 主入口 |
| `<Project>.Target.cs` | `TargetType.Game` | `<Project>.exe` | ⚠️ 先走主入口；无途径才授权命令行 |

⚠️ **陷阱**：IDE 里名为 `<Project>` 的 **Uproject 运行配置**实际执行的是 **Editor target**，不是 Game target。名字相同，极易误解。

**规则**：
1. Game target 优先经 RiderMCP 构建；从构建输出确认实际 target 名、平台、配置和产物时间。未见 Game target 证据时不得把方案构建绿灯写成“双 target 已通过”；
2. 当 RiderMCP 不可达，或已确认其当前解决方案/配置无法构建该 Game target 时，**经用户明确授权**后才可命令行编译：

```powershell
Engine\Build\BatchFiles\Build.bat <GameTargetName> Win64 Development -Project="<uproject>" -WaitMutex
```

**命令行兜底必须同时满足 4 项**：
1. 已证明 RiderMCP 不可达或无法覆盖该 Game target，且用户已明确授权本次命令行；
2. Game target 真实名字以 `Source/*.Target.cs` 为准（**不一定**是 `<Project>Game`）；
3. 在阶段报告与交接记录中**显式标注**「Game target 经命令行编译（原因）」；
4. 编译前关闭引擎（Live Coding 锁，见 §1.4）。

**为何不直接删掉双 target 要求**：`WITH_EDITORONLY_DATA` 字段在 Game target 下不存在。实测故障——editor-only 字段被 `GET_MEMBER_NAME_CHECKED` 直接引用 → Editor 通过、Game 失败。只编 Editor 会让这类问题潜伏到出包时才爆。

### 4.3 依赖必须「双声明」

| 位置 | 声明 | 漏掉后果 |
|---|---|---|
| `Build.cs` | `PublicDependencyModuleNames` / `PrivateDependencyModuleNames` | 链接错误 |
| `.uplugin` 的 `Plugins` 数组 | 引擎**插件**模块（如 `Niagara`） | UBT 警告「模块依赖了 Niagara 但插件未声明」；打包可能失败 |

### 4.4 Public vs Private 依赖

- **Public**：include 路径传递给下游模块。若你的**头文件**暴露了某模块的类型，必须 Public。
- **Private**：仅 `.cpp` 使用。

**常见错误**：Runtime 模块被 Editor 模块依赖时，若 Editor 的**公开头文件**用到 Runtime 类型，Runtime 必须在 Editor 的 `PublicDependencyModuleNames`。

---

## 5. 编译效率

| 场景 | 耗时（实测） | 说明 |
|---|---|---|
| Editor 增量（改 1 个 cpp） | 40~90s | 常规 |
| Game 增量 | ~90s | 常规 |
| Game **首次全量** | ~1.5h | 引擎模块全编译；安排在空闲时段，期间不要发新编译（`-WaitMutex` 会排队超时） |
| Live Coding（引擎运行中改码） | 快 | 但会锁 DLL，阻止 UBT 全量编译 |

**纪律**：
1. 发起编译前确认无残留 `cl.exe` / `UnrealBuildTool` / `Build.bat` / `MSBuild`。
2. 全量编译（尤其 Game target）放后台，轮询**进程退出**而非轮询日志内容——日志是块缓冲，长时间不 flush 会误判「卡住」。
3. 后台编译时，IDE 的运行配置（先 Build 再 Run）会排队等锁 → 表现为通道调用超时。**这不是启动失败**。

---

## 6. 速查表

```
□ 调用超时 → 先查进程再决定是否重试（不盲目重试）
□ 通道工具带项目路径参数；多配置文件漂移以实际 .uproject 为准
□ 编译主入口 = build_solution_start；命令行仅「不可达 + 用户授权」兜底
□ ★ R8：禁止自主 clean/rebuild/全量重编；用户要求才可且一次一确认
□ 全量编译前关闭引擎（Live Coding 锁）
□ 反射头必须带 generated.h 且在最后；非反射头不带
□ 同名 cpp 第一个 include 同名头
□ UCLASS 只在头文件；类名 A/U 前缀
□ TInstancedStruct 不写 BaseStruct 元数据
□ WITH_EDITORONLY_DATA 成员不写 BlueprintReadWrite
□ 宏调用处补分号
□ 报错「不是成员」→ 先查 include 缺失（UHT 不做类型检查）
□ Editor + Game 双 target 都编
□ 引擎插件依赖：Build.cs + .uplugin 双声明
```
