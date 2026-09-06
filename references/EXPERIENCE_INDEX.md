# 实战经验索引（遇到症状先查这里）

> 沉淀自 2026-08 ~ 2026-09 一次 **44 阶段 UE 插件开发计划**（完成 11 阶段、12 次会话、60+ 次自动化验证）的真实事故与解决，融合 VibeCoding 工程方法论。
> **领域结论均经「读引擎源码 + 编译/运行实测」双重验证**，非文档推测。
> 本文件为**按需查阅**，不必每次加载。SKILL.md §1 有精简的任务路由表。

---

## 症状 → 文档对照表

### 方法论类

| 症状 / 任务 | 查哪篇 |
|---|---|
| 任务不知道从哪下手 / 长任务怎么切阶段 | `WORKFLOW_STATE_MACHINE.md` §1 六阶段 + Exit Gate |
| AI 交付了但没法判断是不是真的完成了 | `WORKFLOW_STATE_MACHINE.md` §3.2 GO/NO-GO + `QA_EVIDENCE_LADDER.md` §1 证据阶梯 |
| 编译通过但功能还是不对 / 只验证了一层 | `QA_EVIDENCE_LADDER.md` §1（VISIBLE ≠ PERSISTED ≠ RUNNING） |
| 失败后反复「继续」没有进展（Zero-Delta Retry） | `PROMPT_CONTRACTS.md` §5 失败后重定向 |
| 中途想到新需求，该现在做还是另开任务 | `PROMPT_CONTRACTS.md` §6 路由判断（STEER/QUEUE/NEW TASK） |
| 跨天/换会话后重复已关闭工作 / 旧结论复活 | `CONTEXT_MANAGEMENT.md` §3 压缩规则 + §3.1 恢复协议 |
| 想给任务写清楚 Prompt / 需求边界 | `PROMPT_CONTRACTS.md` §1 七要素 + §2-§4 模板 |
| 多个任务想并行推进 | `PARALLEL_ORCHESTRATION.md` §1-§2 + 资源隔离清单 §3 |
| 测试该怎么设计 / 自动化从哪下手 | `QA_EVIDENCE_LADDER.md` §3 Automation 设计法 + Case Matrix |
| 本次任务值得沉淀什么经验 | `SKILL_DISTILLATION.md` §2 提炼九问 + §3 沉淀载体判断表 |

### UE 领域类

| 症状 / 任务 | 查哪篇 |
|---|---|
| 编译报错但看不懂（尤其「不是成员」「不接受 N 个参数」） | `UE_BUILD_PITFALLS.md` §3 错误链误导 |
| UHT 报各种「声明形式」错误（generated.h / 类名前缀 / USTRUCT 限制） | `UE_BUILD_PITFALLS.md` §2 UHT 规则全集 |
| 编译起不来 / 超时 / 卡住 | `UE_BUILD_PITFALLS.md` §1 构建通道语义 + §5 效率 |
| 插件依赖、双 target、Editor/Game 差异 | `UE_BUILD_PITFALLS.md` §4 |
| **Game target 怎么编** | `UE_BUILD_PITFALLS.md` §4.2（主入口优先，命令行须授权兜底） |
| **想 clean/rebuild/全量重编** | `UE_BUILD_PITFALLS.md` §1.6 R8 禁令（多为禁止项） |
| **引擎启动崩溃**：`Code not found for generated code (package /Script/X)` | `UE_RUNTIME_GOTCHAS.md` §1 DllMain 三禁止 |
| 序列化崩溃 / InstancedStruct 往返 | `UE_RUNTIME_GOTCHAS.md` §2（★ FObjectWriter 而非 MemoryWriter） |
| **接口 BlueprintNativeEvent 不生效 / 双击资产无反应** | `UE_RUNTIME_GOTCHAS.md` §3 + §6 |
| USTRUCT 多态是否可靠（虚调用/扩容/跨资产粘贴） | `UE_RUNTIME_GOTCHAS.md` §4（POC 实测通过） |
| 不确定某 API 真名 | `UE_RUNTIME_GOTCHAS.md` §5 对照表 |
| 长任务如何组织文档 / 防止上下文丢失 | `CONTEXT_MANAGEMENT.md` §4 文档体系 |
| 设计文档与实测不符怎么办 | `CONTEXT_MANAGEMENT.md` §5 勘误候选 + [INFERRED] |
| 跑 Spec 很慢 / 卡在 FPS 等待 | `AUTOMATION_TESTING.md` §1 headless + §2 |
| Python 里某个 API 找不到 | `AUTOMATION_TESTING.md` §4 能力边界清单 |
| 需要程序化改蓝图（设返回值 / 加接口） | `AUTOMATION_TESTING.md` §5 编辑器测试辅助库模式 |
| **残留引擎进程 / 屏幕上有红框** | `PROCESS_HYGIENE.md` §1-§3 |
| 自动化通道连不上 / 配置漂移 / 探测时机 | SKILL.md 硬规则 1/3 时序纪律 + `MCP_CHANNELS.md` §5 排查树 |

### Slate 自动化类

| 症状 / 任务 | 查哪篇 |
|---|---|
| **Slate 控件在快照里隐形**（节点一整块 image / 控件消失） | `PITFALLS_SLATE_UI.md` §2 根因 + `SLATE_AUTOMATION.md` §3 项目侧 role 注册 |
| **graph 上想点/拖 pin 但坐标全失败** | `PITFALLS_SLATE_UI.md` §2.3（9/9 失败实测）→ 一律 ref 操作 |
| **所有引擎内 MCP 调用全部超时** | `PITFALLS_SLATE_UI.md` §3 模态框死锁 + desktool 救援四步 |
| send_keys 无法输入文字 | `PITFALLS_SLATE_UI.md` §5 剪贴板粘贴法 |
| 快照树很浅 / 被 [truncated] 截断 | `SLATE_AUTOMATION.md` §2.2 先 Observe+sleep 再 Snapshot |
| 自定义 SWidget 想被快照看见 | `SLATE_AUTOMATION.md` §3 RegisterWidgetRole/RegisterLabelExtractor |
| 想改引擎源码实现能力 | 先看 SKILL.md §3.3 零引擎侵入红线；确需修改走 `PITFALLS_SLATE_UI.md` 附录 A 授权流程 |
| 编译报 LNK1136（无关模块损坏） | `PITFALLS_SLATE_UI.md` §6 UBA 问题 → `-NoUBA`，不是 rebuild |

---

## 通用原则

**开工前先查对应参考文档**，把「编译报错 → 反复试错」变成「先看清单 → 一次写对」。

UE 编译成本高（增量 40~90s，Game target 全量可达 1.5h），试错代价极大。

---

## 最值得记住的十条（若只读一段）

1. **MCP/通道调用超时 ≠ 失败**——先查进程再决定是否重试，否则制造双引擎实例（实测 2 次）。
2. **编译阶段禁止断言引擎通道状态**——此时无监听正常且必然；时序纪律（SKILL.md 硬规则 1）。
3. **DllMain 三禁止**——静态注册在 loader-lock 期禁止堆分配 / 调用引擎 API / 跨 TU 静态访问，否则引擎启动崩溃（1114）。
4. **序列化用 FObjectWriter/Reader**——裸 MemoryWriter 无 name map，InstancedStruct 反序列化必崩。
5. **接口 BNE 只有 BP 实现路径可靠**——C++ override `_Implementation` 会被静态 thunk 绕过；且禁止虚表直调。
6. **零测试执行 ≠ 通过**——Spec 名写错时引擎照常启动退出，`run_spec_headless.ps1` 用 `exit 2` 显式拦截。
7. **VISIBLE ≠ PERSISTED ≠ RUNNING**——热 Editor 看得见不代表保存/冷加载/运行时成立，每层分别证明。
8. **最后一次源码修改让旧绿灯全部失效**——最终证据只认最终源码（机械化执行，不靠记忆）。
9. **Blocked 是健康状态**——禁止绕过产品入口制造通过；NOT RUN 必须明示。
10. **一个文件只有一个写入 owner**——并行可以重叠等待，不能同时发明「当前真相」。
