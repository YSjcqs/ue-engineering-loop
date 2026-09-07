# 禁忌清单全集（TABOO_LIST）

> 本文件是 SKILL.md §6 的完整展开。每条规则使用稳定、唯一的 ID；新增规则不得复用或重排旧 ID。违反适用规则按对应 Gate 失败处理。不适用项必须标 `N/A + 理由`。

## 五大红线

| ID | 红线 | 代价 | 权威位置 |
|---|---|---|---|
| `BUILD-REBUILD-01` | 自主 clean/rebuild/全量重编，或删除中间产物当排错手段 | 数小时构建成本 | SKILL.md §3.2 / `UE_BUILD_PITFALLS.md` §1.6 |
| `VALIDATE-RUNTIME-01` | 未完成适用的运行/引擎验证就宣称功能正确；把零测试当通过 | 假成功 | SKILL.md §2.4 / `QA_EVIDENCE_LADDER.md` |
| `ENGINE-SOURCE-01` | 未经用户逐次授权修改 `Engine/` 树 | 引擎污染、升级丢失 | SKILL.md §3.3 |
| `UI-MODAL-01` | 替用户点击会改变状态的弹窗按钮 | 破坏性操作、状态污染 | `STARTUP_STUCK_DIAGNOSIS.md` §2.3 |
| `RETRY-EVIDENCE-01` | 失败后无新证据地重试 | 补丁堆叠、双实例 | `PROMPT_CONTRACTS.md` §5 |

## 完整 27 条

### A. 读门与证据门（5 条）

| ID | 禁忌 | 关联 |
|---|---|---|
| `READ-CONTEXT-01` | 不读项目知识文件和相关源码就动手 | 读门 |
| `READ-API-02` | 凭记忆写项目/引擎 API，不核实真实签名与版本 | 读门 |
| `EVIDENCE-LOG-01` | 未读当前版本日志就诊断 bug | 证据门 |
| `EVIDENCE-OUTPUT-02` | 编译或测试结论不附真实输出、文件行号或日志 | 证据门 |
| `EVIDENCE-DOC-03` | 实测与权威文档冲突时静默覆盖原文，而不记录勘误与授权边界 | 交接门 |

### B. 验证与重试（5 条）

| ID | 禁忌 | 关联 |
|---|---|---|
| `VALIDATE-RUNTIME-01` | 未达到任务最低证据层就宣称功能正确 | 验证门 / 五大红线 |
| `VALIDATE-ZERO-02` | 把零测试、无终止标记或版本不明的结果当通过 | `AUTOMATION_TESTING.md` |
| `VALIDATE-DELEGATE-03` | 把可自动判定的二元事实无理由推给用户 | `QA_EVIDENCE_LADDER.md` §6 |
| `VALIDATE-LEVEL-04` | 用低层绿灯冒充高层完成，或用旧产物证明当前源码 | T0–T4 |
| `RETRY-EVIDENCE-01` | 无新证据、无新假设作废地重复同一失败动作 | 五大红线 |

### C. 编译纪律（4 条）

| ID | 禁忌 | 关联 |
|---|---|---|
| `BUILD-TIMING-01` | 在编译阶段探测引擎通道并据此宣布降级 | SKILL.md §2.5 |
| `BUILD-GUESS-02` | 不读错误原文就反复试错编译 | `UE_BUILD_PITFALLS.md` |
| `BUILD-FALLBACK-03` | RiderMCP 不可达时未经授权擅自命令行编译 | SKILL.md §3.1 |
| `BUILD-REBUILD-01` | 自主 clean/rebuild/全量重编 | 五大红线 |

### D. MCP 与启动通道（4 条）

| ID | 禁忌 | 关联 |
|---|---|---|
| `MCP-PROJECT-01` | 机械照抄配置中的项目路径，不以实际 `.uproject` 为准 | SKILL.md §2.5 |
| `MCP-TIMEOUT-02` | 把调用超时当确定失败并盲目重试 | `UE_BUILD_PITFALLS.md` §1.1 |
| `MCP-WAIT-03` | 启动无响应时无限等待或重复启动，不转截图/窗口/日志取证 | `STARTUP_STUCK_DIAGNOSIS.md` |
| `UI-MODAL-01` | 未取证、未授权就处理有状态模态框 | 五大红线 |

### E. 进程与窗口卫生（3 条）

| ID | 禁忌 | 关联 |
|---|---|---|
| `PROCESS-OWNERSHIP-01` | 按进程名或时间差终止引擎；未 register 精确 PID 就 cleanup | `PROCESS_HYGIENE.md` §1 |
| `WINDOW-RELEASE-02` | 使用窗口锁定/置顶后不调用 release | `PROCESS_HYGIENE.md` §2 |
| `CLEANUP-SCOPE-03` | 清理未登记进程、未授权资产或其他会话状态 | `PROCESS_HYGIENE.md` §3 |

### F. 范围与协作（3 条）

| ID | 禁忌 | 关联 |
|---|---|---|
| `SCOPE-CHANGE-01` | 越过任务边界、自行改需求或扩大破坏性操作 | 需求门 |
| `PARALLEL-OWNER-02` | 多 Agent 同时写同一文件或同一状态源 | `PARALLEL_ORCHESTRATION.md` |
| `USER-AUTHORITY-03` | 技能默认流程覆盖用户显式只读、禁提交或权限限制 | SKILL.md 顶部优先级 |

### G. Slate 与 UI 自动化（2 条）

| ID | 禁忌 | 关联 |
|---|---|---|
| `SLATE-REF-01` | 在可获得 Slate ref 时仍用坐标连接 graph pin | `PITFALLS_SLATE_UI.md` §2.3 |
| `UI-GUESS-02` | 读不到图或控件树时猜坐标、猜按钮语义 | `PITFALLS_SLATE_UI.md` §7 |

### H. 引擎侵入（1 条）

| ID | 禁忌 | 关联 |
|---|---|---|
| `ENGINE-SOURCE-01` | 未经用户逐次授权修改引擎源码 | 五大红线 / SKILL.md §3.3 |

## 计数与维护

- 唯一规则数：A 5 + B 5 + C 4 + D 4 + E 3 + F 3 + G 2 + H 1 = **27**。
- 五大红线在主题表中复用同一 ID，不产生第二条规则。
- 新增规则时使用 `<DOMAIN>-<TOPIC>-<NN>`，并同步更新计数与 `scripts/validate_skill.py` 的唯一 ID 校验。
