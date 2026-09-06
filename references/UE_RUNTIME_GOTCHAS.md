# UE 运行时实测定论（静态注册 / 序列化 / 接口 / 多态）

> 沉淀自 2026-08 ~ 2026-09 UE 5.8 插件开发实战。
> **本文件的每条结论都经过「读引擎源码 + 编译/运行实测」双重验证**，不是文档推测。
> 用途：开工前先查这里，避免踩同一个坑两次。
> **版本适用性**：结论出自 UE 5.8 实测；核心机制（DllMain/序列化/BNE）跨 5.x 通常成立，跨大版本或 minor 版本使用前，先按 QA 证据阶梯用最小 Spec 验证。

---

## 1. 静态注册与 DllMain（★ 会导致引擎启动崩溃）

### 1.1 事故模型

```
模块 DLL 加载 → DllMain / 静态对象构造（持有 loader lock）
   ↓ 构造函数里做了「非法操作」
   ↓ DllMain 返回 FALSE  →  ERROR_DLL_INIT_FAILED (1114)
   ↓ 但静态 UCLASS 注册已推入引擎 deferred 链表
   ↓ 引擎继续 → UClassRegisterAllCompiledInClasses 找不到包
   ↓ assert: "Code not found for generated code (package /Script/<Module>)"
```

**崩溃弹窗信息**：`Assertion failed: FoundPackage [UObjectGlobals.cpp]`，callstack 指向 `ProcessNewlyLoadedUObjects`。

### 1.2 DllMain 期「三禁止」

| 禁止 | 反例 |
|---|---|
| **禁止堆分配** | `new` / `MakeUnique` / `TArray::Add` |
| **禁止调用其他 DLL 的初始化** | `FText::FromString`、`FName(...)`、`GEngine->...` |
| **禁止触碰可能未构造的跨 TU 静态** | 访问另一个 .cpp 里的 `static TArray`（SIOF 静态初始化顺序未定义） |

> POD 静态对象（Guid / float / 字面量）是安全的——很多插件的静态注册用 POD 也确实没炸；**一旦构造函数里有逻辑就会引爆**。

### 1.3 正确模式：POD 链表 + 延迟 flush

```cpp
// 1) POD 节点：只有裸指针 / TCHAR 字面量 / 函数指针
struct FMyAutoRegNode {
    const TCHAR* Id; const TCHAR* Name;
    FMyFactoryFn Make;
    FMyAutoRegNode* Next;
};

// 2) 链头用「函数局部 static」——构造顺序安全（SIOF 免疫）
FMyAutoRegNode*& GetAutoRegHead() {
    static FMyAutoRegNode* Head = nullptr;
    return Head;
};

// 3) Registrar 构造只做指针链接（DllMain 安全），析构只做摘链
template<class T>
struct TRegistrar {
    TRegistrar(const TCHAR* InId) { Node.Id = InId; Node.Next = Head(); Head() = &Node; }
    ~TRegistrar() { /* 遍历摘链，指针手术，无分配 */ }
    FMyAutoRegNode Node;
};

// 4) 真实注册（含 FText/FName 构造）推迟到引擎就绪后
void UMySubsystem::Initialize(...) {
    for (FMyAutoRegNode* N = GetAutoRegHead(); N; N = N->Next) {
        Register(FName(N->Id), FText::FromString(N->Name), N->Make);  // 此处构造合法
    }
}
```

**双向安全**：传统热重载（DLL 卸载）会跑析构摘链；Live Coding（不卸载）保持条目。

---

## 2. 序列化（★ POC 级结论）

### 2.1 裸 Memory 归档没有 name map

`FMemoryWriter` / `FMemoryReader` **不含 name/object 引用表**。
`FInstancedStruct` / `TInstancedStruct` / 任何按 `FName` 解析的类型引用在反序列化时会**崩溃**（非报错）。

**正确工具**：

```cpp
#include "Serialization/ObjectWriter.h"   // ← 不是 MemoryWriter
#include "Serialization/ObjectReader.h"

TArray<uint8> Bytes;
{ FObjectWriter W(Bytes); Struct->SerializeItem(W, &Src, &Defaults); }
{ FObjectReader R(Bytes); Struct->SerializeItem(R, &Dst, &Defaults); }
```

> 若确需结构化归档：`FStructuredArchiveFromArchive(Archive).GetSlot()`（来自 `Serialization/StructuredArchiveAdapters.h`）。5.x 的 `SerializeItem(FArchive&, ...)` 重载可能已移除。

### 2.2 `Defaults` 参数必须传真实默认实例

传 `nullptr` 时，含 `FText`（尤其 editor-only 字段）的结构在**写入**阶段就崩溃。

```cpp
const FMyStruct Defaults;                       // 真实默认构造实例
Struct->SerializeItem(Archive, &Value, &Defaults);  // 而非 nullptr
```

### 2.3 InstancedStruct 的 traits 与已知问题

- traits **全开**：`WithSerializer` / `Identical` / `ExportTextItem` / `ImportTextItem`（`InstancedStruct.h` 中已声明）→ 序列化与文本往返**原生支持**。
- `TInstancedStruct<T>` 与 `FInstancedStruct` 同尺寸，反射层直接互操作。
- **已知问题**：**ini/config 序列化**损坏（社区确认）。SavePackage 二进制与 `ExportText`/`ImportText` 是另一条链路，**不受影响**。

### 2.4 文本往返（复制粘贴语义）

```cpp
FString Text;
Struct->ExportText(Text, &Value, nullptr, nullptr, PPF_None, nullptr);
// 粘贴到另一个 Owner 作用域：
Struct->ImportText(*Text, &Out, OtherOwner, PPF_None, GLog, TEXT("FStructName"));
```
> `ImportText` 的 `ErrorText` 参数是指针，传 `GLog`（不是 `*GLog`）。

---

## 3. 接口 BlueprintNativeEvent（★ 5.8 三条禁令）

### 3.1 禁止虚表直调

```cpp
IMyInterface* I = Cast<IMyInterface>(Obj);
I->GetThing();      // ❌ check-fail: "Do not directly call Event functions in Interfaces"
IMyInterface::Execute_GetThing(Obj);   // ✅ 走生成的 static thunk
```

### 3.2 禁止 C++ override `_Implementation`（架构性失效）

**UHT 生成的 `Execute_*` 调用链**：
```
Execute_GetAvatar(Obj)
  → Obj->FindFunction(NAME) → ProcessEvent
    → 接口的 exec thunk（静态函数）
      → 静态绑定【接口自身】的 GetAvatar_Implementation 默认体
```

**结果**：C++ 子类 override `GetAvatar_Implementation()` **能编译，但运行期被绕过**——调用的是接口默认体。

> **测试陷阱**：若子类的三个方法返回值恰好与默认体相同（nullptr/空容器），测试会「假通过」，只有真正返回非默认值的方法才会暴露问题。

### 3.3 结论与替代方案

| 实现方 | 支持度 |
|---|---|
| **Blueprint 实现接口 + 覆写函数图** | ✅ **唯一完整实现路径**（实测通过） |
| C++ 类实现接口 | ❌ 不可用（见 3.2） |

**替代方案**（需要 native 实现时）：
1. 用小 BP 子类包一层，BP 图里调用 C++ 函数；
2. 或把能力放进 Component / Subsystem，接口只做转发；
3. 或像官方 `IAbilitySystemInterface` 那样**根本不声明 UFUNCTION**（纯 C++ 虚函数，BP 走独立包装）。

### 3.4 相关

- `const` 的 `BlueprintNativeEvent` **被 UHT 接受**（实测通过，尽管引擎 Runtime 里找不到先例）。
- `BlueprintNativeEvent` 的 C++ 实现函数名 = `<Name>_Implementation`；**接口**除外（见 3.2）。

---

## 4. USTRUCT 多态（TInstancedStruct）可行性结论

**风险项**：USTRUCT 虚函数 + `TInstancedStruct` 存储 + 序列化/扩容/跨资产粘贴 是否可靠？
**实测结论（POC 通过）**：

| 场景 | 结论 |
|---|---|
| 基类视图虚调用分派（`Get<TBase>()` → 派生实现） | ✅ 正常。cast 判定是 `== \|\| IsChildOf` |
| `TArray` 扩容重分配（Reserve(1)+Push 20 强制多次 realloc） | ✅ vptr 随内存原样搬迁。官方 TArray 假设元素 trivially relocatable |
| 二进制序列化往返（类型 + 派生字段） | ✅（须用 FObjectWriter/Reader，见 §2.1） |
| `ExportText` → `ImportText` 跨资产粘贴 | ✅ 类型与虚分派均保留 |
| 错误类型 `GetPtr<TWrong>()` | ✅ 返回 nullptr（不是崩溃） |

---

## 5. 常用 API 实测名字（不要凭记忆）

| 想要 | 实际（5.8） |
|---|---|
| `FGameplayTagContainer` 成员检查 | **`HasTag` / `HasTagExact`**——**没有 `Contains()`** |
| `FInstancedStruct` 取 ScriptStruct | **`GetScriptStruct()`**——不是 `GetStruct()` |
| `UDeveloperSettings` 三覆写 | `GetContainerName` / `GetCategoryName` / `GetSectionText` |
| `UDeveloperSettings` 持久化位置 | `config=Editor, defaultconfig` → `Config/DefaultEditor.ini`；**自动注册到 Project Settings，无需 ISettingsModule** |
| `TInstancedStruct` 取派生指针 | `GetPtr<TDerived>()`（带 `is_base_of` 约束）；`Get<TBase>()` 返回基类引用 |
| `FRichCurve` 可编辑 | 头文件 `Curves/RichCurve.h`；`UPROPERTY(EditAnywhere) FRichCurve` **直接可在 Details 编辑**（无需 UCurveFloat 资产） |
| 资产工厂注册 | `UAssetDefinition`（`AssetDefinition.h`），替代 `FAssetTypeActions` |
| `GetPrimaryAssetId` 默认实现 | `UPrimaryDataAsset` 非 CDO 实例 = `FPrimaryAssetId(类名, 资产名)` |
| USTRUCT 派生→基类包装 | **无直接构造**：`W.InitializeAs<TDerived>(); W.GetMutable<TDerived>() = Value;` |
| Native GameplayTag（免 ini） | `UE_DEFINE_GAMEPLAY_TAG(Name, "A.B.C")` + `NativeGameplayTags.h` |

---

## 6. 资产打开（双击无响应的经典坑）

**阶段文档常说**「返回 Unhandled 让引擎 fallback 到默认编辑器」——**这是错的**。

**实际链路**：
```
UAssetEditorSubsystem::OpenEditorForAsset
  → GetAssetTypeActionsForClass 经 SyncAssetTypesToAssetDefinitions
     为 AssetDefinition 创建 FAssetDefinitionProxy 包装（判定"有效"）
  → Proxy->OpenAssetEditor(...)
     → AssetDefinitionPtr->OpenAssets(OpenArgs)  ← 返回值被丢弃！
```

**结论**：`EAssetCommandResult::Unhandled` = **双击无任何反应**（不是 fallback）。
**正确写法**（对齐官方 `UAssetDefinitionDefault::OpenAssets`）：

```cpp
EAssetCommandResult UMyAssetDefinition::OpenAssets(const FAssetOpenArgs& Args) const
{
    if (GetAssetOpenSupport(FAssetOpenSupportArgs(Args.OpenMethod)).IsSupported)
    {
        FSimpleAssetEditor::CreateEditor(EToolkitMode::Standalone, Args.ToolkitHost, Args.LoadObjects<UObject>());
        return EAssetCommandResult::Handled;   // ← 必须 Handled
    }
    return EAssetCommandResult::Unhandled;
}
```
> 默认 `GetAssetOpenSupport` 对 Edit 返回 supported，无需覆写。include `Toolkits/SimpleAssetEditor.h`。

---

## 7. const 语义

| 场景 | 结论 |
|---|---|
| const 方法内写 `TObjectPtr` 成员 | 需 `const_cast`（TObjectPtr 是**深度 const**，裸指针不是） |
| `REGISTER` 类静态注册 | 见 §1，DllMain 安全模型 |
| UPROPERTY 加 `mutable` | 不支持，用 const_cast + 注释说明「逻辑 const 缓存」 |
