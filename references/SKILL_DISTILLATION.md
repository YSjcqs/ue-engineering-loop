# 经验提炼为 Skill（SKILL_DISTILLATION）

> Skill 不是一篇超长 Prompt，而是把**高成本判断压缩成可执行路径**。
> 一个有价值的 Skill 能把「再遇到同类任务」从重新考古变成沿成熟路径执行。
> 成熟信号：下一次遇到同类任务时，Prompt 更短、错误方向更少、读取范围更准、验证动作自动出现。否则它还只是一篇文档。

---

## 1. 提炼七步

```
01 REAL CASE    完整交付一次      用真实任务跑通完整闭环（不是速通）
02 PATTERNS     聚类重复判断      工作流、数据 owner、兼容、性能、QA——重复出现的决策
03 ROUTER       设计读取路由      不同任务变体分别该读哪些 reference
04 RESOURCES    拆分可复用载体    SKILL.md / playbook / decision table / scripts
05 ACCEPTANCE   固化交付矩阵      从最低层到最高层的正反例与 Gate
06 FORWARD TEST 换新实例验证      不给旧答案，看能否独立完成同类新任务
07 ITERATE      用真实失败更新    修路由或资源；不塞入一次性流水账
```

---

## 2. 提炼九问（任务结束时逐条自问）

1. **精准触发条件**：什么请求应该使用它？什么情况不该用？
2. **Must-follow boundaries**：绝不能做什么，何时必须暂停？
3. **Read route**：不同任务变体分别应读哪些 reference？
4. **Default workflow**：最小、稳定、可恢复的执行顺序。
5. **Decision tables**：症状 → 根因类别 → 检查路径 → 修复 seam。
6. **Scripts / assets**：哪些机械动作值得封装为脚本？
7. **Failure taxonomy**：产品 Bug、Case Bug、工具 Bug、知识缺口如何分流？
8. **Acceptance matrix**：怎样证明交付完成？
9. **Case studies**：保留正例、反例和 why；删除临时绝对路径与过期状态。

**值得提炼的是**：重复问题（同类任务、相似失败、重复追踪）、稳定不变量（什么永远不能破坏）、决策与路由（症状分类、该读什么）、脚本与资产（机械动作、fixture、模板）、验收矩阵（正反例、失败分流、证据）。

---

## 3. 沉淀载体判断表

| 载体 | 适合保存什么 | 不适合保存什么 | 判断标准 |
|---|---|---|---|
| **Rule / AGENT.md** | 始终生效的仓库不变量与命令 | 只对某类任务有用的长流程 | 任何改动都必须遵守吗？ |
| **Automation / Script** | 确定、可重复、机器能判定的约束 | 需要设计判断或人类视觉的内容 | 能否无歧义地自动判定？ |
| **Template** | 稳定的输入/输出结构 | 依赖大量上下文的决策 | 只是减少格式成本吗？ |
| **Skill** | 触发、边界、路由、决策、工具、验收 | 单次绝对路径与临时状态 | 能显著缩短下一次理解与执行吗？ |
| **Memory / Handoff** | 当前任务状态与下一步 | 跨任务永远有效的规则 | 它会在任务结束后过期吗？ |

---

## 4. Skill 的目录结构（分层执行系统）

```
<skill-name>/
├── SKILL.md
│   只保存 Trigger、硬边界、读取路由、默认流程与暂停点（做路由器，不做百科全书）
├── references/
│   ├── framework-map / 知识地图        领域结构与数据 owner
│   ├── *-playbook                      从盘点到 handoff 的执行顺序
│   ├── implementation-runbook          全链路落地手册
│   ├── decision-tables                 不同形态如何选
│   ├── *-case-study                    一个足够大的真实正反例
│   └── acceptance-matrix               完成门槛与证据要求
└── scripts/
    └── （机械动作封装，必须可验证、有退出码契约）
```

**原则**：SKILL.md 做路由器；细节按任务需要**渐进加载**，不要让每次同类任务都一次性吞下全部历史。

---

## 5. 一个 Skill 改变整个交付形状

以「新业务类型接入」为例（从真实 UE 编辑器工具迁移案例提炼）：

| 交付阶段 | Skill 自动加载的知识 | 必须产出的工程物 | 进入下一阶段的 Gate |
|---|---|---|---|
| 0 · 业务考古 | migration playbook、读取路线 | 工作流清单、保留/替换/删除表、消费者地图 | 没有遗漏真实用户结果与运行时消费者 |
| 1 · 数据设计 | 框架 map、决策表 | 数据映射、编辑 owner、加载策略、文件边界 | 每个字段只有一个编辑面与明确保存 owner |
| 2 · 最小切片 | implementation runbook、Automation 模式 | 一条完整编辑/保存/读回链 | 正向与失败回滚 focused tests 全部成立 |
| 3 · 产品工作流 | UI/工作流专项参考 | 只实现业务确实需要的 UI | 真实操作链可见、可保存、可恢复、可重开 |
| 4 · 性能与兼容 | 渐进加载、缓存、事件 fanout | 性能预算、定向 invalidation、兼容回归证据 | 无隐藏同步加载、无全量扫描、兼容结果不变 |
| 5 · 总验收 | acceptance matrix | 全链证据包、已知缺口、handoff | 证据属于同一最终源码；NOT RUN 不冒充 PASS |

**提炼前**：「参考旧实现，把新类型接进去，功能做齐一点。」→ AI 大概率先生成 UI、镜像旧存储、绕过统一数据流；等问题出现时再逐个补洞。

**提炼后**：Skill 先路由到盘点与数据映射，要求合同设计与最小纵向切片；证据通过后才加载 UI、性能和 QA 参考，扩面顺序由 Gate 决定。

---

## 6. UE 开发中值得持续沉淀的方向（起点清单）

```
□ ue-build-pitfalls        编译/UHT/UBT 踩坑（已含于本技能，按项目补充）
□ ue-runtime-gotchas       运行时实测定论（同上）
□ ue-interactive-qa        可见窗口、租约定位、黑盒操作、截图与报告固化
□ ue-performance-troubleshooting  cold/warm、同步加载、Slate jank、AssetRegistry fanout 诊断路径
□ ue-asset-pipeline-debugging     路径、AssetRegistry、缩略图、缓存与失效边界按症状路由
□ ue-perforce-workflow     P4 打开、diff、revert、生成资产、CL 卫生安全默认
□ <项目>-migration         各项目自己的业务迁移/接入交付系统
```

> 本技能（ue-engineering-loop）已覆盖前两项与工作方法层；项目特有知识按第 4 节结构自行扩建。
