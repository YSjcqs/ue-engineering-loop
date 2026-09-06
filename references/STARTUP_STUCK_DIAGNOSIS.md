# 引擎启动卡死与弹窗排查协议（STARTUP_STUCK_DIAGNOSIS）

> **解决的真实问题**：agent 启动引擎后，屏幕上出现强制交互弹窗（重建模块 / 崩溃报告器 / Assert / 项目迁移…）或引擎崩溃，agent 却在**循环等待、看似无响应**，甚至重发启动造成双实例。
>
> **核心原则**：启动阶段是「黑盒窗口期」——引擎内 MCP(:8000) 未就绪、游戏线程可能被弹窗阻塞，此时**唯一的眼睛是实机通道（OS 层）**。任何疑似卡死，第一动作是 **Workbench 截图 + 窗口枚举取证**，第二动作是**读日志**，然后才谈处置。**禁止继续盲等、禁止重发启动。**

---

## 1. 触发信号（任一命中即进入本协议）

| # | 信号 | 说明 |
|---|---|---|
| S1 | 编译 `Completed` + `buildIsSuccess:true` 后，超过 **5 分钟**引擎主窗口仍未出现 | 常规启动 1–3 分钟；超时即异常（注意：先确认没有第二次编译在排队） |
| S2 | 引擎进程在跑，但 :8000 轮询 10 次（~50s）全失败，且排查树「插件/AutoStart」均正常 | 进程活着 ≠ 引擎可用；可能被弹窗挡住或卡在加载 |
| S3 | `execute_run_configuration` 启动超时，查进程后**进程在但无主窗口** | 超时 ≠ 失败（硬规则 4）；进程在 + 无窗口 = 疑似弹窗/卡加载 |
| S4 | headless Spec 超过基线（~40s）数倍未退出 | 先查进程与日志，不盲目 kill |
| S5 | 用户报告「屏幕上有弹窗 / 编辑器卡住了」 | 直接进入本协议 |

---

## 2. 标准排查流程（截图 → 窗口 → 日志 → 决策）

### 2.1 第一步：实机通道取证（永远第一动作，不做猜测）

```bash
# 工具名以 tools/list 实际返回为准（desktool 前缀）
python scripts/wb_call.py desktool desktool.screenshot '{}' shot.txt     # 全屏截图
python scripts/wb_call.py desktool desktool.window_list '{}' wins.txt    # 枚举顶层窗口
```

- **判读截图**：有无模态弹窗、**弹窗标题是什么**（弹窗标题几乎总能直接定位问题，见 §2.3 决策表）。
- **窗口列表**：找 `UnrealEditor` 主窗口 / 崩溃报告器窗口（标题常含 `UnrealEditor-CrashReporter` / `Error` / 项目名）。
- agent **读不了图**（模型返回 Content filtered）→ 改用窗口标题 + `desktool.find_element` 定位控件，**禁止猜坐标**（`PITFALLS_SLATE_UI.md` §7）。

### 2.2 第二步：日志取证（与截图并行）

```bash
# 运行日志
tail -n 100 "<Project>/Saved/Logs/<Project>.log"
grep -iE "error|fatal|assert|ensure|crash|missing|failed|dialog" <log>
# 崩溃取证
ls "<Project>/Saved/Crashes/"           # 每次崩溃一个目录：CrashContext.xml + .dmp + 日志副本
ls "$LOCALAPPDATA/UnrealCrashReport/"   # 引擎级崩溃报告器数据
```

- **引擎根本没起来**（无新日志文件 / mtime 未更新）：进程没走到日志阶段 → 查启动配置/工作目录/磁盘权限，回报用户。
- **有 `Fatal` / assert 行**：引用原文（时间戳+行）作为根因证据。

### 2.3 常见弹窗类型与处置决策表

| 弹窗 | 识别特征 | 处置 | 谁做 |
|---|---|---|---|
| **Missing Modules**（Would you like to rebuild them now?） | UE 标准路径 | **交给用户在引擎/Rider 点 Yes** 由 IDE 编译；AI 不绕路跑编译 | 用户 |
| **Crash Reporter**（崩溃报告器：Send & Close / Copy Callstack） | 标题含 CrashReporter / Error | **AI 不点任何按钮**；先取 Callstack 文本 + `Saved/Crashes/` 日志做根因分析，再连同证据交用户 | 用户决策，AI 取证 |
| **Assert 弹窗**（Assertion failed … [Yes/No]，Yes=继续 No=退出） | 标题常为 Error / Ensure | **交用户**（影响引擎状态）；AI 同步抓日志里的 assert 行 | 用户 |
| **项目升级/迁移**（created with an older version…） | 打开旧版本项目时 | **交用户**（改变项目数据，属破坏性操作） | 用户 |
| **插件缺失**（Missing Plugins，Disable?） | .uproject 依赖缺失 | 报告用户决策；**不可擅自 Disable** | 用户 |
| Live Coding / Hot Reload 成功或失败提示 | 通常自动消失 | 失败提示 → 读日志定位 | AI |
| 无模态信息窗口（toast、输出日志窗口） | 不阻塞 | AI 直接读取内容，继续流程 | AI |
| **未识别的模态弹窗** | — | 按「有状态选择类」处理：截图+日志 → 交用户 | 用户 |

### 2.4 处置三裁决线

1. **无害关闭类**：关闭一个信息性弹窗且不改变引擎/项目状态（Esc / Cancel）→ AI 可用 desktool 自动处理：
   ```bash
   python scripts/wb_call.py desktool desktool.window_control '{"window":"<标题>","pin":true}'
   python scripts/wb_call.py desktool desktool.send_keys '{"text":"{Escape}"}'
   python scripts/wb_call.py desktool desktool.window_release '{}'
   ```
2. **有状态选择类**：Yes/No 会触发重编、迁移、禁插件、越过崩溃点 → **取证后交用户**，附建议与理由。AI 不猜按钮语义、不替用户冒险。
3. **崩溃类**：不点任何按钮；先取证（Callstack / CrashContext.xml / 日志 Fatal 行）→ 根因分析（衔接 Bug 修复协议：复现→日志→证据根因）→ 报告用户。

---

## 3. 禁止行为（红线）

1. **禁止无上限轮询等待**：任何轮询必须有上限（链接轮询 10 次×5s；窗口出现轮询 ≤5 分钟）；超限进本协议，**把等待换成取证**。
2. **禁止「没反应就重发启动/再点一次运行配置」**——制造双实例（硬规则 4）。
3. **禁止跳过截图猜测弹窗内容**（「应该是 xxx 提示吧」违反证据门）。
4. **禁止未取证就 kill 进程**；确需清理只能按 PID 三步协议（`PROCESS_HYGIENE.md`）。
5. **禁止把「出现弹窗」直接当失败结论**——先取证再定性。

---

## 4. 恢复后动作

1. 弹窗解除/用户处理后：若走 MCP 交互模式，**回到闭环步骤③重新轮询链接**（此刻引擎才算用新产物启动，此前的探测结论一律作废——时序纪律）。
2. **记录到交接**：弹窗类型、截图路径、日志原文片段、处置方式、用户决策——下次会话不重复踩、不重复问。
3. 若根因是代码/配置问题 → 转 Bug 修复协议（复现 → 日志 → 证据根因 → 最小修复）。

---

## 5. 与其他文档的关系

- 上游：`QA_EVIDENCE_LADDER.md` §2 ②启动/③等待链接 的失败分支；
- 取证手段：实机通道用法详见 `SLATE_AUTOMATION.md` §1-2；死锁救援（MCP 全超时）见 `PITFALLS_SLATE_UI.md` §3；
- 进程清理：`PROCESS_HYGIENE.md`；构建状态查询：`UE_BUILD_PITFALLS.md` §1.5（build_solution_state）。
