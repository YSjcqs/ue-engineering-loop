# QA 证据阶梯与 Automation 设计法（QA_EVIDENCE_LADDER）

> QA 与 AutomationTest 不是收尾清单，而是长任务的**导航系统**：任务中途不断回答「当前哪一层已经可信？下一步最值得验证什么？哪些结论仍然不能说？」
> 测试的目标：**决定下一步**，而不是装饰完成报告。

---

## 1. T0–T4 证据阶梯（UE 映射）

| 层 | 证明什么 | UE 具体动作 | 成本 | 不能替代 |
|---|---|---|---|---|
| **T0 静态** | 没有明显破坏 | exact-file diff、架构/依赖边界检查、编码检查、热路径禁令扫描 | 快 | 编译、业务逻辑、UI、真实运行 |
| **T1 Focused** | 确定性逻辑与失败注入 | focused Spec（headless）：序列化 round-trip、权限矩阵、Undo/Dirty、乱序/重复/cancel/stale generation | 低 | 可见 UI、真实环境 |
| **T2 Build+Full** | 模块/集成合同 | Editor+Game 双 target 编译 + 全量 Automation | 中 | 用户可见结果 |
| **T3 可见黑盒** | 用户看得见、可操作 | Editor 内操作验证：UI/Save/Reopen/PIE/截图 | 高 | 冷加载、Cook、多进程 |
| **T4 真实环境** | 真实运行与环境差异 | Standalone/DS+Client、late join、Cook、打包、性能、长稳、故障注入 | 最高 | —（这是终点） |

**Interactive QA 适合证明**：UI 操作、搜索选择拖拽、弹窗、Save/Reopen、布局、空状态、焦点、原生手感。
**失败动作**：停止扩大范围，修复当前层后重跑；失败退回**对应层**的 owning seam，不全项目盲查。

---

## 2. UE 测试闭环细则（SKILL.md §2.4 展开）

### ① 编译

```
1. 通过 IDE/构建通道编译——主入口 build_solution_start（SKILL.md §3.1）；贴出真实输出
2. 失败 → 提取错误行（文件:行号），先用 IDE 静态检查（get_file_problems）定位，修复后重编
   （禁止反复试错编译，每次失败先分析根因）
3. Game target 编译规则见 UE_BUILD_PITFALLS.md §4.2
4. 编译卡住/超时 → 先查进程再判（超时 ≠ 失败）；能力边界外明确告知用户根因+动作
5. ★ 时序纪律：编译阶段禁止探测引擎内通道状态（此时无监听是正常且必然的）
6. ★ R8：禁止自主 clean/rebuild/全量重编（UE_BUILD_PITFALLS.md §1.6）
```

### ② 启动/确认引擎 → ③ 等待链接

```
1. 检查进程（tasklist | findstr UnrealEditor）；已在运行 → ③（注意旧进程可能未启用插件）
2. 未运行 → 主构建通道启动，或请用户手动启动（编辑器启动 1-3 分钟，主动说明）
3. 轮询（前置条件 = 编译成功 + 新产物启动）：
   循环最多 10 次 × 5s：探测端点 → 成功(200/405)退出循环 → 失败查排查树后继续
4. 工具级握手：调用一个只读工具确认链接
5. ★ 排查确认「插件未启用」→ 先问用户：同意 → 启用重启后继续；拒绝 → §2.3 降级路径
6. ★ 引擎迟迟无窗口 / 疑似弹窗 / 疑似崩溃 / 轮询超限 → **启动卡死协议**
   （STARTUP_STUCK_DIAGNOSIS.md：Workbench 截图+窗口枚举 → 日志取证 → 弹窗决策表；
     窗口出现轮询上限 5 分钟，禁止盲等或重发启动）
```

### ④ 引擎内测试（优先级：能自动就不手动）

```
A. headless 跑 Spec（首选，~40s，自动退出，无需清理）：
   scripts/run_spec_headless.ps1 -ProjectPath "<项目>" -Spec "<Spec.Path>"
   ★ 必须看退出码：0=通过；1=有失败；2=零测试执行(按失败)；3=无日志；5=超时
   ★ 局限：-nullrhi 无渲染 → 截图/视觉验证/Python 交互不可用（见 AUTOMATION_TESTING.md §1.4）
B. 引擎内通道跑 Automation / PIE（需常驻引擎）
C. Python 执行（unreal 模块）——先查能力边界（AUTOMATION_TESTING.md §4）
D. 需要程序化改蓝图 → 下沉 editor-only C++ 测试辅助库（AUTOMATION_TESTING.md §5）
```

测试用例来源：任务卡「验证方法」字段 → 需求验收标准 → 都没有则 **AI 必须补写最小验证用例**并记录（交付正确性的底线）。

### ⑤ 实机验证 → ⑥ 日志取证 → ⑦ 验收勾选 → ⑧ 复盘交接

```
⑤ 截图/按键/视口交互：截图必须有路径或可引用内容，禁止「截图成功」这种无凭据表述
⑥ Saved/Logs/*.log：tail -n 100 → grep -iE "Error|Warning|ensure|check|assert" → 引用原文（时间戳+行）
⑦ 对照验收标准逐条 ✅/❌（附证据引用）；存在 ❌ → 回到对应步骤，不得宣布完成
⑧ 更新 STATUS/工作日志/勘误候选；关键经验沉淀（见 SKILL_DISTILLATION.md）
```

### 2.3 降级路径（用户拒绝启用引擎内通道时）

**触发条件（全部满足才可触发）**：①编译成功 ②引擎已用新产物启动 ③轮询失败且排查树确认插件未启用 ④经询问用户选择不启用。

**原则**：放弃的是「引擎内自动化测试」这一个手段，**不是验证义务**。

必须做的三件事：
1. **明示跳过**：交付说明写明「引擎内自动化测试被跳过（原因）」，不得含糊；
2. **补强降级验证**：实机截图/按键 + 日志取证更充分（能通过日志验证的行为绝不只靠截图）；
3. **记录到交接**：记录「通道不可用 + 原因 + 用户决策」，下次会话不重复询问。

**禁止**：假装跑过引擎内测试；把用户拒绝当「不用验证」的借口；用户已拒绝后反复纠缠。

---

## 3. Automation 设计法（从合同反推，不是凭空想测试）

### 3.1 设计六步

```
01 CONTRACT 写不变量    全部成功才提交；任一步失败全退（或对应业务不变量）
02 TRACE   追写入边界   转换、提交点、存储、脏状态、通知——不改产品代码
03 MATRIX  生成故障点   失败前/失败后/部分写入 + 成功对照组
04 ORACLE  保存前快照   值、身份、Dirty、调用次数与事件——不只看返回值
05 FOCUSED 只跑最小集   先让一个失败给出高区分度证据
06 TRIAGE  分类再修改   产品 / Case / Runner / 环境，四选一
07 EXPAND  同 Case 扩圈 相邻测试 → Full → 可见 Save/Reopen
```

**把需求拆成可观察状态**：返回值、每个被写字段、身份标识、包/对象 Dirty、后续调用次数、post-save/refresh 事件次数。**断言不只看 false，还逐项比较所有副作用**。

### 3.2 Case Matrix：先设计能否定实现的用例

以「批量 Save 原子性」为例（合同：任一 Push 失败则全部回滚、保持 Dirty、成功事件不发生）：

| Case | 故障注入 | 必须读回的 Oracle | 能抓到的经典错误 |
|---|---|---|---|
| Malformed input | 输入解析半途失败 | 目标与源都保持旧值；不 Dirty、不通知 | 直接写 live 数据，失败留半个新值 |
| Push #2 fails before write | 第一个成功，第二个写入前失败 | 全部回到 before；#3 不执行 | 只回滚失败项，没回滚已成功前项 |
| Mutates then returns false | 先改字段再返回失败 | 被改字段逐项恢复；仍 Dirty；事件为 0 | 相信返回值而没对副作用做快照 |
| Selective scope | 仅一个对象参与保存，旁路对象做 canary | 目标正确提交/回滚；无关对象与 Undo 不被触碰 | 快照范围过宽污染无关资产 |
| Success control | 全部成功 | 每项只提交一次；Dirty 清除；事件各一次 | 回滚补丁让成功路径重复写/漏通知 |

### 3.3 RUN → READ → CLASSIFY → CHANGE ONE SEAM → RERUN → BROADEN

```
01 RUN      最小 Filter：精确 test ID；Missing/empty 直接失败
02 READ     第一处偏差：Expected / Actual / fault point / first changed state
03 CLASSIFY 先分责任域（四类，见 3.4）
04 CHANGE   只改一个 seam：保留 case 与 Oracle，避免测试追着实现跑
05 RERUN    同 Case 复验：失败继续缩小；PASS 才允许扩大
06 BROADEN  逐层扩圈：相邻 focused → Full → T3 可见验证
```

> Automation 的价值来自反复跑**同一个裁判**，而不是每轮换验收方式。同一个 case 没过之前，不启动 Editor 做昂贵的人工重验。

### 3.4 失败四分类

| 分类 | 判定 | 动作 |
|---|---|---|
| **产品 Bug** | 目标对象、故障注入和 Oracle 都成立，生产状态仍错误 | 回 owning seam 修复 |
| **Case/Oracle Bug** | fixture 没命中、expected error 太宽、case 复用旧状态 | 修测试基础设施；产品结论保持未裁决 |
| **Runner Bug** | runner 没执行核心动作、退出码被管道覆盖 | 修 runner；先读 `$LASTEXITCODE` 再管道 |
| **环境/证据 Bug** | 旧 DLL、没发现测试、无最终标记、进程结果与 runner 结果冲突 | 标记 **BLOCKED**，先修运行合同 |

**规则**：Missing test、空发现、无终止标记、旧二进制或结果版本不明都算 BLOCKED，不得写成 PASS。失败能指向一个 seam 才开始修；**若多层同时失败，先缩小 case**；不要边改产品边改 Oracle 让结果变绿。

---

## 4. 三条反直觉 QA 经验（★ 必须机械执行）

1. **进程活着 ≠ 可见 QA 成立**：CPU、日志、swapchain 都不能证明用户看得到界面；必须绑定真实可见窗口并记录 HWND/标题/矩形（截图证据）。
2. **外层 exit code ≠ 产品结果**：分别记录命令完成标记、Automation summary、编辑器退出码与已知启动噪声；任何例外必须保留警告，不能悄悄吞掉。
3. **最后一次写入会让旧绿灯失效**：一次「最终编译」后又改源码 → 旧证据全部 INVALIDATED，在真正最终源码上重跑。**靠记忆执行这条规则必然失败，必须机械化。**

---

## 5. 状态语义

```
✓ PASS    证据满足（有对应版本源码的真实输出）
× FAIL    行为错误（附 Expected/Actual）
! BLOCKED 环境/入口阻塞（说明缺什么，禁止绕过产品入口制造通过）
○ NOT RUN 明确未执行（诚实声明不能宣称的能力）
```

---

## 6. 验证分工原则

| 类别 | 谁做 |
|---|---|
| 「能否 X」二元事实（资产能创建吗？窗口能打开吗？字段对吗？） | **AI 自动化**（Spec + Python + 截图） |
| 主观判断（审美、图标观感、交互手感） | 用户 |
| 复杂多步人工交互流 | 用户（AI 准备脚本/清单） |

> 每阶段开始时审视验收条款，**能自动化的不推给用户**。演示/验证完毕立即恢复用户屏幕（关测试窗口 + 释放窗口锁定）。

---

## 7. 常见失败场景速查（原 TEST_CLOSED_LOOP 独有内容，措辞已泛化）

| 场景 | 处理 |
|---|---|
| 引擎在跑但引擎内通道 000，且插件未启用 | **先问用户是否启用**（附指引 `MCP_CHANNELS.md` §6.3）；拒绝 → 降级路径（§2.3） |
| 引擎在跑但引擎内通道 000，插件已启用 | 排查树：AutoStart → 端口监听 → 探测可达（`MCP_CHANNELS.md` §5） |
| 编译配置找不到 | `get_run_configurations` 确认 projectPath；Rider 需加载 .sln/.uproject |
| MCP 握手工具不存在 | 用 tools/list 看真实工具名，禁止臆测 |
| 自动化测试没有现成的 | 补写最小测试（Automation 或 Python），记录到任务卡 |
| PIE 无法启动 | 检查是否有未保存关卡/编译版本；退回引擎内通道的编辑器操作 |
| 日志没找到 | 检查项目路径（Saved 在项目根下）；确认引擎确实运行过该项目的进程 |
| 时间超时 | UE 编译/启动本就慢：编译给 5-10 分钟，引擎启动 1-3 分钟，轮询 50s 不够可继续 |
| **Spec 卡在 `FWaitForInteractiveFrameRate`（3 fps，要 ≥10）** | **改用 headless**（治本）；或实机通道 pin 置顶 + **物理点击窗口中心**激活（仅置顶无效；`t.idlewhennotfocused 0` 实测无效） |
| MCP 调用超时/返回 `-32001` | **先查进程**：可能已启动成功。确认未启动才重试——否则造成双引擎实例（SKILL.md 硬规则 4） |
| 编译报「X 不是成员」「函数不接受 N 个参数」 | **先查 include 缺失**（UHT 不做类型检查，UHT 通过 ≠ 编译通过）。全盘搜类型名/枚举名确认定义与引入 |
| 引擎启动崩溃：`Code not found for generated code (package /Script/X)` | 静态对象在 **DllMain** 期做了堆分配/调用引擎 API/跨 TU 静态访问 → 改 POD 链表 + 延迟 flush（`UE_RUNTIME_GOTCHAS.md` §1） |
| InstancedStruct 序列化崩溃 | 裸 `FMemoryWriter/Reader` 无 name map → 用 **`FObjectWriter`/`FObjectReader`**；且 `Defaults` 必须传真实默认实例（`UE_RUNTIME_GOTCHAS.md` §2） |
| 接口 BlueprintNativeEvent 覆写不生效 | 5.8 下 C++ override `_Implementation` 会被静态 thunk 绕过；且**禁止虚表直调**（必须 `Execute_*`）。BP 是唯一完整实现路径（`UE_RUNTIME_GOTCHAS.md` §3） |
| 双击资产无反应 | `OpenAssets` 返回 `Unhandled` = 静默无操作（**不是 fallback**）→ 必须 `FSimpleAssetEditor::CreateEditor` + 返回 `Handled`（`UE_RUNTIME_GOTCHAS.md` §6） |
| 残留引擎进程 / 屏幕残留置顶红框 | PID 跟踪 `cleanup` + `window_release`（`PROCESS_HYGIENE.md`） |
| Slate 控件在快照里隐形 / graph 上无法操作 pin | 项目侧 role 注册（`SLATE_AUTOMATION.md` §3）+ ref 操作（`PITFALLS_SLATE_UI.md` §2） |
| 引擎内 MCP 全部超时 | 模态框死锁 → desktool 救援四步（`PITFALLS_SLATE_UI.md` §3） |
