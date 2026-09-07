# 自动化验证手册（Spec / Python / 蓝图）

> 沉淀自 12 阶段 UE 插件开发中 60+ 次自动化验证的实战经验。
> **目标**：让「验证」从「启动引擎 → 手动点 → 截图」变成「一条命令 → 40 秒出结果」。

---

## 1. ★ Headless 命令行跑 Spec（推荐为默认方式）

### 1.1 为什么（对比 MCP 交互模式）

| 维度 | MCP 交互模式 | Headless 命令行 |
|---|---|---|
| 耗时 | 数分钟（需等引擎启动 + 轮询） | **~40 秒** |
| 进程清理 | 需要（引擎常驻） | **引擎自动退出，无需清理** |
| FPS 节流 | 会被 `FWaitForInteractiveFrameRate` 卡住（见 §2） | **无此问题**（nullrhi） |
| 实机通道交互（桌面自动化） | 需要（置顶/点击激活） | **不需要** |
| 输出 | 需轮询日志 | 直接 `EXIT CODE` + 日志 |


### 1.2 命令

```powershell
UnrealEditor.exe "<Project>.uproject" `
  -ExecCmds="Automation RunTests <Spec.Path>;Quit" `
  -unattended -nosplash -nullrhi -nopause -stdout -FullStdOutLogOutput
```

配套脚本：`scripts/run_spec_headless.ps1`（启动 + 轮询 + 打印结果 + 返回 EXIT CODE）。

### 1.3 坑与退出码契约（★ 必读）

- 不使用共享默认日志。脚本为每次运行生成 GUID，并通过 `-abslog=<Project>/Saved/Logs/Automation/<Project>-<RunId>.log` 绑定唯一证据文件；若该环境不支持 `-abslog` 而未生成本轮日志，直接 exit 3，不回退解析默认日志。脚本不自动删除历史日志；保留策略由项目或用户另行决定。该 runner 要求机器级 Editor 独占：启动前发现任何 `UnrealEditor*.exe`，或无法枚举进程时均 fail-closed；共享开发机不要运行。
- 日志标志：`Test Completed. Result={Success|Fail}`、`Queue Empty N tests performed`、进程退出码。

**★ 退出码契约（caller 必须把非 0 当失败）**：

| 退出码 | 含义 | 处置 |
|---|---|---|
| `0` | 全部通过（Executed > 0、Fail = 0、Queue Empty 存在、editor exit 0） | ✅ 通过 |
| `1` | 有测试失败或 editor 非零退出 | ❌ 修产品/测试或查退出原因 |
| **`2`** | **零测试执行**（Spec 名错 / Spec 不存在） | ❌ **绝不能当通过** |
| `3` | 无本轮日志产出（引擎没起来） | ❌ 查引擎 |
| `4` | 参数错误（项目/引擎路径无效或 Spec 含命令分隔符） | ❌ 修参数 |
| `5` | 超时（优先级高于无日志/零测试） | ❌ 查卡点 |
| `6` | runner 基础设施失败（并发锁、启动、日志轮转、缺终止标记） | ❌ 先修 runner/环境 |

> **为什么 `2` 必须单列（2026-09 评审实测的教训）**：Spec 名写错时，引擎**照常启动、照常写日志、照常退出**，退出码甚至是 0。早期版本把「Success:0 / Fail:0」当成通过，于是**一个测试都没跑却报成功**——这是验证工具最危险的失效模式。
> 现在脚本显式统计 `Executed = Success + Fail`，为 0 即 `exit 2` 并打印提示。
> **纪律**：不可以用「没报错」「引擎退出了」「日志有了」来推断测试通过——必须同时满足 `Executed > 0`、`Queue Empty N tests performed`、Fail=0、editor exit=0 和脚本退出码 0。SelfTest 直接复用生产裁决函数，避免两套逻辑漂移。

### 1.4 何时**不能**用 headless（局限，★ 必读）

headless 使用 `-nullrhi`（无渲染后端），因此**以下场景不可用**，必须改走 MCP 交互模式：

| 场景 | 原因 |
|---|---|
| **截图 / 视觉验证** | `-nullrhi` 无渲染输出，截图为空或不生成 |
| **实机交互**（桌面自动化按键、视口操作） | 需要真实窗口与渲染循环 |
| **引擎内 Python 交互**（存盘→GC→重载、创建资产后断言属性、程序化建蓝图） | 需要常驻引擎进程与 MCP 8000 链接 |
| **渲染相关行为验证**（UI 布局、材质、后处理） | 同上 |

> **简单判据**：需要**看得见**或**引擎常驻** → 用 MCP 模式；只需要**跑逻辑断言** → 用 headless。

用 MCP 交互模式时，仍需走 PID 跟踪与窗口释放（见 `PROCESS_HYGIENE.md`）；若遇 `FWaitForInteractiveFrameRate` 卡住，见 §2。

---

## 2. EditorContext Spec 被 FPS 节流卡住

### 2.1 症状

日志停在：
```
FWaitForInteractiveFrameRate: Wait (Editor is running at 3.00 fps, want at least 10)
```
测试排队但不执行。

### 2.2 解法（按有效性排序）

| 方法 | 有效性 |
|---|---|
| **改用 headless 命令行（§1）** | ✅ **治本** |
| 桌面自动化 `window_control` pin 置顶 + **物理点击窗口中心** | ✅ 有效（3 fps → 38~44 fps） |
| 仅 `window_control` pin 置顶 | ❌ 无效（置顶 ≠ 激活） |
| 控制台 `t.idlewhennotfocused 0` | ❌ 实测对本编辑器无效（记录备查） |

> **点击落空陷阱**：Z 序上若有其他**全屏窗口**（如 Rider）覆盖，点击会落在它上面。必须先 pin 置顶再点击。

---

## 3. Spec 编写要点

### 3.1 执行顺序：按 `It` 块名的**字母序**，不是定义序

```cpp
It("A6_Deinitialize全清", ...)   // 字母序先跑 → 清空注册表
It("A7_工厂函数指针", ...)        // 后跑 → 依赖 A6 之前的注册 → FAIL
```

**规则**：每个 `It` 块**自建自清**（自己注册需要的状态，结束时反注册），**不依赖其他块留下的状态**。
会破坏全局状态的测试（如 Deinitialize）放在**最后**，或改名为靠后的字母序。

### 3.2 断言类型安全

```cpp
TestEqual(TEXT("ptr"), PtrA, PtrB);   // ❌ 泛型对指针会调 GetValueString → check 崩溃
TestTrue(TEXT("ptr"), PtrA == PtrB);  // ✅
```

**规则**：**指针比较一律用 `TestTrue`**；`TestEqual` 只用于数值/FName/字符串等有明确格式化的类型。
`TestEqual` 类型不匹配的报错（`no matching overloaded function`）常源于 `const T*` vs `T*` 不匹配（如 `GetScriptStruct()` 返回 `const UScriptStruct*` 而 `StaticStruct()` 返回非 const）。

### 3.3 预期错误断言

```cpp
AddExpectedError(TEXT("condition class not loadable"), EAutomationExpectedErrorFlags::Contains, 1);
TestFalse(TEXT("missing class"), Evaluate(...));
```
用于验证「失败路径按约定降级」而非崩溃。

### 3.4 测试桩类

- `UCLASS` 测试桩**必须在头文件**（UHT 只扫头文件），Actor 需 `A` 前缀。
- 与桩类同名的 `.cpp` 必须第一个 include 该头。
- 长文件写完后**检查是否漏了 `BEGIN_DEFINE_SPEC` / `END_DEFINE_SPEC`**（实测漏过 3 次——写长文件时末尾被截断，症状是「Spec 类未定义」）。

---

## 4. Python 引擎内验证：能力边界清单（★ 重要）

> UE Python 绑定**不完整**。以下为 5.8 实测「不存在」的 API，不要浪费时间尝试。

### 4.1 Python 侧没有的 API

| 需求 | Python 有？ | 替代方案 |
|---|---|---|
| `UAssetManager` / `get_primary_asset_id_for_object` | ❌ | 读源码确认默认实现 + 等价断言 |
| `UDeveloperSettings::save_config` / `load_config` | ❌ | 写 ini → 重启/重载 → 读 CDO 验证 |
| `EditorAssetLibrary.unload_asset` | ❌ | 直接 `load_asset` 验证重载链路 |
| `BlueprintEditorLibrary.add_interface` | ❌ | **C++ helper**（见 §5） |
| 设置 BP 函数返回 pin 值 | ❌ **快照语义**，`set_pin_value` 不写回 | **C++ helper**（见 §5） |
| `load_blueprint_class` / `generated_class(bp)` 静态方法 | ❌ | `generated_class` 是实例方法；用 `load_object` 取 BP 后调用 |

### 4.2 Python 使用要点

| 要点 | 说明 |
|---|---|
| **类型名不带前缀** | `unreal.HadesSequenceNodeData`，不是 `unreal.FHadesSequenceNodeData`；枚举 `unreal.HadesSequencePlayMode` 也**不带 `E`** |
| 访问属性用 `get_editor_property` | `dir(obj)` 只看到方法，**看不到数据属性** |
| `create_blueprint_asset_with_parent` 参序 | **`(asset_path, parent_class)`**（路径在前） |
| 枚举值访问 | `unreal.HadesSequencePlayMode.RUNTIME`（大写常量） |
| 调 BP 方法 | `inst.call_method('FuncName', (args,))` |

### 4.3 常用可自动化验证（无需人工）

```
□ 创建资产（AssetToolsHelpers.create_asset）并断言类型
□ 读 CDO 默认值（get_default_object + get_editor_property）
□ 断言反射字段集合（遍历 FProperty，Python 侧做不到 → 放 C++ Spec）
□ 创建 BP 资产 → add_function_override → compile → 实例化 → call_method
□ 打开资产编辑器（AssetEditorSubsystem.open_editor_for_assets）+ 实机通道截图
□ 存盘 → 重载 → 断言字段一致
```

---

## 5. 编辑器测试辅助库模式（Python 做不到就下沉 C++）

**模式**：新建一个 **editor-only** 的 `UBlueprintFunctionLibrary`，把 Python 缺的能力实现为 `UFUNCTION(BlueprintCallable)`，Python 再调用它。

```cpp
UCLASS()
class UMyEditorTestLibrary : public UBlueprintFunctionLibrary
{
    GENERATED_BODY()
public:
    // 例 1：程序化设置 BP 函数返回值（Python set_pin_value 是快照语义）
    UFUNCTION(BlueprintCallable, Category="Testing")
    static bool SetFunctionResultBool(UBlueprint* BP, FName FuncName, bool bValue);

    // 例 2：给 BP 加接口（Python 无 add_interface 绑定）
    UFUNCTION(BlueprintCallable, Category="Testing")
    static bool AddInterface(UBlueprint* BP, UClass* InterfaceClass);
};
```

实现要点：
- 设返回 pin：`FBlueprintEditorUtils::GetAllNodesOfClass<UK2Node_FunctionResult>`（或遍历 `Graph->Nodes`）→ `FindPin(TEXT("ReturnValue"), EGPD_Input)` → 兜底找第一个 bool 输入 pin → 改 `DefaultValue` → `MarkBlueprintAsStructurallyModified` + `FKismetEditorUtilities::CompileBlueprint`。
- 加接口：`FBlueprintEditorUtils::ImplementNewInterface(BP, InterfaceClass->GetClassPathName())`（5.x 签名收 **class path**，不是 UClass*）；`FBPInterfaceDescription` 的成员是 `Interface`（不是 `InterfaceClass`）。
- Build.cs 需加 `Kismet` / `BlueprintGraph`。

> 这类库在 P18+ 的编辑器 UI 回归测试里会反复复用，值得早期投资。

---

## 6. 蓝图程序化验证配方（A5 类「BP 可覆写」验收）

```python
# 1) 建 BP 子类
bp = lib.create_blueprint_asset_with_parent('/Game/X/BP_Test', unreal.MyBaseClass)
# 2) 覆写函数
lib.add_function_override(bp, 'Evaluate')
# 3) 编译
lib.compile_blueprint(bp)
# 4) 设置返回值（C++ helper）
unreal.MyEditorTestLibrary.set_function_result_bool(bp, 'Evaluate', True)
# 5) 实例化并调用
gen = lib.generated_class(bp)
inst = unreal.new_object(gen)
res = inst.call_method('Evaluate', (ctx,))
```

**区分法证据**（验证「走了 BP 图」而非 C++ 默认）：
- 覆写组（空图）返回默认 pin 值；未覆写组（对照）返回 C++ 默认实现值 → 两者**不同**即证明路由生效。

**清理**：`save_loaded_asset` 保存有效资产；删除后立即同路径重建会失败（异步 GC），换路径或等待。

---

## 7. 验证分工原则（H 类验收）

> 完整分工表与纪律见 `QA_EVIDENCE_LADDER.md` §6（本技能的验证类权威来源）。
> 要点：**「能否 X」二元事实一律 AI 自动化**（Python + Spec + 实机截图）；只有主观判断（审美/手感）与复杂多步人工交互流交给用户。
> 演示/验证完毕**立即恢复用户屏幕**（关测试窗口 + 释放窗口锁定，见 `PROCESS_HYGIENE.md` §2-§3）。
