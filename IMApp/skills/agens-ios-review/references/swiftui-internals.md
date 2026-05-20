# SwiftUI 内部机制参考

当 SwiftUI review 需要判断“这是不是结构性问题”，而不是只看表面 API 风格时，补充读取这份资料。

这份文档主要吸收 Rens Breur 博客中 4 篇和 SwiftUI 内部机制直接相关的文章，并把它们转成审查时可落地的判断依据。

## 1. 文章列表

- [Untangling the AttributeGraph](https://rensbr.eu/blog/swiftui-attribute-graph/)  
  主题：SwiftUI 背后的 AttributeGraph、依赖传播、脏节点更新。
- [SwiftUI's diffing algorithm](https://rensbr.eu/blog/swiftui-diffing/)  
  主题：SwiftUI 如何依赖静态类型、`ForEach` 身份和少量结构变化完成 diff。
- [The SwiftUI render loop](https://rensbr.eu/blog/swiftui-render-loop/)  
  主题：`body` 重算、视图失效、run loop 调度和真实渲染之间的区别。
- [Don't use escaping closures in SwiftUI](https://rensbr.eu/blog/swiftui-escaping-closures/)  
  主题：为什么在 SwiftUI 组件里长期存 escaping closure 往往会破坏结构推断和优化。

## 2. 吸收后的核心认识

- SwiftUI 的更新不是“每次状态变化都把整棵树重新渲染一遍”，而是依赖图中相关节点失效后，再按依赖回溯更新。
- SwiftUI 的 diff 很大程度依赖静态类型信息，而不是在运行时对任意两棵树做通用最短编辑比较。
- `body` 多次求值不等于屏幕上真的发生了多次用户可见渲染；排查问题时应优先确认真实副作用和用户可见回归。
- 视图结构、身份和依赖关系越稳定，SwiftUI 越容易做正确、便宜的更新。
- 不必要的类型擦除、closure 存储和额外包装层，常常不是“语法风格问题”，而是在主动削弱 SwiftUI 原本可以利用的结构信息。

## 3. 对审查规则的直接影响

### 3.1 AttributeGraph

- 当状态、布局、文本、显示列表互相依赖时，要警惕形成隐蔽的状态反馈回路。
- `onAppear`、几何测量、`PreferenceKey`、布局阶段写状态等逻辑，应优先判断是否会导致“状态更新 -> 布局变化 -> 再次写状态”的回路。
- review 时不要只盯着某个 `body` 很长；更重要的是识别依赖图中是否存在不必要的交叉耦合。

### 3.2 Diff 与静态结构

- 优先保持稳定、可推断的静态视图结构，不要为了抽象统一而过早把分支压到运行时。
- `AnyView`、多层 erased wrapper、无必要的统一容器，会让视图结构和身份更难推断；只有在确实需要抹平异构接口时才使用。
- `ForEach`、列表和导航栈中的元素身份必须稳定；不要把临时下标、offset 或展示顺序当长期身份。
- 对同一路由重复入栈、同一列表项重复出现等场景，应把“导航/展示实例身份”和“业务实体身份”区分开。

### 3.3 Render Loop

- 排查“重复渲染”时，先区分这是：
  - `body` 重新计算
  - 布局再次发生
  - 真实副作用再次执行
  - 用户可见闪烁或状态漂移
- 只有当重新求值真的导致重复网络请求、重复保存、重复动画、错误 UI 状态写入或明显性能问题时，才应上升为 finding。
- 不要仅凭调试日志顺序或 `onAppear` 次数，推断 SwiftUI 一定“渲染了两次”。

### 3.4 Escaping Closure

- 构建可复用组件时，若插槽内容可以在初始化阶段由 `@ViewBuilder` 物化成具体 `View`，就不要把 closure 长期存起来再在 `body` 中调用。
- 对需要插槽内容的组件，优先使用泛型参数和具体 `View` 类型，保留结构、身份和依赖信息。
- 如果同时使用 closure 存储、`AnyView` 和额外包装层去模拟“懒构建”，通常说明组件接口已经开始偏离 SwiftUI 的自然模型。

## 4. 在 review 中如何用

- 当看到 `AnyView`、erased wrapper 或复杂抽象时，不要立刻按风格问题处理；先判断它是否真的破坏了身份、diff 质量或依赖追踪。
- 当看到 `onAppear`、`PreferenceKey` 或几何测量写状态时，优先检查是否存在布局反馈回路，而不是先下结论说“这样写不现代”。
- 当有人用“SwiftUI 渲染了很多次”解释 bug 时，优先要求证据，确认是否真有重复副作用或用户可见回归。
- 当组件通过 escaping closure 暴露子视图时，优先评估是否可以改成初始化阶段物化的泛型 `View`，从而减少不必要的动态行为。

## 5. 不应被机械上升为 finding 的情况

- 存在 `AnyView` 不等于一定错误；关键是它是否真的削弱了结构信息并带来维护或性能代价。
- `body` 多次求值不等于一定存在 bug；只有和真实副作用、状态漂移或可见回归耦合时才应上升。
- 某些 closure 存储是框架或接口兼容所必需的；只有在它显著增加复杂度、破坏依赖追踪或可以被更自然结构替代时，才值得提出。
