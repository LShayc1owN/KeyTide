# UI、线程与逻辑检查（2026-11-17）

本轮确认并修复以下 30 类问题。优先处理了用户指出的设置侧边栏高亮错误；表中的“修复”表示代码已修改，真实设备、权限及性能验收范围见文末。未提交或推送。

P1：阻止构建或可能丢失统计。P2：可重复触发的显示、交互、线程或状态错误。P3：影响较小的交互反馈错误。

## 优先问题与统计页面

| 编号 | 级别 | 触发与原有影响 | 修复及主要位置 |
| --- | --- | --- | --- |
| U01 | P2 | 设置中从“数据”切回“常规”，内容和逻辑选中项已变化，蓝色高亮仍停在旧行。 | 使用 `NSTableRowView.drawSelection` 和正常选中绘制路径，替代普通背景回调中的选中绘制；`SettingsViewController.swift`。CUA 已复现修复前问题，并验证修复后的鼠标与方向键切换。 |
| B01 | P1 | `MechanicalFullPressState` 和 `KeyReplaySession` 的合成初始化方法受私有字段影响，App 与测试无法编译。 | 补充明确的初始化方法，保持内部状态私有；`MechanicalKeyboardView.swift`、`KeyReplayStore.swift`。 |
| U02 | P2 | 从应用统计窗口进入设置修改分应用统计开关，回到原窗口仍显示旧的启用状态。 | 可见期间监听窗口重新获得焦点并刷新，离开时清理观察者；`AppStatsViewController.swift`。 |
| U03 | P2 | 浏览一年以前的历史，概览有计数，月历因只接收最近 53 周的数据而显示零。 | 月历使用完整的已加载历史；旧日期选择、峰值跳转及跨月导航共用相同数据；`AllTimeStatsViewController.swift`、`ActivityOverviewView.swift`。 |
| U04 | P2 | 月历声明为无障碍按钮，但辅助技术执行 Press 无法打开日期。 | 实现 `accessibilityPerformPress()`，与 Return 共用校验；空数据和未来日期拒绝执行；`ActivityOverviewView.swift`。 |
| U05 | P2 | 点击占比把中键、侧键称为“右键”；没有点击时还会显示右侧 100%。 | 三语统一为“左／其它”，使用完整非左键数量；无点击显示破折号；`AllTimeStatsViewController.swift` 及三语资源。 |
| U06 | P2 | 合法导入的极大计数可在总数、键位归一化、物理键参与、平均值、图表标签或后续新输入时溢出崩溃；旧 Double 峰值也可能转换越界。 | 统一饱和求和，整数平均值避免浮点边界转换，保护旧峰值及图表数值转换；覆盖 AppStats、StatsManager、StatsModels、ActivityHeatmap、PhysicalKeyMapping 与统计 UI。 |
| U07 | P3 | 使用指引等待首次按键期间跨日或重置，旧计数基线导致新按键迟迟不被确认。 | 基线同时保存日期；跨日或计数回退时按新基线判断；`OnboardingWindowController.swift`。 |
| U08 | P2 | 设置中读取和解码导入文件、编码和写入导出文件都在主线程执行。 | 引入不可变导出快照和无副作用的导入准备值；文件读取、导入解码、导出编码及文件写入放到串行后台队列，错误和控件状态回主线程；`SettingsViewController.swift`、`StatsManager.swift`。导入状态提交仍沿用主线程事务和既有持久化路径，见限制。 |

## 菜单与键盘工作台

| 编号 | 级别 | 触发与原有影响 | 修复及主要位置 |
| --- | --- | --- | --- |
| M01 | P2 | 菜单趋势图用方向键选中日期后，按键本身触发统计刷新，将选择清空；静止悬停也会被距离刷新清除。 | 相同指标、范围和日期集合更新时按日期身份恢复选择，并重新定位提示；范围或指标变化时清理；两套 StatsPopover 控制器。 |
| M02 | P2 | 菜单每 0.3 秒直接读取后台正在修改的 `currentStats`，KPS 徽章存在数据竞争。 | 改用受锁的 `currentRatesSnapshot()`；徽章与 Pulse 共用同次快照；两套 StatsPopover 控制器。 |
| K01 | P2 | 按键回放中途导出先取消动画，图片回到上一完整帧，摘要却仍是当前进度。 | 保存完整帧对应的日期、总量和覆盖信息；导出使用同一组图像与摘要，随后完成当前请求的静态帧，避免取消后卡住；`GrowthKeyboardViewController.swift`。 |
| K02 | P2 | 默认没有选中键位时，回放进度总量及完成后追加的明细覆盖提示没有传给外层标题。 | 先完成标签修改，再统一发布；未选中键位也发布摘要；`GrowthKeyboardViewController.swift`。 |
| K03 | P3 | 同时按左右 Shift 后松开其中一侧，会被误判为新按压；关闭 Caps Lock 没有试打反馈。 | 使用物理侧别的设备修饰键掩码，Caps Lock 的两种切换都提供反馈；`MechanicalKeyboardView.swift`。 |

## 触控板

| 编号 | 级别 | 触发与原有影响 | 修复及主要位置 |
| --- | --- | --- | --- |
| T01 | P2 | 最小化、隐藏或休眠后停止预览，恢复显示没有对应的预览恢复路径。 | 按页面、窗口、遮挡、应用活动及工作区挂起状态统一计算预览需求，处理恢复通知；`TrackpadStudioView.swift`、`KeyboardVisualizationViewController.swift`。 |
| T02 | P2 | 异步录制写入失败后开关仍开启，错误提示被下一帧实时状态覆盖。 | 录制状态变化发布通知，统一同步开关和错误优先级；`TrackpadStudioView.swift`。 |
| T03 | P2 | 关闭 Studio 后后台录制失败，既无录制也无预览需求，设备回调仍继续运行。 | 失败后停止无需求的 capture；保留仍有需求的预览；`TrackpadStudioView.swift`。 |
| T04 | P2 | 正在录制时删除记录，开关显示旧状态，当前页面的预览也未恢复。 | 删除完成后重新同步录制状态，并按实际展示状态恢复预览；旧写入错误不能覆盖删除结果；`TrackpadStudioView.swift`。 |
| T05 | P2 | 回放时窗口失活或被遮挡，后台仍持续读取并推进画布。 | 在失活和不可见时取消；读取完成与再次调度前再次检查活动状态；`TrackpadStudioView.swift`。 |
| T06 | P2 | 回放扫描准备期间切页或关闭，视图尚未拿到 reader，无法取消后台准备。 | 加载立即返回取消句柄；取消和 reader 安装共用锁，覆盖准备前后的竞争；`TrackpadStudioView.swift`。 |
| T07 | P2 | 确认开启录制时，之前排队的预览帧可能按投递时的新状态被持久化。 | 记录内存中的回调接收时间，建立独立录制起点，拒绝起点之前的排队帧；不改变保存格式；`TrackpadStudioView.swift`。 |
| T08 | P2 | 触控板窗口跨日保留，日期选择器上限仍是昨天。 | 展示、恢复及日期／时钟变化时刷新日期上限；`TrackpadStudioView.swift`。 |

## 统计线程、归属与连接逻辑

| 编号 | 级别 | 触发与原有影响 | 修复及主要位置 |
| --- | --- | --- | --- |
| L01 | P2 | 中键的既有 Helper payload 被标为 back，主 App 将其计为后退键。 | 主 App 优先识别已有 `buttonNumber == 2`，记录全局及分应用中键；贯穿汇总、导入和交互画像；`RemoteEventProcessor.swift`、`StatsManager.swift`、`AppStats.swift`、`InteractionProfile.swift`。 |
| L02 | P2 | XPC 输入线程在进入主队列前读取 UI handler 字典，与界面注册／注销竞争。 | handler 检查与回调读取均移入主队列，注册／注销明确要求主线程；`StatsManager.swift`。 |
| L03 | P2 | 持续移动或滚动不断重建 0.3 秒 timer，距离 UI 只能等输入停止后刷新。 | 已有一次性 timer 时保留原截止时间，合并期间新输入；使用 common run-loop mode；`StatsManager.swift`。 |
| L04 | P1 | 合并导入读取本地快照后、替换状态前，新输入到达；旧合并结果覆盖新增统计。 | 本地基底读取、合并与替换组成同一个受锁事务；`StatsManager.swift`。并发输入与多次合并回归测试通过。 |
| L05 | P2 | 断连先推进 generation，之后的 RPC 错误或回复被丢弃，请求 completion 可能永远不执行。 | 跟踪在途请求，断连时锁外统一取消并 one-shot 收尾；旧 generation 不能修改新连接；`HelperXPCClient.swift`。 |
| L06 | P2 | Helper 首次连接成功后的断连只改变提示，没有进入原有五秒重连流程。 | 断连 observer 统一安排并合并重连；连接成功、安装或退出时取消，验收模式禁止重连；`AppDelegate.swift`。 |
| L07 | P2 | PID 查询在锁外进行，终止通知清理缓存后，旧查询结果又回填，PID 复用时可能错归属。 | 冷查询、回填和终止失效使用同一锁边界；`AppActivityTracker.swift`。 |
| L08 | P2 | 旧录制 epoch 的异步失败晚到，会关闭后来重新开启的真实按键录制。 | 异步失败携带所属 epoch，只允许当前 epoch 的失败关闭 gate；`KeyReplayRecording.swift`。 |

## 兼容与失败路径

- 分应用 `middleClicks` 是新增的兼容字段，旧数据缺失时为 0；旧 `otherClicks` 兼容规则保留。旧后退键历史无法可靠区分中键，不回写猜测结果。
- 导出仍为原有 version 1、`currentDevice` 格式。后台导入准备不修改统计或 UserDefaults；格式或版本错误在提交前失败。合并基底在提交时读取，保留准备期间到来的输入。
- Helper 运行源码、协议、签名身份、安装流程及权限配置未修改。XPC 修复仅涉及主 App 请求生命周期和重连调度。
- 触控板录制默认关闭、独立同意、加密与手动删除规则保留；取消不能中断已经开始的单次文件或 Keychain 调用，但后续准备和投递会终止。

## 验证与边界

- 最终 `swift test`：**264 项 XCTest，0 failures**。新增回归覆盖不可变导出快照、后台导入准备、提交时合并、并发输入与导入、中键兼容及归属、持续距离刷新、极值统计、回放摘要与导出、修饰键反馈。
- `Keytide` Debug 构建：**BUILD SUCCEEDED**，使用 `CODE_SIGNING_ALLOWED=NO` 验证编译和链接；不代表签名或分发验收。
- 三语资源：各 **594 个唯一 key**，语法、key 集合及格式占位符一致；`git diff --check` 通过。
- CUA：实际复现修复前的设置高亮残留；修复后反复鼠标切换与上下方向键导航通过。打开检查历史统计、成长键盘、合成示例和触控板页面。没有开启录制、删除真实记录或导入替换用户统计。
- 统计 UI：62 项同源隔离检查；菜单：88 个同源断言及 macOS 13 原生图表类型检查。它们包含 UI 替身，不等于真实 VoiceOver 或全部主题／尺寸视觉验收。
- 触控板：11 组隔离场景及对应 Thread Sanitizer 运行通过；512,000 帧合成加密回放检查通过。没有使用真实触点或真实记录。
- XPC／epoch：7 组请求生命周期、3 组 epoch 场景通过；另有 PID 强制查询／终止交错和方法级重连调度检查。使用假连接，没有修改或重新安装系统服务。
- 本地验证日志与临时 harness 副本保存在忽略目录 `build/UIAudit-2026-11-17/`，不进入提交。

剩余验收范围：真实 XPC／launchd／TCC、触控板设备的睡眠／重连与触觉、VoiceOver 朗读、能耗及性能未作完整验收。桌面自动操作无法稳定保持工作台焦点，因此没有把回放动画和设备恢复标记为真实 GUI 验收通过。导入的读取和解码已后台化，状态归一化、合并提交及既有同步持久化仍在主线程；超大历史提交阶段未作性能验收。
