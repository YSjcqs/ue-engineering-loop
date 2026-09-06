# MCP 通道指南（MCP_CHANNELS）

> 三源合一：通道能力与排查（原 MCP_ENVIRONMENT）+ 配置与启用（原 MCP_SETUP_GUIDE）+ 环境快速接入（原 ENVIRONMENT_QUICKSTART）。
> 通用纪律（先探测后使用、时序纪律、降级路径）以 SKILL.md 为准；本篇解决「通道怎么用、连不上怎么办、环境怎么配」。

---

## 1. 四通道总览与默认实例

| 通道 | 职责 | 默认实例 | 端点 | 依赖条件 |
|---|---|---|---|---|
| **IDE/构建通道** | 编译、运行配置、IDE 静态检查、调试 | RiderMCP（Rider 2025.2+ 内置 MCP Server） | `http://127.0.0.1:64482/stream` | Rider 运行 + MCP Server 已启用 |
| **引擎内通道** | 引擎内自动化测试、编辑器操作、Python、Slate 控件树 | UnrealEngineMCP（仅 UE5.8 原生插件 `ModelContextProtocol`） | `http://127.0.0.1:8000/mcp` | ①引擎在跑 ②插件已启用 ③AutoStart 已开 ④端口监听 |
| **实机通道** | 截图、按键、视口交互、死锁救援 | Workbench | `http://127.0.0.1:3939/mcp` | 工作台运行中 |
| **日志终审** | 一切结论的最终裁判 | 直接读 `<Project>/Saved/Logs/*.log` | — | 无需任何通道 |

> 🚫 **引擎内通道明确不采用社区 MCP 方案**（gimmeDG/chongdashu/ChiR24 等）：官方维护、与引擎版本绑定，社区方案不作为替代或备选。
> 端口随环境变化；换环境改 `env_health_check.ps1 -Endpoints` 参数即可，纪律不变。

---

## 2. 各通道能力与典型工具

### 2.1 IDE/构建通道（RiderMCP）

> **实测版本（2026-09-06）**：JetBrains Rider MCP Server **2026.2.1**，`tools/list` 返回 **75 个工具**。除构建类工具外还含 UE 桥接工具（`ue_health`/`ue_status`/`ue_execute_python`/`ue_get_logs`/`ue_play`/`spawn_actor`/`take_screenshot`/`search_assets`/蓝图导入导出等）与调试（xdebug_*）、git、性能分析（dotTrace*）、重构（rename/extract 等）工具——工具清单以实际 `tools/list` 为准。

| 工具 | 用途 | 何时用 |
|---|---|---|
| `build_solution_start` | **方案级构建（★ 编译主入口，SKILL.md §3.1）**；**异步**——立即返回 `sessionId`，轮询 `build_solution_state` 取结果；**已有构建在跑时直接报错**（`Fails if a build is already running`） | 日常/完整构建；项目方案与引擎方案均可 |
| `build_solution_state` | 查询构建状态：`state` ∈ Running/Completed/Cancelled/NotFound + 增量累计的 `problems` + 完成后的 `buildIsSuccess`；可反复轮询 | 与 build_solution_start 配套轮询 |
| `get_run_configurations` | 列出运行配置 | 找「启动编辑器 / Uproject」配置 |
| `execute_run_configuration` | 执行运行配置（可设 timeout/waitForExit） | 按运行配置编译/启动引擎（辅助入口） |
| `get_file_problems` | 文件级 IDE 检查（error/warning） | 改完代码立即静态检查 |
| `get_solution_projects` | 列出当前打开解决方案的全部工程 | 确认方案内容 / 获取 rootFolder |
| `get_project_modules` / `get_project_dependencies` | 项目模块/依赖 | 确认模块依赖关系 |
| `find_files_by_glob` / `search_*` 系列 | 搜文件/文本/符号 | 快速定位 |
| 调试相关工具 | 断点、调用层级、符号查询 | bug 排查（DebugGame Editor 下断点才有效） |

**★ build_solution_start 实测参数语义（2026-09-06）**：
- `rootFolder`（强烈建议显式传）：Rider 当前打开的解决方案根目录；不传时服务端报「Unable to determine the target project」并列出当前打开的项目。
- `rebuild`（boolean，**默认 false = 增量**）：★ **R8 禁令的直接管辖对象——未经用户一次一确认，禁止传 `rebuild:true`**。
- `filesToRebuild`（可选文件列表）：按文件编译。
- **Unreal 语义**（官方描述）：编辑器已连接且 Live Coding 可用 → 触发 **Hot Reload 编译**；否则由 **UBT 编译主 Editor target**。
- 实测：对 `F:/Unreal/Blank`（引擎解决方案）发起增量构建，返回 sessionId 后 `build_solution_state` 轮询 2 分钟+ 仍 `Running` 且 `problems:[]`——引擎级增量构建以**分钟**计，轮询间隔建议 20~30s，不要因慢就重发构建。

**★ MCP 会话协议实测坑（2026-09-06）**：streamable-HTTP 会话**不能跨进程/连接复用**——用 curl 分两次调用（第一次 initialize、第二次 tools/call 带 session-id）会报 `Streamable HTTP session not found`。**必须在同一进程内完成 initialize → notifications/initialized → tools/call 三步**。用 `scripts/rider_call.py` 即可（自动完成三步）：
```bash
python scripts/rider_call.py '{"name":"get_solution_projects","arguments":{"rootFolder":"F:/Unreal/Blank"}}'
```

**使用要点**：
- 工具需**显式传项目路径参数**（`rootFolder` / `projectPath`）；不传时服务端返回「Unable to determine the target project」并列出当前打开的项目（以此确认 rootFolder）。判据：返回的配置/工程里应包含当前项目。
- **Live Coding 锁**：引擎在跑且 Live Coding 活跃时，UBT 编译会失败（DLL 占用）→ 编译前先关引擎（或接受 Hot Reload 语义，见上）。
- 调试需在 **DebugGame Editor** 配置下断点才有效。
- 编译入口优先级、R8 rebuild 禁令 → `UE_BUILD_PITFALLS.md` §1.5/§1.6。

### 2.2 引擎内通道（UnrealEngineMCP）

启用后引擎内运行本地 HTTP 服务器（游戏线程）：
- 生成/放置 Actor、配置灯光、创建材质实例
- **Slate 控件树操作**（SlateInspectorToolset，ref 级）→ `SLATE_AUTOMATION.md`
- **运行自动化测试（Automation Tests）**
- 执行 Python（`unreal` 模块 API）

> 所有工具清单以实际连接后 `tools/list` 返回为准，**禁止凭文档臆测工具名**。调用约定三套并存见 `SLATE_AUTOMATION.md` §1。

### 2.3 实机通道（Workbench）

**截图、按键操作、视口交互、窗口管理**。用于：
- 渲染/交互/UI 的**视觉证据**（截图）
- 无法自动化的交互流程（按键序列）
- **模态框死锁救援**（游戏线程被模态框阻塞时的唯一通道）→ `PITFALLS_SLATE_UI.md` §3

---

## 3. 连接检查（每次会话第一步）

### 3.1 快速探测（无脚本时）

```bash
# Bash / Git Bash
curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://127.0.0.1:64482/stream   # 期望 200
curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/mcp       # 期望 200/405
curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3939/mcp       # 期望 405（只收 POST = 在线）
```

```powershell
# PowerShell
Test-NetConnection -ComputerName 127.0.0.1 -Port 64482 -InformationLevel Quiet
Test-NetConnection -ComputerName 127.0.0.1 -Port 8000  -InformationLevel Quiet
Test-NetConnection -ComputerName 127.0.0.1 -Port 3939  -InformationLevel Quiet
```

进程与端口：
```bash
tasklist | grep -iE "UnrealEditor|rider64"     # 引擎 / Rider 是否在跑
netstat -ano | grep -E "64482|8000|3939"       # 端口是否监听
```

### 3.2 健康检查脚本

```powershell
powershell -ExecutionPolicy Bypass -File "<本技能>/scripts/env_health_check.ps1" -ProjectPath "<uproject 所在目录>"
# 端点可参数化：
#   -Endpoints "IDE_BUILD=127.0.0.1:64482/stream,ENGINE_MCP=127.0.0.1:8000/mcp,DESKTOP=127.0.0.1:3939/mcp"
```

### 3.3 检查结果解读

| 结果 | 含义 | 下一步 |
|---|---|---|
| IDE 构建 `200` | 在线 | 可用 |
| IDE 构建 `000`/超时 | 不可达 | 确认 Rider 已启动且 MCP Server 已启用；仍不可达 → 用 §6.2 标准话术提示用户 |
| 引擎内 `200`/`405` | **在线** | 可用（405 = 只收 POST，正常） |
| 引擎内 `000`/超时 | 不可达 | **进入 §5 排查树**（注意时序纪律：编译阶段探测必为 000，属正常） |
| 实机 `405` | 在线 | 可用 |
| 实机 `000` | 不可达 | 确认工作台已启动 |

> ⚠️ **两种 UEMCP 检查的时机语义**：①会话启动健康检查只反映「当前运行的引擎实例」状态（可能是旧代码进程），仅作情报；②闭环步骤③的链接检查必须以「编译成功 + 引擎已用新产物启动」为前提。**编译阶段禁止探测/断言引擎内通道**（SKILL.md 硬规则 1）。

---

## 4. 链接后的验证（防「假链接」）

探测 200/405 只说明 HTTP 端口活着，**不保证工具可用**。链接成功后**必须做一次工具级握手**：
- 调用一个只读工具（如 `tools/list`、`Windows`、`get_connection_status`）确认能返回结果；
- 握手中的任何异常（工具不存在、超时）都要记录并进入排查。

> 规则：**没有完成工具级握手，不得宣称「MCP 已链接」**。

---

## 5. 引擎内通道连接故障排查树

### 5.1 实测案例（2026-08-30 · F:/Unreal/Blank）

**现象**：`UnrealEditor.exe` 在跑，但探测 `http://127.0.0.1:8000/mcp` 返回 `000`。

**排查**：进程在跑 ✅ → 8000 无监听 ❌ → `.uproject` 的 Plugins 无 `ModelContextProtocol` ❌（根因）。
**结论**：「引擎在跑」与「引擎内通道可用」是两回事。排查顺序：插件启用 → AutoStart → 端口监听 → 探测可达，缺一即 000。

### 5.2 排查树（按顺序，找到断点即修复）

```
引擎内通道探测失败（000/超时）
  │
  ├─① 是否在编译阶段探测？（★ 时序纪律 SKILL.md 硬规则 1）
  │    是 → 此探测结果无效，等「编译成功 + 引擎用新产物启动」后再探测
  │    否 ↓
  ├─② 引擎是否在运行？
  │    否 → 通过 IDE 构建通道执行「启动编辑器」运行配置，或请用户启动引擎
  │    是 ↓
  ├─③ 项目是否启用引擎内 MCP 插件（如 UE 5.8 原生 ModelContextProtocol）？
  │    检查 .uproject 的 Plugins 数组；或编辑器 Edit > Plugins 搜索
  │    否 → ★ 先与用户交流：询问是否启用插件（附启用指引 §6.3）
  │         ├─ 用户同意 → 按 §6.3 启用，重启编辑器，回到 ⑥
  │         └─ 用户拒绝/不启用 → 放弃引擎内通道，降级到 实机 + 日志（SKILL.md R7）
  │                              并在任务卡/交接记录标注「引擎内自动化测试被跳过」
  │    是 ↓
  ├─④ AutoStart 是否开启？（UE 5.8 默认 false！）
  │    编辑器 Editor Preferences > General > Model Context Protocol > Auto Start Server
  │    否 → 开启 AutoStart，重启编辑器；或临时执行控制台命令 ModelContextProtocol.StartServer
  │    是 ↓
  ├─⑤ 端口是否监听？
  │    netstat -ano | grep 8000
  │    否 → 检查插件是否在引擎启动时报错（Saved/Logs）；确认端口未被占用/被改
  │    是 ↓
  └─⑥ 探测可达 + 工具级握手？
        期望 200/405 且只读工具能返回。仍失败 → 检查防火墙 / MCP 版本兼容 / 客户端配置 URL
```

> ⚠️ **只有 ③ 的「询问用户」是允许与用户交互的分支**；其余步骤 AI 应自主排查，不要用问题打断用户。
> 本排查树只在闭环步骤③（编译成功 + 新产物启动）时执行；完整实测复盘见 `CASE_STUDY_UEMCP_OUTAGE.md`。

---

## 6. 配置与启用

### 6.1 ⚠️ 配置文件位置与「双文件不一致」陷阱

**可能同时存在两份配置**：`C:\Users\<用户名>\.workbuddy\mcp.json` 与 `C:\Users\<用户名>\.codebuddy\mcp.json`。

**实测风险（2026-09-02 确认）**：两份内容可能不一致（一边指向当前项目、一边指向旧项目残留），AI 不传路径参数调用时会拿到**旧项目**的运行配置。

**处置规则**：
1. **AI 一律调用时显式传项目路径参数**，不依赖配置里的 `IJ_MCP_SERVER_PROJECT_PATH`（与哪个文件生效无关，始终安全）；
2. 发现两份不一致 → **提醒用户把两者都更新为当前项目目录**；
3. `env_health_check.ps1` 会列出配置值供比对（含 DRIFT 告警）；
4. 不确定时以实际项目 `.uproject` 位置为准。

> **同类陷阱：技能目录双副本**——技能可能同时存在于 `.codebuddy\skills\` 与 `.workbuddy\skills\`，会话若加载旧副本则所有规则不生效。修改技能后务必同步或删除旧副本。

### 6.2 可粘贴配置 + IDE 构建通道未连接时的标准话术

**客户端配置**（Windows WorkBuddy 风格：`C:\Users\<用户名>\.workbuddy\mcp.json`；是 `mcp.json` **不是** `.mcp.json`；与已有 `mcpServers` **合并**，不覆盖其他服务器）：

```json
{
  "mcpServers": {
    "RiderMCP": {
      "serverType": "http",
      "url": "http://127.0.0.1:64482/stream",
      "headers": {
        "IJ_MCP_SERVER_PROJECT_PATH": "<实际项目目录>"
      }
    },
    "UnrealEngineMCP": { "serverType": "http", "url": "http://127.0.0.1:8000/mcp" },
    "Workbench": { "serverType": "http", "url": "http://127.0.0.1:3939/mcp" }
  }
}
```

**激活步骤（MCP 不会自动生效，必须手动信任）**：
1. 确认 Rider 已启动，`Settings | Tools | MCP Server` 已启用（2025.2+ 内置）；
2. 将上方 JSON 合并进客户端 MCP 配置文件（`IJ_MCP_SERVER_PROJECT_PATH` 改成当前项目实际目录）；
3. 打开客户端**连接器管理页**（右上角「自定义连接器」入口），找到新加的服务器，点击**「信任」**激活；
4. 回复 AI「已连接」，AI 重新健康检查后继续。

**IDE 构建通道未连接时的可粘贴话术**：

> **IDE 构建通道（RiderMCP）未连接到本会话（HTTP 不是 200），编译/运行配置无法执行。** 请确认：① Rider 已启动且 MCP Server 已启用；② 在客户端 MCP 配置中合并上方 RiderMCP 条目（项目路径改为当前项目）；③ 在连接器管理页点击「信任」激活。完成后回复「已连接」，我会重新健康检查并继续。

**附带提示**：引擎启动弹 `Missing Modules — Would you like to rebuild them now?` 是 UE 标准路径——交给用户在引擎/Rider 里点 **Yes** 由 IDE 编译；AI 不绕路跑编译脚本。

### 6.3 UE 5.8 原生 Unreal MCP 插件启用流程

> 适用：项目未启用插件、用户同意启用时引导；或交用户手动操作。

1. **确认引擎版本**：UE 5.8（原生 MCP 插件随 5.8 提供）；版本不符 → 告知用户，走放弃分支。
2. **启用插件**：编辑器 `Edit > Plugins`，搜索 **Unreal MCP**，勾选启用（依赖 **Toolset Registry** 自动启用），提示重启时重启。
3. **开启 AutoStart**：`Editor Preferences > General > Model Context Protocol` → **Auto Start Server**。
4. **（可选）生成客户端配置**：控制台（~）执行 `ModelContextProtocol.GenerateClientConfig`。
5. **重启编辑器**，轮询 `http://127.0.0.1:8000/mcp` 到 200/405，再做工具级握手（§4）。

> ⚠️ 插件为**实验性**：仅 localhost、无鉴权、API 可能变化。
> ⚠️ **`bAutoStartServer` 默认 false**——即使插件已启用，8000 也不会自动监听（「引擎在跑但不通」最常见原因）。持久化配置必须写：
> ```
> <Project>/Config/DefaultEditorPerProjectUserSettings.ini
> [/Script/ModelContextProtocolEngine.ModelContextProtocolSettings]
> bAutoStartServer=True
> ```
> ⚠️ **不是** `DefaultEngine.ini`（写那里不生效，实测踩坑）。临时方案：控制台命令 `ModelContextProtocol.StartServer`（Python：`unreal.SystemLibrary.execute_console_command(None, 'ModelContextProtocol.StartServer')`）。重启后日志出现 `Starting MCP server on port 8000` 即成功。

---

## 7. 引擎内通道实测经验（UE 5.8）

- **WP（World Partition）关卡**：运行时 `EditorLevelLibrary.spawn_actor_from_class` 生成的 Actor **不会复制进 PIE 世界**，BeginPlay 不触发。验证 Actor 运行逻辑改用 **Simulate 模式**（`ue_play mode=simulate`）；或 `save_map(world, '/Game/Xxx')` 保存关卡后再 PIE。
- **HTTP 直连**（无 MCP 客户端时）：带 `Mcp-Session-Id` 头，流程 initialize → notifications/initialized → tools/call；meta-tool 模式下 `list_toolsets`/`describe_toolset`/`call_tool` 是顶层入口。
- **`build_solution_start` 的观测提示**：历史记载在引擎解决方案上做过全队列构建 + 假错误的案例（见 `UE_BUILD_PITFALLS.md` §1.5）——以实测为准，出现症状记录并报告，不作禁令。
- 所有通道的工具清单以实际连接后 `tools/list` 返回为准，**禁止凭文档臆测工具名**。
