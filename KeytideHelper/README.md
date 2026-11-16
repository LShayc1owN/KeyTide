# Keytide 原生采集包

`KeytideHelper/` 可以作为 macOS 13+、Swift 5.9+ 的独立 SwiftPM 包构建和测试，不依赖主 App、PostHog、统计存储或 Node.js。SwiftPM 与正式 Xcode `helper` target 直接编译同一份十个 Swift 源文件，没有复制实现或更改 XPC 协议。

## 构建与测试

在 Keytide 仓库根目录运行：

```sh
swift build --package-path KeytideHelper \
  --scratch-path build/HelperStandalone/SwiftPM --product KeytideHelper

swift test --package-path KeytideHelper \
  --scratch-path build/HelperStandalone/SwiftPM
```

也可只取本目录，在该目录执行 `swift build` 和 `swift test`；没有外部包依赖。`Tests/` 仅使用合成 CGEvent 检查 payload 与服务契约，不创建 EventTap、不请求辅助功能权限、不连接 XPC、不运行服务入口。

新增 SwiftPM 测试文件时，同时在主工程 `PBXFileSystemSynchronizedBuildFileExceptionSet` 的 helper 排除项中列出具体相对路径；Xcode 的同步目录不会自动把整个 `Tests` 目录当作测试 target。

独立的是**源码构建和测试边界**。SwiftPM 输出的是开发用裸可执行文件，不是可直接替换已安装服务的签名 `.app`，也没有自动安装、LaunchAgent 或授权步骤。不要用 `swift run` 验证正在使用的采集服务，以免与现有 Mach service 冲突。正式 App 打包仍使用 Xcode 的 `helper` target，以及原有 vendored helper、签名和嵌入脚本。

## 职责与依赖

| 层 | 源码 | 职责 |
| --- | --- | --- |
| 进程入口 | `main.swift` | 启动原有 XPC listener 与 run loop |
| 原生采集 | `EventTapController.swift` | listen-only EventTap、移动采样、权限查询和显式权限请求 |
| 事件字段 | `PayloadBuilder.swift`、`HelperPayloadFields.swift` | 受限的内存 payload，不读取输入文本 |
| 输入语义 | `ButtonRoleClassifier.swift`、`SystemMediaKey.swift` | 鼠标逻辑按键和媒体键语义 |
| 本机通信 | `HelperXPCListener.swift`、`HelperProtocols.swift` | 签名及 UID 校验、单活动连接、XPC 转发 |
| 服务身份 | `HelperLocations.swift` | 既有 Bundle ID、Mach service、安装路径和协议版本 |
| 生命周期 | `HelperIdleSupervisor.swift` | 断开后的空闲退出 |

主 App 的 `HelperSupervisor` 继续负责安装／cdhash／LaunchAgent，`HelperXPCClient` 继续负责连接。`RemoteEventProcessor` 与 `StatsManager` 负责键名解释、距离计算和聚合持久化，不属于这个采集包。主 App 与 Helper 仍共享原有协议／字段文件，根 SwiftPM 的 `KeytideEventCore` 也继续直接编译现有字段与解码实现。

保持现有身份：

- 主 App：`com.xuanlprk.KeyTide`
- Helper／Mach service／LaunchAgent：`com.xuanlprk.KeyTide.helper`
- XPC interface version：`1`
- 安装位置：`~/Library/Application Support/Keytide/Helper/KeytideHelper.app`

签名校验没有放宽，仍只接受既有主 App identity、有效签名和相同用户 UID。构建本包不会运行安装器，不应据此宣称已验证 TCC 授权连续性或真实 XPC 生命周期。
