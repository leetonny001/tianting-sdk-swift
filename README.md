# tianting-sdk-swift

天听 IM SDK（Swift）：iOS 的网络层与数据层。**天听**是自研的独立 IM 产品。

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

测试替身：`TiantingIMTesting` 导出 `FakeTransport`、`FakeClock`、`FakeHttp`、`MemorySessionStore`，界面的测试也可以用。

## 账号（PRD-chat 第 5、13.1 节）

`AccountClient` 是账号 HTTP 接口和账号会话，独立于 `IMClient`。语义和 tianting-sdk-ts 相同，基准是 tianting-server 的 `docs/sdk/README.md` 第 6 节。

```swift
var o = AccountClientOptions(baseUrl: "https://im.example.com")   // 不带 /v1
o.store = keychainStore                                    // 实现 AccountSessionStore，见下
o.unregisterSystemPushToken = { /* C3 接入 APNs 后调 unregisterForRemoteNotifications */ }
let account = AccountClient(options: o)                    // @MainActor
account.on { event in
    if case .ended(let end) = event { backToLogin(end.dialogText()) }   // 有文案就弹窗；end.action == .banNotice 是封禁
}
try await account.start()                                  // 读 Keychain，发送待退出；已过期的先刷新
let r = try await account.login(username: name, password: password)
if let code = r.recoveryCode { showSavePage(code) ; try await account.ackRecoveryCode(gen: r.recoveryCodeGen!) }
im.connect(tokenProvider: account.tokenProvider)           // 自动刷新、换 token 重连；im.connect(token:) 是演示模式，行为不变
```

接口：`register`、`login`、`refresh`、`logout`、`logoutOthers`、`changePassword`、`recover`、`regenerateRecoveryCode`、`ackRecoveryCode`、`updateProfile`、`getConfig`、`listEvents`、`requestDelete`、`cancelDelete`。错误：`AccountError`（服务端的码）、`AccountNetworkError`（没有拿到服务端的码）、`SessionEndedError`。`IMEvent` 增加 `.securityNotice`、`.recoveryCodeUnacked`、`.profileChanged`，`FatalReason` 增加 `.session`，`.kicked` 增加 `recoverBefore`。

**`AccountSessionStore` 的契约**：Session 由 App 的 Keychain 保存，SDK 只回调。

- `save` 返回就表示已经写好。新 token 要等 `save` 返回才使用（R-CF-09），所以这之后杀 App，下次启动用的是服务端认识的值。`save` 抛错时继续用旧值，按退避重试。
- 恢复码确认之前不调 `save`，存储里的旧值当场 `clear`（RS5-13）。这期间杀 App，下次回登录页。
- 调用不重叠，按顺序到达。
- `savePendingLogouts` 只有 `sid` 和 refresh token，**要在 `clear()` 之后还留着**，和 Session 分开存（F-ACC-04 规则 1）。退出时先写记录、清 Session，再发请求，服务端确认或明确拒绝才删；发不出去时留到联网（`networkOnline()`，`systemEvents` 打开时自动）、回前台、下次启动或下次登录再发，失败按退避重试 5 次，最多留 8 条。恢复码还没确认的 token 只有请求失败时才写进来（和 sdk-kotlin 相同）。

`AccountSession` 是 `Codable`，老数据 `{userId, token}` 和没有 `mode` 的都读成 `demo`（R-CF-11）。`AccountSession`、`AuthResult`、`RecoveryCodeResult`、`PendingLogout`、`HttpRequest` 的 `description` 和 `dump` 都不含凭证；日志只有方法、路径、状态码、错误码和动作，没有 URL。

**URLSession 的隐式重试**（第 21 节 16）：`Tests/TiantingIMTests/URLSessionRetryTests.swift` 用真实 socket 数到达的请求（macOS、回环、HTTP/1.1，**没有覆盖 iOS、HTTP/2、HTTP/3、真实网关**）。POST 在新连接、复用连接被关闭或重置、超时、取消时，以及 `503`、`429` 带 `Retry-After: 0`、`408`、`421` 时都只到达 1 次，重定向不跟随；同样场景下 GET 会被重发（3 个请求），说明测试看得见重发。**带 `WWW-Authenticate` 的 401 实测会让 URLSession 再发一次 POST**（默认处理、拒绝保护空间、空凭证都一样），所以 SDK 遇到 HTTP 认证质询直接取消请求，按网络错误处理；服务端不发这个头，**网关不能给 `/v1/` 加这个头**，否则刷新的 4019 会被当成网络错误一直退避。

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

## 图片和文件（PRD-chat C2，第 6、13.1 节）

```swift
var o = IMClientOptions(url: url)
o.files = FileClient(auth: account)   // AccountClient 实现 FileAuth（4011 按规则 7）；演示模式用 StaticTokenAuth(baseUrl:token:)
o.attachmentDirectory = ...           // 发送前的沙盒副本，默认 databaseDirectory/tianting-attachments
o.fileCacheDirectory = ...            // 下载缓存（键 fileId + variant），默认 Caches/tianting-files
let im = IMClient(options: o)

// 图片处理（压缩、缩略图 ≤ 480、去 EXIF）在 App 里做，SDK 只收处理好的文件，先复制进自己的沙盒再上传。
try im.sendImage(convId, ProcessedImage(original: LocalUpload(file: o, mime: "image/jpeg"),
                                        thumb: LocalUpload(file: t, mime: "image/jpeg"), width: w, height: h),
                 onProgress: { sent, total in ... })
try im.sendImage(convId, process: { try await processPicked(item) })  // 先显示"处理中"，轮到它才处理（并发 1）
try im.sendFile(convId, FileInput(file: url, name: name, mime: mime))
im.cancelUpload(convId, clientMsgId)  // 中止上传、发 DELETE、消息消失；已经在 send 的不能取消；失败的也能删
im.retry(convId, clientMsgId)         // 已 complete 的复用 fileId；没传完的从沙盒副本从头传；没有副本时 error = .sourceMissing
let urls = try await im.getFileUrls([FileUrlItem(fileId: id, variant: .thumb)])  // 同一轮合并成一批（≤ 50），地址只在内存
let file = try await im.download(fileId: id, variant: .original, progress: { got, total in ... })  // 取消调用它的 Task 即可
im.cachedFile(fileId: id, variant: .thumb)  // 已下载的本地文件
// IMEvent.filesExpired(ids)：过期或被删，SDK 已删掉地址和下载缓存，App 清掉自己按 fileId + variant 缓存的东西
```

- 状态：`processing` → `uploading` → `queued`（待发送：已 complete）→ `sending` → `sent`，任何一步可以 `failed`。全局同时只传一个，按选择顺序；文字可以越过。上传的时间不算 10 秒发送超时。
- `error`：`.code(4292)` 额度用完、`.code(4290)` + `errorReason == "uploadPendingLimit"`（都不自动重试）、`.code(4139/4150/4096/5032)`，或 `.network`、`.process`（"无法处理这张图片，请用文件方式发送"）、`.storage`（"存储空间不足"）、`.sourceMissing`（"原文件已不可用，请重新选择"）、`.interrupted`（冷启动时还在处理或上传）、`.timeout`、`.kicked`。`complete` 的 5032 退避 1、2、4 秒重试 3 次；`send` 返回 4096 时有沙盒副本的回到上传中重新上传，不占自动重发次数。
- 沙盒副本：发出后删除，失败保留供手动重发，退出登录、被踢时整目录删除。没发出的图片和文件记在本地库的 `outbox` 表（只有沙盒里的文件名，不存预签名地址），冷启动时处理中、上传中的转失败、不自动重传；已经 complete 的按"排队"规则自动发一次。没有引用的沙盒文件启动时删除。
- 本地库版本 2：版本 1 原地升级（加 `outbox` 表），已有的会话和消息保留。会话记着已核对的 `modVer`，重连只重拉 `modVer` 变了的会话（服务端没有 `modVer` 时全部重拉）；`deleted`、`expired` 只能从假变真，过期的文件名清空。
- 对象存储的 PUT、GET（`URLSessionObjectStoreTransport`）每次用新的会话，不复用连接：断在半路的 PUT 只到达 1 次（`URLSessionRetryTests` 用真实 socket 数过）。GET 会被 URLSession 自己重发，对下载无害（只读、同一个短期地址、2xx 才写文件）。不跟随重定向，不打日志。

## 本地库

每个用户一个 SQLite 文件（文件名是 userId 的十六进制，避免大小写不敏感的文件系统把 alice 和 Alice 合并），保存会话、已确认的消息（每个会话最近 `maxCachedMessagesPerConversation` 条，默认 100）、社交状态和没发出的图片文件（`outbox`）。token、预签名地址和未确认的文本不落盘。

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

账号的集成测试（`AccountIntegrationTests`）用 `IM_REGISTER_MODE=invite`、`IM_REFRESH_OVERLAP=61s`、`IM_TEST_DISABLE_AUTH_LOCK=1` 自己启动一个服务端，有一条要真的等一个 61 秒的窗口。

文件的集成测试（`FileIntegrationTests`）另外启动 `Tests/IntegrationResources/fake_s3.py`（标准库 Python 3，只监听 127.0.0.1，不验签名，只验调度逻辑，和 sdk-ts 是同一个文件），服务端开 `IM_FILES_ENABLED=1`。

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
