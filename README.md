# tianting-sdk-swift

天听 IM SDK（Swift）：iOS 的网络层与数据层。**天听**是自研的微信式 IM 产品。

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
im.muteState(convId)                                       // nil，或 MuteInfo（user / group / groupAll，mutedUntil 永久为 .permanent；全群禁言不限制群主、管理员）
im.disconnect()                                            // 退出登录：以 1000 关闭，清内存和本地库
im.close()                                                 // 只停止连接，保留本地库
```

社交：`applyFriend`、`respondFriend`、`deleteFriend`、`setFriendRemark`、`block`、`unblock`、`markFriendRequestsSeen`、`relationOf`、`searchUser`、`setSearchable`、`getUsers`、`loadMyGroups`、`refreshSocial`；快照 `friends()`、`friendRequests()`、`blocks()`、`socialSettings()`、`socialLoaded()`、`profileOf`、`displayName`。

群：`createGroup`、`inviteToGroup`、`leaveGroup`、`kickFromGroup`、`transferGroupOwner`、`setGroupAdmin`、`dissolveGroup`、`updateGroup`、`getGroupInfo`、`loadGroupMembers`；`tipText` 生成提示消息的本地文案。

工具：`c2cConvId`、`groupConvId`、`parseConvIdStrict`、`peerId`、`checkText`、`trimText`、`countCodePoints`、`describeError`、`messageFor`、`ErrorCode`、`CloseCode`、`avatarColorIndex`、`avatarInitial`、`pinyinGroup`。

测试替身：`TiantingIMTesting` 导出 `FakeTransport`、`FakeClock`，界面的测试也可以用。

## 系统推送（PRD-live v1.1 第 4 节）

```swift
let sub = im.onPush { p in                                 // 主线程回调；{ pushId, type, data, ts, target, roomId, pushSeq, replayed }
    handle(p)                                              // 按 type 分发由业务负责，按 pushId 幂等
}
im.onPushSynced { latestSeq in ... }                       // 一轮补拉结束，可选
for await p in im.pushes { ... }                           // 或者用流；每次读 pushes 是一条新的流
im.pushCursor()                                            // 已交付的最大连续序号；还没有游标时为 nil

options.pushStart = .latest                                // 没有游标时只建立游标、不回放（灰度用），默认 .beginning
options.pushCursorStore = FilePushCursorStore(directory: dir)   // 默认就是文件，在 Application Support/tianting-push-cursors
options.pushCursorStore = nil                              // 只在内存：每个新实例从 afterSeq 0 开始，行为同 H5
```

- **只有 `onPush` 和正在迭代的 `pushes` 才算订阅者**；通用的 `on`、`events()` 不算，只创建 `pushes` 不迭代也不算（从第一次 `next()` 起算，任务取消或流和迭代器释放后结束）。没有订阅者时不发 `pushSync`，带 `pushSeq` 的实时帧丢弃，之后从收件箱补回；不带 `pushSeq` 的（全员、按房间、`ttlSeconds=0`）进上限 500 的队列，溢出丢最旧。
- 注册后到下一个调度点才生效（主线程任务，或者先到的网络事件、定时器）：先交付队列，再补拉；同一调度点注册的都能收到积压。
- 带 `pushSeq` 的至少一次，业务按 `pushId` 幂等；不带的至多一次。`replayed = ts < T0`，`T0` 是本实例上该账号第一次 `auth` 的 `serverTime`，重连不变。
- **游标不在本地库里**（4.9 节）：本地库退出、换号、被踢、损坏、Schema 升级都会清，游标在单独的文件里，按 userId 分键，只有游标数字和最近 2000 个 `pushId`，不含内容，不进备份。按批落盘：一个 ack 或一次实时帧处理完写一次，在交付之后，所以进程在中间退出时最多重复一批。文件损坏或读不了按没有游标处理。只有卸载、清应用数据、换设备才回放。
- SDK 不把 `data` 写进日志；`Push` 的 `description`、`dump` 也不含 `data`。服务端未开启（4001）时静默，这次连接内不再发。
- 行为判据是 `protocol/vectors/push-sync.json`，71 个用例全跑（`Tests/TiantingIMTests/PushVectorTests.swift`）。

## 本地库

每个用户一个 SQLite 文件（文件名是 userId 的十六进制，避免大小写不敏感的文件系统把 alice 和 Alice 合并），保存会话、已确认的消息（每个会话最近 `maxCachedMessagesPerConversation` 条，默认 100）和社交状态。token 和未确认的消息不落盘。

被删除的原文要从磁盘文件里消失（AC-ADM-31-4），所以：

- `secure_delete=ON`：释放的单元和页清零；SQLite 不接受这个设置时退回 `VACUUM`。
- `journal_mode=DELETE`，不用 WAL：WAL 文件在检查点之前留着旧页（含原文），而检查点可能被阻塞；回滚日志在提交时就没了，平时只有一个文件。
- `temp_store=MEMORY`：没有临时文件。
- 写失败时丢弃整个缓存（数据都能从服务端重新拉），不留下可能含已删原文的文件。
- 文件设置了不进备份。
- 进程被杀期间被删除的消息：启动后第一次连接时重新拉一遍缓存范围，清掉原文。

被踢、退出登录、换账号时删除文件（推送游标不在这里，见上一节）。**已经展示的系统推送通知无法撤回**（PRD-admin F-ADM-31 规则 6）。

## 开发

```bash
swift test --skip TiantingIMIntegrationTests   # 单元测试（假传输层 + 假时钟）
swift test --filter TiantingIMIntegrationTests # 集成测试：go build 并启动真实 im-server
python3 -I scripts/gen-errors/gen_errors.py    # 从 protocol/errors.json 重新生成 ErrorCodes.gen.swift（--check 只比较）
scripts/sync-protocol.sh                       # 从 tianting-server 检出同步 protocol/，并重新生成错误码
```

推送的集成测试（`PushIntegrationTests`）自己用 `IM_PUSH_ENABLED=1` 启动一个服务端，开关关闭时的行为在 `PushDisabledIntegrationTests`。

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
