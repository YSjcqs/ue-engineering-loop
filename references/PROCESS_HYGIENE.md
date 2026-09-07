# 进程与窗口卫生（清理纪律）

> **强制沉淀的能力项**：AI 每个阶段结束必须清理自己启动的引擎进程；用过窗口控制的必须释放。
> 起因：一次开发中因反复启动引擎验证，残留多个引擎进程；另一次因未释放桌面自动化工具的窗口锁定，屏幕上留下红框。

---

## 1. PID 跟踪协议（禁止按进程名杀）

### 1.1 为什么不能 `Stop-Process -Name UnrealEditor`

- 会**误杀用户自己启动的引擎**（用户可能正在用它做人工测试/验证）。
- 无法区分「AI 启动的」和「用户启动的」。

### 1.2 四步协议：时间差只做观察，精确登记才构成所有权

```powershell
# 步骤 1（启动前）：创建隔离 run，并记录诊断基线
$out = & .\engine_pid_tracker.ps1 -Action snapshot -ProjectPath "<uproject 目录>"
$runId = ($out | Select-String '^RUN_ID=').Line.Split('=')[1]

# 步骤 2（启动）：必须从启动器拿到精确 PID
$proc = Start-Process -FilePath "<UnrealEditor.exe>" -ArgumentList '<uproject>' -PassThru

# 步骤 3（立即登记）：绑定 PID + 创建时间 + exe + 命令行 + 项目
.\engine_pid_tracker.ps1 -Action register -ProjectPath "<uproject 目录>" -RunId $runId -Pid $proc.Id

# 可选观察：diff 只显示新增候选，绝不把候选称为 AI-owned
.\engine_pid_tracker.ps1 -Action diff -ProjectPath "<uproject 目录>" -RunId $runId

# 步骤 4（结束）：只处理已登记且身份复核一致的 PID
.\engine_pid_tracker.ps1 -Action cleanup -ProjectPath "<uproject 目录>" -RunId $runId
# 优雅关闭失败时，只有获得本次明确授权后才加 -Force。
```

### 1.2.1 为什么不能用 `当前 PID − baseline` 证明所有权

用户可能在 snapshot 后手动启动另一个编辑器。它同样出现在差集中，但不属于 AI。旧算法会把这个用户进程误判为 AI-owned；因此：

1. `snapshot` 只创建 run 和诊断基线；
2. `diff` 输出 `CANDIDATES_NOT_OWNERSHIP_PROOF`，不写所有权文件；
3. `register` 只接受启动器返回的精确 PID，并记录进程名、可执行路径、创建时间、命令行和项目关联；
4. `cleanup` 在终止前重新核验全部身份字段，检测 PID 复用时 fail-closed；
5. `-ProjectPath` 与 `-RunId` 均为必填，解析失败不回退 global；并行会话各用独立 run；
6. 状态写入 `%LOCALAPPDATA%\ue-engineering-loop\process-state`，不污染技能目录或项目仓库；
7. 默认只请求优雅关闭；`-Force` 需要对本次清理的明确授权，失败记录保留以便复查。

**核心规则**：
```
□ 未经 register 的 PID 永远不得由 cleanup 终止
□ 时间差、进程名、端口归属都不能单独证明所有权
□ 身份字段不一致或项目关联不明时 fail-closed
□ cleanup 只有在全部登记对象已退出后才删除 run 状态
```

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

cleanup 后可只读扫描 `ShaderCompileWorker` / `UbaAgent` / `CrashReportClientEditor` / `UnrealVersionSelector` 并报告 PID。它们不自动继承主编辑器的所有权，除非启动时也被精确登记，否则不得终止。

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
□ 1. 引擎进程：只 cleanup 本 run 已 register 且身份复核一致的 PID
□ 2. 孤儿进程：仅报告 ShaderCompileWorker / UbaAgent / CrashReportClientEditor，不按名终止
□ 3. 桌面自动化：window_release（若用过 window_control）
□ 4. 用户屏幕：关闭自己创建的演示/测试窗口；释放锁定红框
□ 5. 测试资产：按用户授权删除，或保留并登记
□ 6. 临时脚本产物：只清理本 run 的状态与日志
□ 7. git：仅在用户授权或仓库规则要求时独立 commit
□ 8. Current Truth：可写时更新 STATUS；只读任务写入最终回复
```

---

## 4. 互斥/排队导致的「假死」

| 现象 | 真因 | 处理 |
|---|---|---|
| 后台 UBT 编译时，Rider 运行配置 MCP 超时 | **UBT 全局 `-WaitMutex` 锁**，Rider 的「Build 再 Run」在排队 | 等后台编译结束。**不是启动失败** |
| 引擎已启动但 MCP 长时间不就绪 | 引擎冷启动慢（磁盘/索引忙时每模块 1-2 秒） | 按上限轮询并转取证（见 `STARTUP_STUCK_DIAGNOSIS.md`）；或改用 headless（无需 MCP） |
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
