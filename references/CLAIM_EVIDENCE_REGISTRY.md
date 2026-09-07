# UE 版本化结论证据登记表（CLAIM_EVIDENCE_REGISTRY）

> 目的：防止一次项目实测被误写成跨版本普遍定律。`UE_RUNTIME_GOTCHAS.md`、`UE_BUILD_PITFALLS.md` 与 Slate 文档中的高影响结论，必须在本表登记适用版本、证据类型和复核动作。
>
> 裁决：`Bundled` 才可作为本版本强规则；`Environment-observed` 仅作高优先级假设，应用到不同引擎 minor/分支前先跑最小 Spec；`Unverified` 不得用于架构裁决。

## 状态定义

| 状态 | 含义 | 使用方式 |
|---|---|---|
| `Bundled` | 技能包内含源码位置、复现或测试输出 | 在登记版本内可直接引用，跨版本复核 |
| `Environment-observed` | 有历史实测，但原始源码行号/日志/Spec 未随技能分发 | 作为诊断线索；修改架构前必须本地复现 |
| `Unverified` | 仅经验描述或第三方信息 | 不得作为强规则 |

## 高影响结论

| Claim ID | 结论摘要 | 适用版本 | 当前状态 | 应补证据 / 最小复核 |
|---|---|---|---|---|
| `RUNTIME-DLLMAIN-01` | DLL 静态构造期应避免分配、跨 DLL 初始化与跨 TU 静态依赖 | UE 5.8 观察；机制与 Windows loader 相关 | Environment-observed | 引擎/模块源码位置、最小崩溃插件、Fatal 日志与修复后启动日志 |
| `SERIALIZE-INSTANCED-01` | InstancedStruct 二进制往返使用 ObjectWriter/ObjectReader，而非裸 MemoryWriter/Reader | UE 5.8 | Environment-observed | 最小 Spec：派生类型 + FName/FText + round-trip；记录源码 CL 与输出 |
| `SERIALIZE-DEFAULTS-01` | SerializeItem 的 Defaults 对含 FText 的目标不可盲传 nullptr | UE 5.8 | Environment-observed | 正/负对照 Spec 与 callstack；确认不同 archive 的差异 |
| `INTERFACE-BNE-01` | BlueprintNativeEvent 接口的 C++ `_Implementation` 路由存在版本/声明形式风险 | UE 5.8 特定案例 | Environment-observed | 最小接口工程：Execute_*、native override、BP override 三组对照；未复现前禁止写成“C++ 全部不可用” |
| `USTRUCT-POLY-01` | TInstancedStruct 中 USTRUCT 多态、扩容、文本/二进制往返可行 | UE 5.8 POC | Environment-observed | 附 POC 源码、Automation 输出、引擎 CL；跨版本重跑 |
| `ASSET-OPEN-01` | AssetDefinition 返回 Unhandled 时不保证自动 fallback | UE 5.8 | Environment-observed | 记录 `OpenEditorForAsset` 源码链、最小资产类型与双击日志 |
| `SLATE-ROLE-01` | 无 role/label 的控件不会被 Snapshot 输出，项目侧精确注册可恢复 ref | UE 5.8.2 Toolsets | Environment-observed | Snapshot 前后对照、插件源码位置、工具集版本 |
| `BUILD-R8-01` | clean/rebuild 可能触发数千 actions，默认禁止自主执行 | UE4/UE5 工程策略 | Bundled policy | 每次需用户明确授权；action 数和耗时只作为历史样本，不作固定预测 |

## 新增或升级结论的必填字段

```markdown
### <CLAIM-ID>
- 结论：
- 状态：Bundled / Environment-observed / Unverified
- UE 版本与分支/CL：
- 引擎源码：`文件:行号`：
- 最小复现/Spec：
- 原始输出或日志：
- 反例与边界：
- 最后复核日期：
```

## 使用纪律

1. 先查 Claim ID，再引用运行时结论。
2. 不同 UE minor、自研分支或不同插件版本默认视为“待复核”。
3. 复核失败时，更新本表状态并在 Current Truth 中作废依赖该结论的旧证据。
4. 不把缺少随包证据的历史观察写成“唯一实现路径”“必然崩溃”或“跨 5.x 通常成立”。
