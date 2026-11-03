# tianting-sdk-swift

天听 IM SDK（Swift）：iOS 的网络层与数据层。**天听**是自研 IM 平台，替换腾讯 IM（聊天、群聊、聊天室、站内推送）。

iOS 的统一 SDK（Swift Package）：连接与重连、首帧鉴权、收发、同步、会话、未读、已读、本地缓存、好友与拉黑。

| | |
|---|---|
| 状态 | 尚未开始，排在工作队列 Q18（M6） |
| 技术 | Swift，async/await，URLSessionWebSocketTask，Codable，SQLite（GRDB） |
| 服务端、协议、需求文档 | [tianting-server](https://github.com/leetonny001/tianting-server) |
| 工作队列 / 日报 | tianting-server 的 `docs/process/QUEUE.md`、`docs/reports/daily/` |

行为必须和 [tianting-sdk-ts](https://github.com/leetonny001/tianting-sdk-ts) 一致：遵守 tianting-server 的 `docs/sdk/README.md`，跑同一批 `protocol/vectors` 共享用例。

## 天听的项目

| 仓库 | 内容 |
|---|---|
| [tianting-server](https://github.com/leetonny001/tianting-server) | Go 服务端、协议、需求 / 架构 / 测试文档 |
| [tianting-sdk-ts](https://github.com/leetonny001/tianting-sdk-ts) | SDK（TypeScript）：H5、PC |
| [tianting-sdk-kotlin](https://github.com/leetonny001/tianting-sdk-kotlin) | SDK（Kotlin）：Android |
| [tianting-sdk-swift](https://github.com/leetonny001/tianting-sdk-swift) | SDK（Swift）：iOS |
| [tianting-web](https://github.com/leetonny001/tianting-web) | H5 客户端 |
| [tianting-desktop](https://github.com/leetonny001/tianting-desktop) | PC 客户端 |
| [tianting-android](https://github.com/leetonny001/tianting-android) | Android 客户端 |
| [tianting-ios](https://github.com/leetonny001/tianting-ios) | iOS 客户端 |
| [tianting-admin](https://github.com/leetonny001/tianting-admin) | 管理后台 H5 |
| [tianting-ops](https://github.com/leetonny001/tianting-ops) | 运维后台 H5 |
