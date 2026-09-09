# 撤销任务状态与显式恢复

日期：2026-09-07。B08 仍实施中，接续[独立执行器合同](device-revocation-runner-contract.md)。

## 持久状态与恢复

队列新增只包含 empty/pending/paused 的聚合状态流，不向 UI 传递账号、设备、capability 或内部错误。订阅和初始快照在队列 actor 同一 turn 完成；写入成功后发布完整状态，bufferNewest(1) 合并迟到通知。读失败结束该订阅并显示不可读取，不能伪装成任务已完成。

用户重试在单次持久读改写中恢复全部当前暂停任务：保留原 intent、operationID 和累计尝试次数，去除 pause 并设为立即可尝试。正常退避任务完全不变，因此按钮不能绕过 429 的等待时间。重复点击后的无变化调用幂等；写入失败保留原数据，旧任务 CAS 不能完成已更新任务。

App 在前台观察状态，后台取消观察并保留上次状态。观察和网络 runner 有各自所有者；任何一个读取/执行错误不会删除任务或改变当前认证会话。手动重试单飞，持久保存后重新订阅初始快照，即使该次恢复没有改动数据，也能消除旧的读取错误显示。等待旧观察排空只涉及本地 stream，不等待撤销网络。

## 用户界面

根界面的安全区状态栏在登录和已登录界面均可展示此前的退出确认状态；隐私遮罩仍覆盖后台截图。等待自动重试时没有手动加速按钮；暂停/不可读取显示“重试退出确认”，操作进行时禁用。任务清空后状态栏消失，不把 capability 过期表述为撤销已提交。

此前“请联网后移除 Push 端点”的本地退出失败文案已改为解锁、保存退出任务和删除本机凭据，匹配当前本地退出合同。

新文案使用 SwiftUI LocalizedStringKey，包括状态标题、解释、按钮及 hint；沿用当前中文源文案方式，未新增全局 String Catalog 或宣称完整翻译。状态以文本表达，按钮保留系统角色、至少 44pt 高度，文字允许换行，布局使用 leading。无障碍字号默认折叠解释，用户可展开；主要定位 ID 为 `v2.revocation.status`、`v2.revocation.retry` 和 `v2.revocation.details`；hint 说明重试不退出当前账号。

## 验证范围

- ClientKit 442 报告、437 实际、5 在线跳过，69 套件通过。覆盖初始快照/合并状态、读失败后重新订阅、持久恢复失败保留、原操作与次数、普通退避不变、旧完成拒绝。
- 最终签名模拟器 App 196 报告、195 实际、1 在线跳过，20 套件通过。真实 Keychain + App 前台读出暂停，后台取消后手动恢复原任务，另一份登录凭据保持不变，并清理独立测试域。
- 真实 UI 测试检查重试点击、状态持续显示及按钮消失、登录控件可触达；另在显式 SwiftUI accessibility5 和 rightToLeft 环境运行，并检查登录提交按钮仍可触达。审计覆盖元素检测、触达区域、描述、文字裁剪、traits；它不是人工 VoiceOver 朗读或全语言翻译验收。
- 初期仅用系统启动参数的 UI 测试虽通过，截图却显示字号/方向未生效；保留日志但不算最大字号证据。改用受限 DEBUG 环境后，截图确认字号及镜像，再将大字号说明默认折叠。其他旧启动参数测试需独立核实。
- UI 使用明确 DEBUG 且限于 uiTestingSignedOut 的展示 fixture，点击只转换展示状态；真实持久副作用由独立 App/ClientKit 测试验证，不把视觉 fixture 当成网络或存储端到端证明。

本批未重跑 HTTPS/PostgreSQL、完整 Gateway/headless、物理设备锁屏、任意指令强杀或系统后台调度。注册响应迟到等剩余 B08 生命周期边界仍待完成。schema 28、protocol 27、SQLite 173/5 和 47 项状态不变，16 项已验证、31 项开放。

日志、截图和最终源码哈希见[证据](evidence/20260907-revocation-status/manifest.json)。

最终截图：[普通字号](evidence/20260907-revocation-status/screenshots/normal.png)、[最大字号 RTL](evidence/20260907-revocation-status/screenshots/accessibility-rtl.png)。
