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
- `error`：`.code(4292)` 额度用完、`.code(4290)` + `errorReason == "uploadPendingLimit"`（都不自动重试）、`.code(4139/4150/4096/5032)`，或 `.network`、`.process`（"无法处理这张图片，请用文件方式发送"）、`.storage`（"存储空间不足"）、`.sourceMissing`（"原文件已不可用，请重新选择"）、`.interrupted`（冷启动时还在处理或上传）、`.timeout`、`.kicked`。`complete` 的 5032 退避 1、2、4 秒重试 3 次；`send` 返回 4096，或这台设备自己上传（`complete` 成功过）的 `fileId` 返回 4048（24 小时未绑定被清理，PRD-chat v1.4 F-FILE-07 规则 4），有沙盒副本的回到上传中重新上传，不占自动重发次数，没有的 `.sourceMissing`；别人的 `fileId` 收到 4048 照常失败。改头像后 `IMClient` 重新拉一次自己的资料（`TokenProvider.onProfileChanged` 带 `ProfileChange`，问题 H13）。
- 沙盒副本：发出后删除，失败保留供手动重发，退出登录、被踢时整目录删除。没发出的图片和文件记在本地库的 `outbox` 表（只有沙盒里的文件名，不存预签名地址），冷启动时处理中、上传中的转失败、不自动重传；已经 complete 的按"排队"规则自动发一次。没有引用的沙盒文件启动时删除。
- 本地库版本 2（C4 起是 3，见上一节）：版本 1 原地升级（加 `outbox` 表），已有的会话和消息保留。会话记着已核对的 `modVer`，重连只重拉 `modVer` 变了的会话（服务端没有 `modVer` 时全部重拉）；`deleted`、`expired` 只能从假变真，过期的文件名清空。
- 对象存储的 PUT、GET（`URLSessionObjectStoreTransport`）每次用新的会话，不复用连接：断在半路的 PUT 只到达 1 次（`URLSessionRetryTests` 用真实 socket 数过）。GET 会被 URLSession 自己重发，对下载无害（只读、同一个短期地址、2xx 才写文件）。不跟随重定向，不打日志。

## 撤回、引用、@（FE-663、FE-664，C4）

语义和 sdk-ts、sdk-kotlin 相同（tianting-server 的 `docs/sdk/README.md` C4 部分）。服务端开关 `IM_MSG_ACTIONS_ENABLED`；`AccountConfig.features.msgActions` 为 `false` 时页面只留"复制"（老服务端没有这个字段，为 `nil`）。

```swift
try im.send(convId, text, quote: QuoteRef(msgId: id), mentions: Mentions(userIds: ["u2"], all: false))
                                                 // 上行 quote 只发 msgId；mentions 只在群聊（单聊抛 IMArgumentError），userIds 去重
try await im.recall(convId, msgId)               // 成功后本地立即撤回；4097（details.windowSeconds）、4030、4044 抛 IMError，不自动重试
im.canRecall(m, myRole: nil)                     // 按 ts 和 auth ack 校正后的服务端时间：自己的 2 分钟；群主、管理员 7 天
im.messageActions(m)                             // [.copy, .quote, .recall] 的子集；撤回、删除的消息和提示行是 []
im.recallText(m)                                 // "你撤回了一条消息" 等（F-RCL-02 规则 1a）；列表摘要用 recallText(convId:lastMsg:)
try await im.searchGroupMembers(groupId, keyword: "zh")   // @ 选人；4290 不自动重试
messageFor(cmd: "recall", code: 4097, windowSeconds: 120) // "发送时间超过 2 分钟，无法撤回"；send 4293 "@所有人次数已用完"
quoteSummary(m); quoteLabel(quote)               // 引用摘要（规则 2）；引用条文字（规则 3），不认识的 state "引用内容不可用"
```

| | |
|---|---|
| 模型 | `Message.recalled`、`recalledAt`、`recalledBy`（同时 `deleted == true`）；`MsgBody.quote`（`QuoteView`：msgId、seq、from、type、state、text）、`mentions`；`LastMsg.recalled`、`recalledBy`；`Conversation.mentionUnread`、`firstMentionSeq`；`IMError.reason`、`Message.errorReason`（4040 的 `quoteUnavailable`） |
| 单调合并 | `deleted`、`recalled` 只能从假变真；`quote.state` 只能从 normal 往后走，`quote.text` 清除后不恢复；迟到的旧 sync、ack 带着原文也写不回来（F-RCL-03 规则 2a，`chat-sync.json`）。`convs` 的 `lastMsg` 带 `recalled` 时已加载的那条直接按撤回清（问题 32） |
| 收到撤回 | `msgDeleted` 带 `recalled`：清除原文，本会话里引用它的消息（含待发的）的 `quote.text` 一起清掉、状态改 recalled（后台删除是 deleted，F-QUO-02 规则 4）；文件的地址和下载缓存清掉，发 `.filesExpired` |
| 下载中被撤回 | 正在下载的文件所在消息被撤回、删除或过期：中止下载、删掉部分文件，`download` 抛 `DownloadAbortedError(fileId, recalled)`，发 `.downloadAborted(fileId:recalled:)`；App 据此提示"该消息已被撤回"（AC-RCL-03-12）。调用方自己取消仍是 `FileTransferError.cancelled` |
| 提及 | 实时收到 @ 我或 @ 所有人的未读消息本地 +1（自己发的、已读位置之前的、服务端没给过计数的会话不推算），本端读到最新清零；有提及的会话收到 `readUpdated`、`msgDeleted` 时节流 5 秒重拉 `convs`（窗口内的推迟到窗口结束，断线时不拉，退出登录清定时器） |
| 本地库 | 第 3 版：新表 `deleted_refs`（已删除的 msgId、seq 和撤回信息，含没加载过的消息，跨冷启动保留，问题 17）。第 1、2 版原地升级，旧行保留；更新或不认识的版本按缓存重建。撤回、清引用后照样 `secure_delete`（不支持时 VACUUM），数据库文件里搜不到原文 |
| 日志 | 引用文字、@ 的内容不进日志（`QuoteView.description` 不带 text） |

## 置顶、免打扰、删除会话（FE-682，C5）

语义和 sdk-ts（FE-680）、sdk-kotlin（FE-681）相同（PRD-chat 第 9 节）。服务端开关 `IM_CONV_SETTINGS_ENABLED`；`AccountConfig.features.convSettings` 为 `false` 时页面不出菜单（老服务端没有这个字段，为 `nil`），关闭时只拦新命令（4030），已有的置顶、免打扰、删除 SDK 照常应用（P-46 ②）。

```swift
try await im.setConvPinned(convId, true)     // 乐观更新：先移到最前；ack 的 conv 覆盖本地；失败回滚并抛出，不自动重试
try await im.setConvNotifyOff(convId, true)  // 同上（4220 置顶已满、4290、4030、5000、超时、未连接都回滚）
try await im.deleteConv(convId)              // upToSeq = 本地看到的最大 seq；先从列表消失，失败恢复；确认框由 App 弹
im.totalUnread()                             // 普通会话的 unread 之和 + 免打扰会话的 mentionUnread 之和；.totalUnread 同口径
// IMEvent.convDeleted(convId:)：本端删除成功或其他设备删除了它，App 清这个会话的草稿
```

| | |
|---|---|
| 模型 | `Conversation.pinned`、`pinnedAt`、`notifyOff`（没有时为 nil，按 false；`isPinned`、`isNotifyOff`）；`conversations()` 置顶的在前按 `pinnedAt` 倒序，其余 `updatedAt` 倒序，同时间按 `convId`；置顶时间相同时再按 `updatedAt` 倒序、`convId`（和服务端 `convListOrder` 一致） |
| 多端 | `convSettingsChanged` 覆盖本地；等 ack 期间其他端改过的，失败时不回滚成旧值。重连靠 `convs`，以服务端为准 |
| 删除 | `minSeq = clearedSeq + 1`、已读推进到 `clearedSeq`、不再置顶、保留免打扰；`seq < minSeq` 的消息从内存、本地库和下载缓存清除（`.filesExpired`），迟到的 sync、ack 不写回（我自己的、ack 落在清除范围内的待发消息一起去掉）。本端删除时这个会话的附件取消上传（服务端删临时对象）、排队和失败的消息丢弃（问题 59），发送中的不动；其他设备删除时本机没发出的消息保留（问题 63）。之后有新消息会话按删除时的状态重新出现，未读只算新消息 |
| 引用 | 保留下来的消息（seq ≥ minSeq）里的引用摘要照常显示（P-46 ④）；只有还没发出、引用了被清除消息的，引用原文清除（state 改 deleted，问题 62） |
| `convs` | `deleted` 里的群不是"你已不在该群"（没有 `.convRemoved`、没有快照，AC-CVS-03-5）；`truncated` 或 `deletedTruncated` 时不推断（问题 54）；列表里的会话（和 `convAdded`）按各自的 `minSeq` 清除；服务端的 `minSeq` 比本地下限小（重新入群按新成员算、`historyVisible`，规则 6a，问题 65）时放低下限，旧历史可以重新加载 |
| 本地库 | 第 4 版：新表 `pending_purges`。清除前先记"待清除"（单独一个事务），删除消息行、释放的页清零（不支持 `secure_delete` 时 VACUUM）、缓存文件删掉之后才去掉记录；中途失败或进程被杀，下次启动先补做（F-CVS-03 异常）。置顶、免打扰在会话 JSON 里，冷启动先显示。第 1～3 版原地升级 |

## 举报、内容拦截（FE-692，C6）

语义和 sdk-ts（FE-690）、sdk-kotlin（FE-691）相同（PRD-chat 第 10 节）。入口按 `AccountConfig.features.moderation`（服务端 `IM_MOD_ENABLED`；老服务端没有，为 `nil`，按关闭）；4510 的提示和它无关。

```swift
let reportId = try await im.report(.message(convId: convId, msgIds: [msgId], reason: .abuse, note: note)) // 页面只举报单条
try await im.report(.user(userId, reason: .spam))
try await im.report(.group(groupId, reason: .illegal))
im.canReport(m)   // 消息菜单有没有"举报"（三套 SDK 同一口径，问题 77、88、89、92）
im.canRetry(m)    // 失败气泡有没有"重发"：4510（内容被拦截）和 sourceMissing 没有，只有"复制""删除"
messageFor(cmd: "send", code: 4510)  // "消息包含不当内容，无法发送"；其他命令和账号接口："内容包含不当信息，请修改后重试"
```

| | |
|---|---|
| `report` | 本地先校验：`targetType` 互斥（`message` 带 `convId`、`msgIds`；`user` 带 `userId`；`group` 带 `groupId`，带了别的对象的字段——空串也算——都不行），`reason` 六选一（`ReportReason.all`），`msgIds` 1～20 条且格式合法，`note` 不超过 200 个码点，不能是聊天室，单聊自己必须是参与者（还没登录时只校验格式）。不合法抛 `IMError` 4000（`details["field"]`），不发帧。服务端的 4292、4040 `reportTargetInvalid`、4030 `featureDisabled`、4290、5000、超时、未连接原样抛出，不自动重试；文案 `messageFor(cmd: "report", code:)`。`note` 不进日志和错误信息 |
| `canReport` | 别人发的、已经发送成功（有 msgId）的 `text`、`image`、`file`，会话是单聊（我是参与者）或群。自己的、`tip`、`custom`、发送中、排队、失败的、后台删除的都没有。撤回的（撤回提示行，F-MOD-03 规则 2a）只在别人的、不是我撤回的消息上有（撤回者不知道时按别人撤回，问题 89），自己的消息被别人撤回也没有。只有本机看过的：`seq ≤` 本地会话的 `readSeq`（服务端校验 `readSeq ≥ seq`），会话不在本地列表里的没有（问题 92）。开关由页面另外判断 |
| 4510 | `send`、`sendImage`、`sendFile` 收到 4510：标记失败、`error == .code(4510)`，不自动重发，`retry` 也不发、不重新上传；超时之后才到的 4510 同样改成 4510（不再发 `.sendFailed`）。错误里没有命中的词。图片、文件的失败原因随 `outbox` 进本地库，冷启动后仍然没有"重发"（文本的失败消息本来就不落盘）。其他 WS 命令（建群、改群名和公告、好友申请）的 4510 原样抛 `IMError`；账号接口（注册、改昵称）抛 `AccountError(status: 451, code: 4510)` |

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

举报和内容拦截的集成测试（`ReportIntegrationTests`、`BlockedIntegrationTests`）用 `IM_MOD_ENABLED=1` 和测试专用的 `IM_REPORT_KEY` 启动服务端；后者的调用方多一个 `moderation.words` scope（`TestServer.start(env:extraScopes:)`，不加进公共 scope，免得服务端不认识时其他用例跟着失败），只用特征词。

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
