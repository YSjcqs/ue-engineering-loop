# ue-engineering-loop

UE 全栈开发工程协议技能（WorkBuddy Skill）：工程闭环方法论 × UE 领域实测定论 × 通用 Slate 控件树自动化。

## 是什么

一个可被 AI 助手加载的行为协议技能，覆盖：

- **工程闭环**：五 Gate（读门/证据门/验证门/需求门/交接门）、六阶段状态机（M0–M5）、T0–T4 证据阶梯；
- **编译纪律**：RiderMCP 为最高优先级，`build_solution_start` 主入口（异步 sessionId + `build_solution_state` 轮询）；**R8 红线——禁止自动 clean/rebuild/全量重编**，用户明确要求才可且一次一确认；
- **零引擎侵入**：Slate role 注册走项目侧公开 API（`RegisterWidgetRole`/`RegisterLabelExtractor`），改引擎补丁仅作备选存档；
- **测试闭环 R1–R8**：编译 → 启动 → 链接轮询 → 引擎内测试（headless Spec 优先）→ 实机验证 → 日志取证 → 验收勾选 → 复盘交接；
- **启动卡死协议**：引擎遇强制交互弹窗/崩溃报告器时，Workbench 截图取证 → 日志 → 弹窗决策表，禁止盲等与重发启动；
- **MCP 四通道卫生**：IDE 构建（RiderMCP）/ 引擎内（UnrealEngineMCP，需 `ModelContextProtocol` + `AllToolsets` 双插件）/ 实机（Workbench）/ 日志终审。

## 目录

```
SKILL.md            # 协议总纲（每次必读的骨架与红线）
references/         # 18 篇按需加载的细则（路由表见 SKILL.md §1）
scripts/            # env_health_check / engine_pid_tracker / run_spec_headless
                    # rider_call / mcp_call / wb_call / mcp_catalog.json
```

## 来源

由三份技能融合而成（2026-09）：`UnrealDevProtocol`（具名环境实测）+ `UnrealDevProtocol-Skill`（泛化方法论）+ `ue-editor-ui-automation`（Slate 自动化），融合裁决与评审记录见仓库外 `SKILL_FUSION_PLAN.md` / `SKILL_REVIEW_REPORT.md`。

## 适用

UE5（多数结论实测于 UE 5.8 + Rider 2026.2）C++/蓝图项目开发、bug 修复、编译调试、引擎内测试、长任务多会话推进、Slate 编辑器 UI 自动化。不覆盖纯美术资产创作与材质表达式调试。
