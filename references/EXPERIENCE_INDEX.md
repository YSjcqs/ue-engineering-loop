# 实战经验索引（按症状查找与最值得记住十条）

> 本文件沉淀自 2026-08 ~ 2026-09 一次 **44 阶段 UE 插件开发计划**（完成 11 阶段、12 次会话、60+ 次自动化验证）的真实事故与解决。
> 领域结论按 `CLAIM_EVIDENCE_REGISTRY.md` 分级；未随包附原始证据的历史观察只作高优先级假设，跨版本应用前需最小复核。
>
> **★ 与 SKILL.md §1 任务路由的关系**：§1 是每次会话启动的主路由（22 项症状→文件映射）；本文件**不再重复**症状映射表，只保留两块高价值内容：
> 1. **最值得记住的十条**（若只读一段）——AI 在长任务中容易遗忘的工程级教训。
> 2. **案例锚点**——指向具体事故复盘，作为规则的可信度背书。
>
> 本文件为**按需查阅**，不必每次加载。

---

## 1. 最值得记住的十条（若只读一段）

1. **MCP/通道调用超时 ≠ 失败**——先查进程再决定是否重试，否则制造双引擎实例（实测 2 次）。
   - 关联：SKILL.md §2.5-4 / `UE_BUILD_PITFALLS.md` §1.1 / `CASE_STUDY_UEMCP_OUTAGE.md`
2. **编译阶段禁止用通道探测裁决新产物状态**——结果可能为空或来自旧实例；必须在新产物启动后重新握手（SKILL.md §2.5-1）。
   - 关联：`CASE_STUDY_UEMCP_OUTAGE.md` §5（时序纪律的来源事故）
3. **DllMain 风险优先排查**——登记案例中，loader-lock 期的分配、引擎 API 与跨 TU 静态依赖导致启动崩溃；按 `RUNTIME-DLLMAIN-01` 复核。
   - 关联：`UE_RUNTIME_GOTCHAS.md` §1 / `CLAIM_EVIDENCE_REGISTRY.md`
4. **InstancedStruct 序列化先做 archive 对照**——登记案例需要 FObjectWriter/Reader；跨类型/版本按 `SERIALIZE-INSTANCED-01` 复核，不写“必崩”。
   - 关联：`UE_RUNTIME_GOTCHAS.md` §2 / `CLAIM_EVIDENCE_REGISTRY.md`
5. **接口 BNE 路由必须做三组对照**——始终用 `Execute_*`；native override、BP override 与默认体在目标版本实测后再裁决。
   - 关联：`UE_RUNTIME_GOTCHAS.md` §3 / `INTERFACE-BNE-01`
6. **零测试执行 ≠ 通过**——Spec 名写错时引擎照常启动退出，`run_spec_headless.ps1` 用 `exit 2` 显式拦截。
   - 关联：`AUTOMATION_TESTING.md` §1.3 / `VALIDATE-ZERO-02`
7. **VISIBLE ≠ PERSISTED ≠ RUNNING**——热 Editor 看得见不代表保存/冷加载/运行时成立，每层分别证明。
   - 关联：`QA_EVIDENCE_LADDER.md` §1
8. **最后一次源码修改让旧绿灯全部失效**——最终证据只认最终源码（机械化执行，不靠记忆）。
   - 关联：`QA_EVIDENCE_LADDER.md` §4
9. **Blocked 是健康状态**——禁止绕过产品入口制造通过；NOT RUN 必须明示。
   - 关联：`WORKFLOW_STATE_MACHINE.md` §2 / SKILL.md §2.3
10. **一个文件只有一个写入 owner**——并行可以重叠等待，不能同时发明「当前真相」。
    - 关联：`PARALLEL_ORCHESTRATION.md` §2

---

## 2. 案例锚点（事故复盘，作为规则的可信度背书）

| 案例 | 规则产物 | 文件 |
|---|---|---|
| 引擎在跑但 UEMCP 连不上（PID 22448 在跑、8000 无监听，根因 = 插件未启用） | 硬规则 1 时序纪律 / 硬规则 2 / 硬规则 7 降级路径 / MCP_CHANNELS.md §5 排查树 | `CASE_STUDY_UEMCP_OUTAGE.md` |
| Slate graph pin 坐标点击 9/9 失败（pin 几何在节点框外 31~62px） | `SLATE-REF-01`：不用坐标点 pin / 项目侧 role 注册方案 | `PITFALLS_SLATE_UI.md` §2.3 |
| `Build.version is newer` 触发 4517 actions makefile 重建 | `BUILD-REBUILD-01`：R8 rebuild 禁令 | `UE_BUILD_PITFALLS.md` §1.6 |
| 早期 `run_spec_headless` 把 Success:0/Fail:0 当通过 | 退出码 2 = 零测试 = 失败（最危险失效模式） | `AUTOMATION_TESTING.md` §1.3 |
| 误杀风险：时间差无法证明进程所有权 | `snapshot` 仅观察；启动器拿精确 PID 后 `register`；cleanup 复核 PID/创建时间/exe/项目 | `PROCESS_HYGIENE.md` §1.2 |
| 双引擎实例：MCP 调用超时盲目重试 | 硬规则 4 先查进程再决定是否重试 | `UE_BUILD_PITFALLS.md` §1.1 |

---

## 3. 通用原则

**开工前先查对应参考文档**，把「编译报错 → 反复试错」变成「先看清单 → 一次写对」。

UE 编译成本高（增量 40~90s，Game target 全量可达 1.5h），试错代价极大。

> **症状路由**：本文件不再维护症状→文档映射表（与 SKILL.md §1 重复会漂移）。每次会话启动走 SKILL.md §1 任务路由表即可。