# 通用 Slate 控件树自动化（SLATE_AUTOMATION）

> **定位：通用 Slate 程序开发与调试能力，不是蓝图专项。**
> SlateInspectorToolset 提供对**任意 Slate 控件树**的 ref 级操作（Observe / Snapshot / Click / Hover / Drag / 文本输入），适用于：编辑器任意窗口/面板/对话框、自定义 Slate 工具与插件编辑器、graph 类控件（SGraphPanel 族）、模态框诊断与救援。
> 蓝图图表（创建蓝图→建节点→pin 连线）只是这一套能力**最先被实测跑通的参考案例**，不是功能边界。
> 全部踩坑的根因分析与解法见 `PITFALLS_SLATE_UI.md`。

---

## 1. 双通道架构与调用约定

| MCP | 地址 | 运行线程 | 用途 | 关键限制 |
|---|---|---|---|---|
| UnrealEngineMCP（SlateInspectorToolset 等 52 工具集） | `http://127.0.0.1:8000/mcp` | **UE 游戏线程** | 精确控件树操作（ref 级） | **任何模态对话框都会阻塞全部 MCP 调用** |
| Workbench MCP（desktool） | `http://127.0.0.1:3939/mcp` | OS/桌面层 | 截图、键盘鼠标、窗口管理、**死锁救援** | 不受游戏线程影响 |

**调用约定（两者不同，极易混淆）**：

| | toolset_name | tool_name |
|---|---|---|
| UnrealEngineMCP（SlateInspectorToolset / BlueprintTools / AssetTools 等） | 全限定名（如 `SlateInspectorToolset.SlateInspectorToolset`） | **短名**（`Snapshot`） |
| Workbench desktool | 短名（`desktool`） | **带前缀**（`desktool.click`） |

返回值包装：`{"returnValue":"..."}` 字符串，需 `json.loads(s).get("returnValue")` 二次解析。

**脚本**（本技能 `scripts/`，mcp_call.py 依赖同目录 `mcp_catalog.json`）：

```bash
python mcp_call.py SlateInspectorToolset Snapshot '{"ref":"w1","maxDepth":40}' out.txt
python wb_call.py desktool desktool.click '{"x":100,"y":100,"button":"left"}' out.txt
```

---

## 2. 通用工作模式（适用于任何 Slate 窗口）

### 2.1 环境检查（每次开始前）

1. 探活：8000 与 3939 各探一次（200/405=活着；502/000=编辑器未启动或通道未开）。
2. 走标准闭环时序纪律：编译阶段不探测引擎内通道。
3. 链接后做工具级握手（`Windows` 列表是常用的只读握手工具）。

### 2.2 快照三板斧

1. **先 Observe 后 Snapshot**：对目标窗口 `Observe {"ref":"<窗口ref>","maxDepth":40}` → sleep 3 → `Snapshot`。否则树很浅且被 `[truncated]` 截断。
2. **ref 跨快照稳定**（内部 `bResetCache=false`），可复用。
3. **查 `Windows` 列表确认窗口形态**：操作可能新开独立窗口，也可能只在主窗口加 tab，两种都要确认。

### 2.3 交互原则

- **ref 优先于坐标**：坐标点击在非矩形/树外几何控件上不可靠（见 pitfalls §2.3），一律用快照 ref 操作。
- **不能读图就不猜坐标**：模型读不了截图时，用 ref / UIA / 引擎接口定位，**禁止猜坐标**。
- 文本输入：`send_keys` 只认按键令牌（`{Ctrl+V}` `{Enter}` `{Escape}` `{Tab}`），字面文本走**剪贴板粘贴法**（pitfalls §5）。
- 结果验证优先用**只读引擎接口**（find_assets / find_nodes / get_connected_subgraph 等），不依赖视觉。

---

## 3. 项目侧 role 注册（★ 默认路径，零引擎侵入）

### 3.1 什么时候需要

快照里某个 widget 族「隐形」（节点是一整块 image、控件整个消失）→ 该 widget 类型没有注册 role，被快照渲染器丢弃。**解法不是改引擎**，而是在本项目自己的插件里调用 SlateInspectorToolset 的公开注册 API。

### 3.2 注册 API（Build.cs 加 `"SlateInspectorToolset"` 依赖）

```cpp
#include "SlateInspectorToolsetSnapshotRenderer.h"

// 精确匹配注册：对每个具体子类名逐一注册（RegisterWidgetRole 无前缀接口，
// 注册基类名对子类无效——GetType() 返回的是具体子类名）
FSlateInspectorToolsetSnapshotRenderer::RegisterWidgetRole(FName(TEXT("SGraphPinExec")),  TEXT("pin"),   TEXT("p"));
FSlateInspectorToolsetSnapshotRenderer::RegisterWidgetRole(FName(TEXT("SGraphPinBool")),  TEXT("pin"),   TEXT("p"));
FSlateInspectorToolsetSnapshotRenderer::RegisterWidgetRole(FName(TEXT("SGraphPinString")),TEXT("pin"),   TEXT("p"));
// ... 其余需要的子类同理；自定义 SWidget 族同样这样注册

// 需要 label 时注册 label 提取器（否则控件可见但无文本标识）
FSlateInspectorToolsetSnapshotRenderer::RegisterLabelExtractor(FName(TEXT("SGraphPinExec")),
    [](TSharedRef<SWidget> W){ return StaticCastSharedRef<SGraphPinExec>(W)->GetPinName().ToString(); });
```

### 3.3 实施步骤

1. 在项目插件某模块（建议 Editor 模块）启动时（`StartupModule()`）执行注册；
2. 编译（走 SKILL.md §3 编译入口，RiderMCP `build_solution_start`，增量）；
3. 重启编辑器 → Snapshot 目标窗口 → 确认目标控件出现且带 ref；
4. 把验证过的子类注册清单沉淀进本文件的注册模板（下方 3.4）。

### 3.4 已验证子类注册模板（graph 类控件）

> 出自蓝图图表案例实测；同族控件可直接复用。**注意：此模板随引擎版本变化，使用前先小成本验证。**

| widget 类型族 | 建议 role | ref 前缀 |
|---|---|---|
| `SGraphPin*`（Exec/Bool/String/Object/Struct/Enum/Vector/NameList/Wildcard/Color…逐子类注册） | `pin` | `p` |
| `SGraphNode`（及需要细分的子类） | `node` | `n` |
| `SGraphPanel` / `SNodePanel` | `canvas` | `cv` |

其他常见会隐形的控件（按需注册）：`SInlineEditableTextBlock`（节点重命名）、`SNumericEntryBox`/`SVectorInputBox`（pin 默认值）、`SColorBlock/SColorPicker`、`SGraphNodeComment`、`SExpandableArea`、`SErrorHint`。

> 改引擎源码的前缀注册方案（`TemplatePrefixToRole`，一次覆盖整个类族）**只作备选**，见 `PITFALLS_SLATE_UI.md` 附录 A——默认不采用（零引擎侵入红线）。

---

## 4. 参考案例：蓝图图表建节点 + pin 连线（已验证端到端）

> 本案例演示通用能力的完整串联；每一节都是可迁移的模式。

### 4.1 创建资产（全程非模态，禁止弹模态框）

- 打开已有资产：`EditorAppToolset OpenEditorForAsset {"assetPath":"/Game/X"}`。
- 新建：Content Browser 的 **Add 按钮** → 菜单窗 → hover `Blueprint` 子菜单 → `Blueprint Function Library`（父类固定、无模态）→ desktool `{Enter}` 确认内联命名。
- **黑名单**：`BlueprintTools.create` 与菜单项 "Blueprint Class"（都弹模态框 → 游戏线程死锁）。死锁救援见 `PITFALLS_SLATE_UI.md` §3。

### 4.2 快照定位 canvas / node / pin

```
canvas [ref=cv1] → node [ref=n1] → pin [ref=p1]（exec-out）
                 → node [ref=n2] → pin [ref=p2]（exec-in）
```

- 若 pin 隐形 → 按 §3 注册后重编重启，**不要用坐标硬试**。

### 4.3 ref 级连线与验证

```bash
python mcp_call.py SlateInspectorToolset Drag '{"startRef":"p1","endRef":"p2"}' r.txt   # 返回 true
# 只读验证（资产对象路径必须完整 /Game/X.X）：
python mcp_call.py BlueprintTools find_nodes '{"graph":{"refPath":"/Game/X.X:Graph"},"title":""}' n.txt
python mcp_call.py BlueprintTools get_connected_subgraph '{"node":{"refPath":"<节点refPath>"}}' c.txt
# 证实 connected_pins 双向互指即连线成功；save_assets 必须带 asset_paths 数组
```

### 4.4 参数速查

| 项 | 值 |
|---|---|
| 资产 object path | `/Game/<Name>.<Name>`（图表再加 `:<GraphName>`） |
| find_assets | `{"folder_path":"/Game","name":""}`（name 必填，空串列全部） |
| find_nodes | `title` **必填**（空串列全部）；返回 `refPath` 可喂给 `get_connected_subgraph` |
| save_assets | `{"asset_paths":[...]}` **必填** |
| ref 稳定性 | Snapshot 内部 `bResetCache=false` → ref 跨快照稳定可复用 |
| 主窗口快照 | 会被 MCP 截断（约 9KB 出现 `[truncated]`），但其中子控件的 ref 仍可点击 |
| 第二显示器 | desktool 坐标是全虚拟桌面绝对坐标 |

### 4.5 模态框死锁救援（MCP 全部超时时立即执行）

```bash
python wb_call.py desktool desktool.window_control '{"window":"<编辑器窗口标题>","pin":true}'
python wb_call.py desktool desktool.send_keys '{"text":"{Escape}"}'
sleep 2 && python mcp_call.py SlateInspectorToolset Windows '{}' check.txt   # 正常返回即解锁
python wb_call.py desktool desktool.window_release '{}'
```

---

## 5. 纪律要点（与 SKILL.md 的衔接）

1. 引擎内通道操作发生在**游戏线程**：任何模态框都会让全部 MCP 调用超时——先怀疑死锁，不要先怀疑网络。
2. 每次会话结束后清理：窗口 `window_release`、测试资产处理（`PROCESS_HYGIENE.md`）。
3. 涉及编译（如新增注册代码）→ 走 SKILL.md §3 编译入口与 R8 禁令。
4. 「能否 X」类二元事实（窗口能开吗、连线成功吗）一律自动化取证，不推给用户。
