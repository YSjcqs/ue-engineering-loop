# ue-engineering-loop

UE 工程闭环与条件化自动化技能：工程方法论 × UE 版本化经验 × Slate/MCP 自动化配置。

## 两层适用范围

1. **通用核心**：适用于 UE4/UE5 C++/蓝图工程的需求澄清、最小实现、构建、bug 修复、分层验证和长任务交接。
2. **自动化配置**：仅在 Windows + UE 5.8 + RiderMCP + `ModelContextProtocol`/`AllToolsets` + Workbench 条件满足时，启用 Slate ref、MCP 四通道和配套脚本。

不覆盖纯美术资产创作、材质表达式调试和非 UE 工程。用户显式约束与仓库规则始终高于技能默认流程；只读任务不写文件、不提交。

## 核心能力

- 五 Gate、M0–M5 状态机、T0–T4 证据阶梯及任务类型最低证据矩阵；
- R8 红线：禁止自主 clean/rebuild/全量重编；
- headless Spec：完整退出码、队列终止标记、并发互斥和同源 SelfTest；
- 进程卫生：`snapshot → 精确 PID register → cleanup`，不再用时间差猜所有权；
- MCP 调用：统一握手、协议解析、非零错误码和原子输出；
- 启动卡死：桌面截图/窗口 + 日志取证，禁止盲等和重复启动；
- Slate ref 级控件树操作与模态框救援。

## 目录

```text
SKILL.md            # 总纲、边界、路由和红线
references/         # 18 篇按需加载的细则与证据登记表
scripts/            # 6 个 Python + 3 个 PowerShell + mcp_catalog.json
  mcp_common.py     # 三个 MCP caller 的共享严格客户端
  validate_skill.py # frontmatter、链接、catalog、清单一致性检查
tests/              # Python 单元测试（含 PowerShell 子进程错误码/自检契约）
```

## 运行环境矩阵

| 能力 | 最低/默认环境 | 其他环境 |
|---|---|---|
| 通用工程闭环 | UE4/UE5；与操作系统无关 | 使用仓库已有构建/测试入口 |
| PowerShell 脚本 | Windows PowerShell 5.1 或 PowerShell 7 | 非 Windows 只使用 core profile |
| Python 脚本与测试 | Python 3.10+，仅标准库 | Windows/Linux/macOS 均可做离线测试 |
| Rider 构建通道 | Rider 2025.2+；以实际 tools/list 为准 | 可改用仓库声明的 IDE/CI 入口 |
| UE MCP/Slate 自动化 | UE 5.8 + ModelContextProtocol + AllToolsets | 版本不符先做小成本能力探测，不套用该 profile |
| 桌面自动化 | Workbench 本地端点 | 不可用时用日志/项目原生测试降级 |

## 快速质量检查

```bash
python scripts/validate_skill.py                 # Core/结构质量门
python scripts/validate_skill.py --release       # 完整 Automation 发布门（当前历史 catalog 会 fail-closed）
python -m unittest discover -s tests -v
```

PowerShell 契约检查已纳入上述 `unittest discover`，在 Windows 上自动运行。`.github/workflows/quality.yml` 会在 push/PR 上执行同一组质量门与 PowerShell 语法检查。

## 来源与可追溯性

本技能于 2026-09 由 `UnrealDevProtocol`、`UnrealDevProtocol-Skill` 和 `ue-editor-ui-automation` 融合。高影响 UE 结论的证据状态与跨版本复核要求见 `references/CLAIM_EVIDENCE_REGISTRY.md`；未随包附证据的历史观察不得当作跨版本定律。
