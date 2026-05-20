# Type-Driven Design 参考

当 review 需要判断“这是不是只是风格偏好”，还是“确实应该通过类型系统前移约束”时，补充读取这份资料。

这份文档主要吸收 Swiftology 的 Type-Driven Design 系列文章，并把它们整理成与当前 AGENS 规范对应的可落地参考。

## 1. 集合入口

- [Type-Driven Design with Swift](https://swiftology.io/collections/type-driven-design/)  
  这是整个系列的集合页，当前公开了 Part 1 到 Part 5，后续还有 `Controlling Side Effects with Swift`、`Fatal error as a design tool`、`Types are Tests` 等待发布。

## 2. 当前可读文章

- [Fundamentals of type-driven code](https://swiftology.io/articles/tydd-part-1-fundamentals)  
  主题：类型驱动设计的基本立场，如何通过类型保留信息、减少无意义状态空间。
- [Type-safe validation](https://swiftology.io/articles/tydd-part-2/)  
  主题：不要只做 runtime validate；应尽早 parse 成更强类型，让后续 API 直接消费已验证结果。
- [Witness pattern — type-safe access control](https://swiftology.io/articles/tydd-part-3/)  
  主题：通过 witness/proof 类型表达前置条件、权限和能力开启状态，避免只传裸 `Bool`。
- [Domain modeling with types](https://swiftology.io/articles/tydd-part-4)  
  主题：从领域原语出发建模，使用 `struct` / `enum` / 强类型 ID 准确表达领域关系。
- [Making illegal states unrepresentable](https://swiftology.io/articles/making-illegal-states-unrepresentable)  
  主题：当业务上不应存在的状态仍可被程序构造时，应优先反思类型设计，而不是继续补防御分支。

## 3. 吸收后的核心认识

- 类型系统不只是“让代码更优雅”，而是主动缩小可表示状态空间，让非法状态、弱约束状态和模糊失败语义更难进入核心流程。
- 边界层最重要的职责之一，是把弱类型输入尽早解析为强类型，而不是把原始值一路往里传，再靠业务流程中段的 `if` / `guard` 补救。
- 若某种前置条件在业务上非常关键，例如“已鉴权”“已验证”“能力已开启”，应优先让 API 接收 proof，而不是只读一个容易伪造的 flag。
- 领域模型应尽可能保留原本存在的信息密度，例如专属 `ID`、非空集合、受限字符串、互斥状态枚举，而不是过早退化成 `String`、`Int`、多个 `Bool`。
- 当非法状态仍可被表达时，优先重新建模；不要一开始就接受它，然后在后续流程里到处铺日志、断言和兜底分支。

## 4. 对当前规范的直接支撑

### 4.1 默认用类型表达业务约束

- `Email`、`UserID`、`Money`、`FeatureFlag`、`NonEmpty` 这类领域原语，通常比裸 `String`、`Int` 或数组更能保留真实约束。
- 对互斥状态、加载生命周期、能力状态、权限状态，优先使用 `enum` 或 proof 类型，而不是多个 `Bool`/`Optional` 拼装。
- 强类型 ID 的价值不只是“命名更漂亮”，而是防止跨领域身份误混用。

### 4.2 Parse, don’t validate

- 边界上拿到 JSON、DTO、数据库记录、表单输入或第三方结果时，优先尽快 parse 成已验证领域类型。
- 一旦某个值已经被验证成功，就不要在后续流程中再降级成原始 `String`、`Bool`、`Int` 继续传递。
- review 时应特别关注：解析是否发生得足够早，还是被拖延到业务流程中段。

### 4.3 Witness 与前置条件

- witness 最适合表达“你只有在某条件成立后，才能调用这个 API”。
- proof 应在可信边界构造，例如鉴权成功、配置加载成功、持久化成功、解析成功之后。
- 若 proof 可以被任意模块随手构造，它就失去了设计价值。

### 4.4 非法状态不可表示

- 如果一个模型允许出现“业务上不该出现”的组合，就应先质疑模型，而不是继续堆更多防御性代码。
- `nil`、空字符串、零值、空数组、多个布尔位组合出的“半合法状态”都应被重点审查。
- review 时若发现大量保护分支反复围绕同一种非法组合出现，往往说明应该重新设计类型。

## 5. 在 review 中如何用

- 当发现某个模块不断在判断 `isValid`、`hasPermission`、`isReady` 之类的 flag 时，先问：这些前置条件能否通过类型系统前移？
- 当看到 DTO、数据库模型或第三方模型直接进入 UI 层和业务层时，优先指出边界解析缺失，而不是只讨论命名问题。
- 当代码里充满多个 `Bool`、多个 `Optional` 或松散字符串状态时，优先判断这些是否本质上是互斥状态或受限状态，应该改成 `enum` 或更强类型。
- 当某个 API 声称“调用时必须先做 X”，但签名里没有任何体现，优先考虑是否应改为 proof/witness 驱动的接口。

## 6. 不应被机械上升为 finding 的情况

- 不是所有原始类型都会成为问题；只有当它们确实在跨边界长期传播、导致语义丢失或频繁引发保护分支时，才值得上升。
- 不是所有 `Bool` 都应被消灭；只有当它承担了复杂业务状态、互斥状态或权限/前置条件语义时，才应考虑更强建模。
- 不是所有 parse/包装都值得做；若值只在极窄局部范围使用，且不会跨边界传播，额外类型可能不划算。
