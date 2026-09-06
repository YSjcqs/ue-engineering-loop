# Slate 自动化踩坑手册（PITFALLS_SLATE_UI）

> 本手册沉淀自 2026-09-06 实测（UE 5.8.2 源码版，Demo 项目）+ 持续积累。
> 每一条都经过实际验证，含根因分析与解法。`SLATE_AUTOMATION.md` 只放工作流，细节与根因在此。
> **纪律**：本技能默认**零引擎侵入**——改引擎源码的方案全部收入附录 A，须用户逐次明确授权才可使用。

---

## 1. 双 MCP 架构与调用约定

| MCP | 地址 | 运行线程 | 用途 | 关键限制 |
|---|---|---|---|---|
| UnrealEngineMCP（SlateInspectorToolset 等 52 工具集） | `http://127.0.0.1:8000/mcp` | **UE 游戏线程** | 精确控件树操作（ref 级） | **任何模态对话框都会阻塞全部 MCP 调用** |
| Workbench MCP（desktool） | `http://127.0.0.1:3939/mcp` | OS/桌面层 | 截图、键盘鼠标、窗口管理、救援 | 不受游戏线程影响 |

**调用约定（两者不同，极易混淆）**：

| | toolset_name | tool_name |
|---|---|---|
| UnrealEngineMCP（SlateInspectorToolset / BlueprintTools / AssetTools 等） | 全限定名（`SlateInspectorToolset.SlateInspectorToolset`） | **短名**（`Snapshot`） |
| Workbench desktool | 短名（`desktool`） | **带前缀**（`desktool.click`） |

返回值包装：`{"returnValue":"..."}` 字符串，需 `json.loads(s).get("returnValue")` 二次解析。

**脚本**：`scripts/mcp_call.py`（8000，自动解析工具集全限定名，需 `mcp_catalog.json` 同目录）、`scripts/wb_call.py`（3939）。

---

## 2. 【最重要】图表 pin / 节点 / 图表面板在快照里"隐形"的根因

### 现象
Snapshot 里蓝图节点只是**一整块 image**（仅 pos/size），无内部 pin 元素 → 拿不到 pin 的 ref → 无法用 `SlateInspector.Drag(startRef,endRef)` 连线，只能退化成 `desktool.drag` 按坐标拖，而坐标法**注定失败**（见 2.3）。

### 根因（源码级，`SlateInspectorToolsetSnapshotRenderer.cpp` 的 `RenderWidget()`）
1. 树遍历是**完整 Slate 树**（emit 后继续递归子节点），不是访问性树；
2. 但 `if (!Role)` 分支：**没有 role 且没有 label 的 widget 被直接丢弃**（不 emit、不分配 ref）；
3. `SGraphPin*` 全家族不在 `TypeToRole` 映射表，`ExtractLabel()` 对它返回空 → 整族 pin 被丢弃；
4. `SGraphPanel`/`SGraphNode` 同理被丢或以错误的 role 兜底。

**反证**：`SGraphNode` 本就持有 `TArray<TSharedRef<SGraphPin>> InputPins/OutputPins`，pin 是独立 SWidget 且参与 hit test。**pin 一直在树里，只是工具看不见。**

### 解法（★ 默认：项目侧注册，零引擎侵入）
在本项目插件里调用公开注册 API（`RegisterWidgetRole` / `RegisterLabelExtractor`），按具体子类名逐一注册——完整代码、实施步骤与已验证子类清单见 **`SLATE_AUTOMATION.md` §3**。

- 为什么不能只注册基类 `SGraphPin`：`RegisterWidgetRole` 是**精确匹配**（无前缀注册接口），而 `GetType()` 返回具体子类名（如 `SGraphPinExec`）→ 必须逐子类注册。
- 改引擎源码的前缀注册方案收入**附录 A**（备选，须用户逐次授权）。

### 2.3 为什么坐标法注定失败（不要重蹈覆辙）
**SGraphPin 的 widget 几何在节点框外**（实测）：入口节点 142px 宽，pin 中心在右缘外约 31px；Print String 的 exec-out 在节点右缘外约 62px。按"节点框边缘 ± 几像素"推的坐标**根本不在 pin widget 几何内**，mousedown 一律命中节点本体（撤销提示 `Undo: Move Node`）。曾试 9 组坐标/手动序列，9/9 失败。

**结论：永远不要用坐标连 pin，先确认快照里有 pin ref。**（SKILL.md 禁忌 24）

### 2.4 Snapshot 的四种"丢失机制"（排查其他隐形控件）
1. 无 role 且无 label → 完全 skip（**pin 属此类**）；
2. StructuralContainers → skip 但递归、不给 ref（SBox/SBorder/SOverlay/SSpacer/SConstraintCanvas/SHorizontalBox/SVerticalBox/SGridPanel/SWrapBox/SWidgetSwitcher/SCanvas/SScaleBox/SSizeBox/SNullWidget/SInvalidationPanel/SRetainerWidget）；
3. Collapsed/Hidden → 完全跳过（**高级 pin 默认折叠不可见**）；
4. 吸收唯一 STextBlock 子节点后不递归（可能截断子树）。

---

## 3. 模态框死锁与 desktool 救援（已两次实测）

- **触发**：任何弹模态框的操作（点 "Blueprint Class" 菜单项、`BlueprintTools.create` 工具）→ 所有 MCP 调用（含 `Windows`、裸 curl）超时无响应。HTTP 层接受连接但游戏线程不回包。
- **救援流程（desktool，秒级）**：
  1. `desktool.window_control {"window":"<编辑器窗口标题>","pin":true}` 锁定前置；
  2. `desktool.send_keys {"text":"{Escape}"}` —— UE 的 Slate 模态框默认响应 Esc；
  3. 等 2 秒，`SlateInspectorToolset.Windows` 正常返回即解锁；
  4. `desktool.window_release` 释放。
  - Esc 无效时：`desktool.find_element {"name":"Cancel","window":...}` 定位取消按钮再点（注意：主窗口 UIA 遍历可能 >60s 超时）。
- **黑名单工具/操作**（会弹模态，禁止）：`BlueprintTools.create`（创建蓝图）、Content Browser 菜单项 "Blueprint Class"（弹「选择父类」）。
- **安全的非模态替代**：Add 菜单 → Blueprint 子菜单 → **Blueprint Function Library** 或 Gameplay → Actor（父类固定，无选择框）。

---

## 4. 非模态创建资产 + 节点 + ref 连线全流程（实测可复现）

前置：项目侧 role 注册生效（§2 解法），编辑器已启动，`Windows` 可用。

### 4.1 创建函数库蓝图（全程 SlateInspector，无模态）
1. 快照主窗口（先 `Observe {"ref":"w1","maxDepth":40}` + sleep 3 再 Snapshot）→ 找 Content Browser 的 **Add 按钮**（`combobox` 内 text "Add" 的 button，实测 `b52`）；
2. `Click {"ref":"b52"}` → 弹出菜单窗口（`Windows` 多出无标题窗口）；
3. `Snapshot {"ref":"","maxDepth":40}` → 找 `generic "Blueprint"` 子菜单项 → `Hover {"ref":"g21"}`；
4. 子菜单窗口出现 → Click `generic "Blueprint Function Library"`；
5. desktool `{Enter}` 确认内联命名 → `AssetTools.find_assets` 确认 `/Game/NewFunctionLibrary`。

### 4.2 打开图表
`EditorAppToolset.OpenEditorForAsset {"assetPath":"/Game/NewFunctionLibrary"}` → **新开独立窗口**（必须查 `Windows` 列表确认新窗口，也可能只在主窗口加 tab，两种都要看）。

### 4.3 右键菜单创建 Print String 节点
1. `desktool.click {"x":<canvas空白>,"y":...,"button":"right"}`（canvas 的 ref 有 pos/size，选其中空白点）；
2. 快照找菜单窗口：`checkbox "Context Sensitive" [checked]` 与 `textbox "Search"`；
3. `Click` 取消 Context Sensitive 勾选 —— **焦点会移走**；
4. **必须再 Click 搜索框恢复焦点**；
5. 输文本用**剪贴板粘贴法**（见第 5 节）→ `{Ctrl+V}`；
6. 等 2 秒，快照找 `listitem` 结果（分组：Class/Development/...），**Click 结果项（如 li48 "Print String"）比按 Enter 可靠**；
7. `{Escape}` 关菜单。

### 4.4 ref 级连线（核心成果）
```
Snapshot {"ref":"<图表窗口ref>","maxDepth":40}
→ canvas [ref=cv1] → node [ref=n1] → pin [ref=p1]（exec-out）
                     → node [ref=n2] → pin [ref=p2]（exec-in）
Drag {"startRef":"p1","endRef":"p2"}   → 返回 true
```
验证（只读，不属图编辑）：
```bash
BlueprintTools find_nodes '{"graph":{"refPath":"/Game/X.NewFunctionLibrary:NewFunction"},"title":""}'   # title 必填，空串列全部
BlueprintTools get_connected_subgraph '{"node":{"refPath":"...K2Node_FunctionEntry_0"}}'
# 证实 FunctionEntry.then ──Exec──→ PrintString.execute（双向 connected_pins 互指）
```

### 4.5 保存
`AssetTools.save_assets {"asset_paths":["/Game/NewFunctionLibrary"]}`（**必须带 asset_paths 数组**）。

---

## 5. 文本输入：send_keys 不能打字面文本

`desktool.send_keys` 把输入按**按键令牌**解析：传 `"Print String"` 报 `错误: 无法解析按键: PRINT STRING`。支持的只有 `{Ctrl+X}` `{Enter}` `{Escape}` `{Tab}` 等令牌。

**解法（剪贴板粘贴法）**：
```powershell
Set-Clipboard -Value "Print String"    # 用 PowerShell 工具执行（Bash 调 powershell.exe 会被安全策略拦截）
```
```bash
python wb_call.py desktool desktool.send_keys '{"text":"{Ctrl+V}"}'
```

---

## 6. 编译相关坑（与 SKILL.md §3 编译纪律衔接）

1. **编译前必须关 UnrealEditor**（DLL 锁；编辑器连着时 UBT 相关工具会走 Live Coding/Hot Reload）。
2. **PowerShell 不能在管道中调用 .exe/.bat**：`& "x.exe" args | Out-File` 报 `CantActivateDocumentInPipeline`（Build.bat 同样）。→ 用 **Bash 直接调 exe + 重定向**（仅限用户授权的命令行兜底场景）。
3. **UBA（UnrealBuildAccelerator）权限问题**：日志大量 `UbaSessionServer - SetFileInformationByHandle ... (Access is denied.)` → 产物 `.lib` 损坏 → `LNK1136 文件无效或损坏`（报在无关模块，勿误判为自己的代码错误）。→ 加 **`-NoUBA`**；根治可管理员删除 `C:\ProgramData\Epic\UnrealBuildAccelerator`。**这是环境修复，不是 rebuild 理由**（R8）。
4. **判断编译是否成功**：比较插件 DLL 与源文件的 mtime，DLL 更新 = 成功；`Build.version is newer` 会触发 makefile 重建（4517 个 action 的大范围重编，二三十分钟）——**这正是 R8 要防的场景**，任何可能改动 `Build.version` 的操作都属禁止项。
5. **RiderMCP rootFolder 报错的旧案例**：「Unable to determine the target project... specify via rootFolder」而工具 schema 拒收 rootFolder → 在 Rider MCP 设置里绑定默认项目。新技能主路径（`build_solution_start`）以实测为准，见 `UE_BUILD_PITFALLS.md` §1。

---

## 7. 参数与路径速查

| 项 | 值 |
|---|---|
| 资产 object path | `/Game/<Name>.<Name>`（图表再加 `:<GraphName>`，如 `...:NewFunction`） |
| find_assets | `{"folder_path":"/Game","name":""}`（name 必填，空串列全部） |
| find_nodes | `title` **必填**（空串列全部）；返回 `refPath` 可喂给 `get_connected_subgraph` |
| save_assets | `{"asset_paths":[...]}` **必填** |
| Observe/Snapshot | 目标窗口先 `Observe {"ref":<w>,"maxDepth":40}`，sleep 3 再 `Snapshot`，否则树浅且 `[truncated]` |
| ref 稳定性 | Snapshot 内部 `bResetCache=false` → **ref 跨快照稳定可复用** |
| 多显示器 | desktool 坐标是全虚拟桌面绝对坐标 |
| 主窗口快照 | 会被 MCP 截断（约 9KB 出现 `[truncated]`），但其中子控件的 ref 仍可点击 |
| UIA find_element 超时 >60s | 主窗口 UIA 树太大 → 改用 SlateInspector 快照定位 |
| Ctrl+Space | UE 5.8 实测未弹出独立 Content Drawer 窗口；直接从主窗口 dock 区域找 Add 按钮 |
| 模型读图 | 部分模型不支持图片（Read PNG 返回 Content filtered）→ 依赖视觉定位的任务，先确认能否读图；不能读图就用 ref/UIA/引擎接口，**不要猜坐标** |

---

## 附录 A：改引擎源码的前缀注册方案（★ 备选，默认不采用）

> **使用前提**：项目侧逐子类注册（`SLATE_AUTOMATION.md` §3）确实无法满足需求（如需要一次覆盖海量子类/未来新增类型），且**用户对本一次操作明确授权**。SKILL.md §3.3 零引擎侵入红线默认禁止本方案。

**方案内容**（历史实测验证有效，UE 5.8.2）：改
`Engine/Plugins/Experimental/Toolsets/SlateInspectorToolset/Source/SlateInspectorToolset/Private/SlateInspectorToolsetSnapshotRenderer.cpp`
的 `EnsureMapsInitialized()` 新增（**tab 缩进**）：

```cpp
TemplatePrefixToRole.Add(TPair<FString, FString>(TEXT("SGraphPin"),   TEXT("pin")));
TemplatePrefixToRole.Add(TPair<FString, FString>(TEXT("SGraphNode"),  TEXT("node")));
TemplatePrefixToRole.Add(TPair<FString, FString>(TEXT("SGraphPanel"), TEXT("canvas")));
TemplatePrefixToRole.Add(TPair<FString, FString>(TEXT("SNodePanel"),  TEXT("canvas")));
RoleToRefPrefix.Add(TEXT("pin"),    TEXT("p"));
RoleToRefPrefix.Add(TEXT("node"),   TEXT("n"));
RoleToRefPrefix.Add(TEXT("canvas"), TEXT("cv"));
```

**为什么用 `TemplatePrefixToRole`（`StartsWith` 前缀匹配）而不是 `TypeToRole`（精确 FName）**：SGraphPin 是类族，`GetType()` 返回具体子类名，往 `TypeToRole` 注册基类无效；前缀一次覆盖现有+未来+项目自定义的 pin 类型。

**代价与风险**：
- 修改引擎源码 → 引擎升级/同步会丢补丁，且污染引擎树（git status 不干净）；
- 编译的是引擎目标 → 耗时大（触发 R8 约束），必须先关编辑器；
- 每次使用前须向用户报备并逐次获得授权，使用后在交接记录中登记改动的文件与内容。

**授权话术模板**：
> 「需要临时修改引擎源码：文件 X，改动内容 Y（共 N 行），目的 Z。该改动会在引擎升级时丢失且污染引擎树。是否授权本次修改？(是/否)」
