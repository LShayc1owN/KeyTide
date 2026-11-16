# Keytide 技术文档

当前仓库维护独立 macOS App、原生 Helper、测试和本地打包工具。当前源码优先于历史记录。

## 当前入口

- [产品与开发说明](../README.md)：当前功能、安装、手动更新及产品身份。
- [AI Agent 开发指南](../AGENTS.md)：架构、隐私、构建与操作约束。
- [原生 Helper](../KeytideHelper/README.md)：独立 SwiftPM 包、XPC 和权限边界。
- [macOS 发布流程](macos-release.md)：版本准备、DMG／ZIP、签名及安装验收。
- [图标资源](../Design/Keytide-Icon-v1/README.md)：Icon Composer 工程与菜单栏模板。

## 架构摘要

输入链路为 KeytideHelper / listen-only EventTap → XPC → RemoteEventProcessor → StatsManager → 本地聚合存储与 UI。主 App 不另建全局输入监听。Mac／机械成长键盘使用已加载的正式统计、共享键位布局和按需渲染，不依赖历史原型或独立磁盘读取器。

Windows、Sync 客户端／服务端、独立插件和历史原型不再属于当前产品。不得根据旧记录恢复这些组件。

## 历史记录与验收

`PROJECT.md`、历史设计、评审与本地参考资料由维护者保存在忽略路径，不是新 checkout 的依赖，也不列为公开文档链接。历史记录中的旧标识符、路径、统计数量和操作步骤不代表当前实现。

测试、构建、截图和包验收证据存放于忽略的 `build/`。构建成功或签名一致不代表真实授权、输入采集、升级、VoiceOver 或能耗验收完成；发布时应分别记录这些状态。
