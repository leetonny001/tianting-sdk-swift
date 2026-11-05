# tianting-sdk-swift

天听 IM SDK（Swift）：iOS 的网络层与数据层。**天听**是自研 IM 平台，替换腾讯 IM。

| | |
|---|---|
| 技术 | Swift 6、Swift Package Manager、async/await、`URLSessionWebSocketTask`、Codable、系统 `SQLite3`，没有第三方依赖 |
| 平台 | iOS 15+、macOS 12+ |
| 行为基准 | tianting-server 的 `docs/sdk/README.md`；与 [tianting-sdk-ts](https://github.com/leetonny001/tianting-sdk-ts) 一致，跑同一批 `protocol/vectors` |

## 用法

```swift
import TiantingIM

var options = IMClientOptions(url: "wss://im.example.com/ws")
options.databaseDirectory = applicationSupportDirectory   // 不设置就只在内存
let im = IMClient(options: options)                        // @MainActor：状态都在主线程，界面可以同步读快照

im.on { event in                                           // 或者 for await event in im.events()
    switch event {
    case .conversations(let list): render(list)
    case .messages(let convId, let list): render(convId, list)
    case .fatal(let reason): backToLogin(reason)           // 被踢、封禁（reason = suspended，until）：不再重连
    default: break
    }
}
im.restoreCache(userId: lastUserId)                        // 可选：离线冷启动先显示本地数据
im.connect(token: token)

let result = try im.send(convId, text)                     // .ok(message) / .empty / .tooLong(over:)
im.retry(convId, clientMsgId)
im.removeFailed(convId, clientMsgId)
try await im.loadHistory(convId)
im.setActiveConversation(convId)                           // 已读上报依据
im.muteState(convId)                                       // nil，或 MuteInfo（user / group，mutedUntil 永久为 .permanent）
im.disconnect()                                            // 退出登录：以 1000 关闭，清内存和本地库
im.close()                                                 // 只停止连接，保留本地库
```

社交：`applyFriend`、`respondFriend`、`deleteFriend`、`setFriendRemark`、`block`、`unblock`、`markFriendRequestsSeen`、`relationOf`、`searchUser`、`setSearchable`、`getUsers`、`loadMyGroups`、`refreshSocial`；快照 `friends()`、`friendRequests()`、`blocks()`、`socialSettings()`、`socialLoaded()`、`profileOf`、`displayName`。

群：`createGroup`、`inviteToGroup`、`leaveGroup`、`kickFromGroup`、`transferGroupOwner`、`setGroupAdmin`、`dissolveGroup`、`updateGroup`、`getGroupInfo`、`loadGroupMembers`；`tipText` 生成提示消息的本地文案。

工具：`c2cConvId`、`groupConvId`、`parseConvIdStrict`、`peerId`、`checkText`、`trimText`、`countCodePoints`、`describeError`、`messageFor`、`ErrorCode`、`CloseCode`、`avatarColorIndex`、`avatarInitial`、`pinyinGroup`。

测试替身：`TiantingIMTesting` 导出 `FakeTransport`、`FakeClock`，界面的测试也可以用。

## 本地库

每个用户一个 SQLite 文件（文件名是 userId 的十六进制，避免大小写不敏感的文件系统把 alice 和 Alice 合并），保存会话、已确认的消息（每个会话最近 `maxCachedMessagesPerConversation` 条，默认 100）和社交状态。token 和未确认的消息不落盘。

被删除的原文要从磁盘文件里消失（AC-ADM-31-4），所以：

- `secure_delete=ON`：释放的单元和页清零；SQLite 不接受这个设置时退回 `VACUUM`。
- `journal_mode=DELETE`，不用 WAL：WAL 文件在检查点之前留着旧页（含原文），而检查点可能被阻塞；回滚日志在提交时就没了，平时只有一个文件。
- `temp_store=MEMORY`：没有临时文件。
- 写失败时丢弃整个缓存（数据都能从服务端重新拉），不留下可能含已删原文的文件。
- 文件设置了不进备份。
- 进程被杀期间被删除的消息：启动后第一次连接时重新拉一遍缓存范围，清掉原文。

被踢、退出登录、换账号时删除文件。**已经展示的系统推送通知无法撤回**（PRD-admin F-ADM-31 规则 6）。

## 开发

```bash
swift test --skip TiantingIMIntegrationTests   # 单元测试（假传输层 + 假时钟）
swift test --filter TiantingIMIntegrationTests # 集成测试：go build 并启动真实 im-server
python3 -I scripts/gen-errors/gen_errors.py    # 从 protocol/errors.json 重新生成 ErrorCodes.gen.swift（--check 只比较）
scripts/sync-protocol.sh                       # 从 tianting-server 检出同步 protocol/，并重新生成错误码
```

集成测试需要 Go 和 tianting-server 的源码：环境变量 `TIANTING_SERVER_DIR`，否则找同级目录的 `../tianting-server/server`、`../im-mvp/server`；都没有时跳过。

单元测试结束时，每个客户端发出的每一帧都要通过 `protocol/schema/frame.schema.json` 校验。

CI 的集成测试要读私有仓库 tianting-server：仓库所有者运行一次 `scripts/setup-ci-deploy-key.sh`（生成只读 Deploy key，设置 secret `TIANTING_SERVER_DEPLOY_KEY`，删除本地密钥）。没配置时 CI 只跑单元测试。

## 天听的项目

| 仓库 | 内容 |
|---|---|
| [tianting-server](https://github.com/leetonny001/tianting-server) | Go 服务端、协议、需求 / 架构 / 测试文档 |
| [tianting-sdk-ts](https://github.com/leetonny001/tianting-sdk-ts) | SDK（TypeScript）：H5、PC |
| [tianting-sdk-kotlin](https://github.com/leetonny001/tianting-sdk-kotlin) | SDK（Kotlin）：Android |
| [tianting-sdk-swift](https://github.com/leetonny001/tianting-sdk-swift) | SDK（Swift）：iOS |
| [tianting-ios](https://github.com/leetonny001/tianting-ios) | iOS 客户端 |
