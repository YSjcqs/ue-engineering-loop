# 进程与窗口卫生（清理纪律）

> **强制沉淀的能力项**：AI 每个阶段结束必须清理自己启动的引擎进程；用过窗口控制的必须释放。
> 起因：一次开发中因反复启动引擎验证，残留多个引擎进程；另一次因未释放桌面自动化工具的窗口锁定，屏幕上留下红框。

---

## 1. PID 跟踪协议（禁止按进程名杀）

### 1.1 为什么不能 `Stop-Process -Name UnrealEditor`

- 会**误杀用户自己启动的引擎**（用户可能正在用它做人工测试/验证）。
- 无法区分「AI 启动的」和「用户启动的」。

### 1.2 三步协议

```powershell
# 步骤 1（启动前）：记录基线 = 此刻已存在的引擎 PID（这些不是 AI 的）
engine_pid_tracker.ps1 -Action snapshot -ProjectPath "<uproject 目录>"

# 步骤 2（启动后）：diff 出「新增 PID」= AI 自己启动的
engine_pid_tracker.ps1 -Action diff -ProjectPath "<uproject 目录>"

# 步骤 3（结束）：只杀 AI 自有的 PID；无 baseline 时拒绝按名杀
engine_pid_tracker.ps1 -Action cleanup -ProjectPath "<uproject 目录>"
```

### 1.1.1 ★ 为什么要带 `-ProjectPath`（跨项目误杀防护，2026-09 修复）

**故障路径**（修复前真实存在的风险）：
```
A 项目 snapshot（baseline 记录 A 的引擎 PID）
   ↓ 切换到 B 项目
B 项目 diff / cleanup
   ↓ B 的引擎 PID 不在 A 的 baseline 里
   ↓ 被误判为「AI 启动的」
   ↓ 💀 杀掉用户在 B 项目的编辑器
```

**防护机制（fail-closed）**：
1. baseline 文件名带项目 key（路径 MD5 前 8 位）：`.engine_baseline_<key>.json`；
2. baseline 内容记录 `project` 与 `projectKey`；
3. `diff` / `cleanup` 时校验 key **一致才执行**，不一致则**报错退出**（绝不因歧义而杀进程）；
4. 无 `projectKey` 的**旧格式 baseline 一律拒绝使用**（提示删除后重新 snapshot）；
5. 未传 `-ProjectPath` 时回退 `global` key，并**打印 WARN** 提醒跨项目风险。

> **纪律**：多项目/多会话/并行会话场景下，`-ProjectPath` **不是可选项**。不传就失去了本脚本存在的意义。

**核心规则**：
```
□ snapshot 必须在【启动引擎之前】执行（启动后执行会把 AI 自己的 PID 记进基线 → cleanup 拒杀）
□ cleanup 只杀「当前 PID 集合 − baseline 集合」
□ 没有 snapshot 记录时，cleanup 报错退出，绝不回退到按名杀
□ cleanup 后删除状态文件（下次会话重新开始）
```

### 1.2.1 ⚠️ 基线污染陷阱：「正在退出」的进程（实测）

**现象**（2026-09-02 评审中实测）：一次 headless Spec 跑完后，`$proc.HasExited` 已为 `true`、脚本也读到了退出码，但**进程仍在做收尾**（卸载模块、flush 日志），此刻的 `Get-Process` **仍能查到它**。

若这时执行 `snapshot`，该残留 PID 会被当成「用户已有的进程」写进 baseline → **基线污染**：后续 `cleanup` 会认为它不是 AI 的，**永远不清理**。

**防护**：
1. `snapshot` 前先确认无引擎进程；若有，先判明归属（对比上一次会话的 baseline / 看启动时间）。
2. headless 跑完后**等 3-5 秒**再执行 snapshot。
3. 若 baseline 里出现**意料外**的 PID，停下来查明来源，**不要直接沿用**——它很可能是自己上一轮的残留。

### 1.2.2 PowerShell 陷阱：管道会覆盖 `$LASTEXITCODE`

```powershell
script.ps1 | Select-String "VERDICT"      # ❌ $LASTEXITCODE 变成 Select-String 的退出码（常为 0）
Write-Host $LASTEXITCODE                  #    误报成功！

$out = & script.ps1 2>&1                  # ✅ 先拿退出码再处理输出
$code = $LASTEXITCODE
```
**规则**：需要依据退出码判定成败时，**先读 `$LASTEXITCODE` 再做管道/格式化**。
（对 `run_spec_headless.ps1` 尤其重要——它的 `exit 2`「零测试执行」一旦被覆盖成 0，就是假成功。）

### 1.3 孤儿进程检查

cleanup 后扫描：`ShaderCompileWorker` / `UbaAgent` / `CrashReportClientEditor` / `UnrealVersionSelector`。

---

## 2. 桌面自动化窗口释放（必做）

任何桌面自动化通道（如 Workbench 类 MCP 工具、截图/按键脚本）执行过 `window_control`（pin/置顶/最小化/最大化）后，**必须**调用对应的释放动作（如 `desktool.window_release`）：

```json
{"serverName":"<桌面自动化服务>","toolName":"<服务名>.window_release","arguments":{}}
```

**不释放的后果**：置顶红框 overlay **残留在屏幕上**（即使引擎进程已退出，overlay 也不消失）。

> 返回 `released: null` 属正常（锁定随进程退出已失效），但释放调用本身是清理 overlay 的动作。

---

## 3. 阶段结束清理清单（固定动作）

```
□ 1. 引擎进程：PID 跟踪 cleanup（只杀 AI 自有的）
□ 2. 孤儿进程：ShaderCompileWorker / UbaAgent / CrashReportClientEditor
□ 3. 桌面自动化：window_release（若用过 window_control）
□ 4. 用户屏幕：关闭演示/测试窗口；释放锁定红框
□ 5. 测试资产：删除或保留并登记（避免污染内容目录）
□ 6. 临时脚本产物：日志/状态文件按需清理
□ 7. git：阶段成果独立 commit
□ 8. STATUS.md：看板 + 进度表 + 交接记录更新
```

---

## 4. 互斥/排队导致的「假死」

| 现象 | 真因 | 处理 |
|---|---|---|
| 后台 UBT 编译时，Rider 运行配置 MCP 超时 | **UBT 全局 `-WaitMutex` 锁**，Rider 的「Build 再 Run」在排队 | 等后台编译结束。**不是启动失败** |
| 引擎已启动但 MCP 长时间不就绪 | 引擎冷启动慢（磁盘/索引忙时每模块 1-2 秒） | 延长轮询；或改用 headless（无需 MCP） |
| Live Coding 激活时 UBT 编译失败 | DLL 被占用 | 关闭引擎后编译 |

**等待期利用**：等待编译/启动时，可做**零冲突工作**（读阶段文档、读引擎源码、写代码、更新文档），不要空等。

---

## 5. 轮询技巧

| 场景 | 错误做法 | 正确做法 |
|---|---|---|
| 等编译完成 | 轮询日志文件内容 | **轮询进程退出**（日志是块缓冲，长时间不 flush） |
| 等 MCP 就绪 | 单次探测 | 循环探测 + 日志标志位（如 `Starting MCP server on port`） |
| 等引擎初始化 | 固定 sleep | 日志驱动（匹配 `Engine Initialization.*Total time`） |

> **采样间隔陷阱**：单个 `cl.exe` 生命周期可能只有 13-37 秒，60 秒采样间隔会落在两个模块编译的空档 → 误判「已完成」。用「连续 N 次采样无进程」判定，或结合产物时间戳。
