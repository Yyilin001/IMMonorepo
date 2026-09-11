import Foundation
import IMV2Core
@testable import IMV2Server
import SwiftProtobuf
import Testing

@Suite("V2 room summary")
struct V2RoomSummaryStoreTests {
    @Test("request rejects an out-of-range page size")
    func rejectsOutOfRangePageSize() throws {
        let user = try UserID("00000000-0000-0000-0000-00000000a001")
        #expect(throws: V2RoomSummaryError.invalidRequest) {
            _ = try V2RoomSummaryRequest(actorUserID: user, cursor: nil, pageSize: 0)
        }
        #expect(throws: V2RoomSummaryError.invalidRequest) {
            _ = try V2RoomSummaryRequest(
                actorUserID: user, cursor: nil,
                pageSize: V2RoomSummaryRequest.maximumPageSize + 1
            )
        }
        // 上限只约束一页，不约束可以加入多少房间：正好一页也是合法请求。
        let request = try V2RoomSummaryRequest(
            actorUserID: user, cursor: nil,
            pageSize: V2RoomSummaryRequest.maximumPageSize
        )
        #expect(request.cursor == nil)
    }

    @Test("service pairs activity rows with latest visible messages")
    func pairsActivityWithMessages() async throws {
        let user = try UserID("00000000-0000-0000-0000-00000000a002")
        let roomA = try RoomID("00000000-0000-0000-0000-00000000a101")
        let roomB = try RoomID("00000000-0000-0000-0000-00000000a102")
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let store = SummaryStoreFake(
            activity: .init(
                rooms: [
                    .init(roomID: roomA, roomKind: .group, head: 9,
                          lastEventAtMicroseconds: summaryMicroseconds(base), unreadCount: 4),
                    // 房间还没有可见消息：摘要仍然要有这一行，否则会话会从列表里消失。
                    .init(roomID: roomB, roomKind: .direct, head: 0,
                          lastEventAtMicroseconds: summaryMicroseconds(base.addingTimeInterval(-1)), unreadCount: 0),
                ],
                hasMore: false
            ),
            messages: [
                .init(
                    roomID: roomA, messageID: try MessageID("00000000-0000-0000-0000-00000000a201"),
                    senderUserID: user, roomSequence: 9, text: "hello",
                    isWithdrawn: false, mediaCount: 0, serverCreatedAt: base
                ),
            ]
        )
        let page = try await V2RoomSummaryService(store: store)
            .summaries(V2RoomSummaryRequest(actorUserID: user, cursor: nil, pageSize: 10))

        #expect(page.rooms.count == 2)
        #expect(page.rooms[0].unreadCount == 4)
        #expect(page.rooms[0].latestMessage?.roomSequence == 9)
        #expect(page.rooms[1].latestMessage == nil)
        #expect(page.nextCursor == nil)
    }

    @Test("service returns a next cursor only when the store has more")
    func emitsNextCursor() async throws {
        let user = try UserID("00000000-0000-0000-0000-00000000a003")
        let room = try RoomID("00000000-0000-0000-0000-00000000a103")
        let base = Date(timeIntervalSince1970: 1_750_000_500)
        let store = SummaryStoreFake(
            activity: .init(
                rooms: [.init(roomID: room, roomKind: .group, head: 3,
                              lastEventAtMicroseconds: summaryMicroseconds(base), unreadCount: 0)],
                hasMore: true
            ),
            messages: []
        )
        let page = try await V2RoomSummaryService(store: store)
            .summaries(V2RoomSummaryRequest(actorUserID: user, cursor: nil, pageSize: 1))

        #expect(page.nextCursor == V2RoomSummaryCursor(
            lastEventAtMicroseconds: summaryMicroseconds(base), roomID: room
        ))
    }

    @Test("service refuses a summary whose message is newer than the room head")
    func rejectsMessageBeyondHead() async throws {
        let user = try UserID("00000000-0000-0000-0000-00000000a004")
        let room = try RoomID("00000000-0000-0000-0000-00000000a104")
        let base = Date(timeIntervalSince1970: 1_750_000_600)
        let store = SummaryStoreFake(
            activity: .init(
                rooms: [.init(roomID: room, roomKind: .group, head: 4,
                              lastEventAtMicroseconds: summaryMicroseconds(base), unreadCount: 0)],
                hasMore: false
            ),
            messages: [
                .init(
                    roomID: room, messageID: try MessageID("00000000-0000-0000-0000-00000000a204"),
                    senderUserID: user, roomSequence: 5, text: "future",
                    isWithdrawn: false, mediaCount: 0, serverCreatedAt: base
                ),
            ]
        )
        await #expect(throws: V2RoomSummaryError.corruptPersistenceState) {
            _ = try await V2RoomSummaryService(store: store)
                .summaries(V2RoomSummaryRequest(actorUserID: user, cursor: nil, pageSize: 10))
        }
    }

    @Test("service refuses two summaries for the same room")
    func rejectsDuplicateRoomSummaries() async throws {
        let user = try UserID("00000000-0000-0000-0000-00000000a005")
        let room = try RoomID("00000000-0000-0000-0000-00000000a105")
        let base = Date(timeIntervalSince1970: 1_750_000_700)
        let message = V2RoomSummaryMessage(
            roomID: room, messageID: try MessageID("00000000-0000-0000-0000-00000000a205"),
            senderUserID: user, roomSequence: 2, text: "dup",
            isWithdrawn: false, mediaCount: 0, serverCreatedAt: base
        )
        let store = SummaryStoreFake(
            activity: .init(
                rooms: [.init(roomID: room, roomKind: .group, head: 2,
                              lastEventAtMicroseconds: summaryMicroseconds(base), unreadCount: 0)],
                hasMore: false
            ),
            messages: [message, message]
        )
        await #expect(throws: V2RoomSummaryError.corruptPersistenceState) {
            _ = try await V2RoomSummaryService(store: store)
                .summaries(V2RoomSummaryRequest(actorUserID: user, cursor: nil, pageSize: 10))
        }
    }

    @Test("routed store merges shards by activity and keeps the global page boundary")
    func mergesShardsByActivity() async throws {
        let user = try UserID("00000000-0000-0000-0000-00000000a006")
        let base = Date(timeIntervalSince1970: 1_750_001_000)
        let rooms = try (1 ... 4).map { index in
            try RoomID(String(format: "00000000-0000-0000-0000-00000000b%03d", index))
        }
        let first = SummaryStoreFake(
            activity: .init(
                rooms: [
                    .init(roomID: rooms[0], roomKind: .group, head: 5,
                          lastEventAtMicroseconds: summaryMicroseconds(base), unreadCount: 1),
                    .init(roomID: rooms[2], roomKind: .group, head: 2,
                          lastEventAtMicroseconds: summaryMicroseconds(base.addingTimeInterval(-50)), unreadCount: 0),
                ],
                hasMore: false
            ),
            messages: []
        )
        let second = SummaryStoreFake(
            activity: .init(
                rooms: [
                    .init(roomID: rooms[1], roomKind: .direct, head: 8,
                          lastEventAtMicroseconds: summaryMicroseconds(base.addingTimeInterval(20)), unreadCount: 3),
                    .init(roomID: rooms[3], roomKind: .group, head: 1,
                          lastEventAtMicroseconds: summaryMicroseconds(base.addingTimeInterval(-90)), unreadCount: 0),
                ],
                hasMore: true
            ),
            messages: []
        )
        let store = try V2RoutedRoomSummaryStore(
            router: SummaryRouter(routes: [:]),
            stores: ["rooms-a": first, "rooms-b": second]
        )
        let page = try await store.roomActivityWatermarks(after: nil, actorUserID: user, limit: 3)

        #expect(page.rooms.map(\.roomID) == [rooms[1], rooms[0], rooms[2]])
        // 任一存储还有余量时全局就一定还有余量：截断不能把 hasMore 变成 false。
        #expect(page.hasMore)
        #expect(await first.requestedLimits() == [3])
        #expect(await second.requestedLimits() == [3])
    }

    @Test("routed store queries a shared physical database once")
    func queriesSharedPhysicalStoreOnce() async throws {
        let user = try UserID("00000000-0000-0000-0000-00000000a007")
        let room = try RoomID("00000000-0000-0000-0000-00000000b101")
        let shared = SummaryStoreFake(
            activity: .init(
                rooms: [.init(roomID: room, roomKind: .group, head: 1,
                              lastEventAtMicroseconds: summaryMicroseconds(Date(timeIntervalSince1970: 1_750_002_000)),
                              unreadCount: 0)],
                hasMore: false
            ),
            messages: []
        )
        let otherShardOnSameDatabase = SummaryStoreFake(
            activity: .init(rooms: [], hasMore: false),
            messages: []
        )
        let store = try V2RoutedRoomSummaryStore(
            router: SummaryRouter(routes: [:]),
            stores: ["rooms-a": shared, "rooms-b": otherShardOnSameDatabase],
            physicalStoreKeyByShard: ["rooms-a": "primary", "rooms-b": "primary"]
        )
        let page = try await store.roomActivityWatermarks(after: nil, actorUserID: user, limit: 10)

        // 两个逻辑分片共用同一个库时，同一个房间不能被返回两次。
        #expect(page.rooms.map(\.roomID) == [room])
        #expect(await otherShardOnSameDatabase.requestedLimits().isEmpty)
    }

    @Test("routed store sends each room to its own shard")
    func routesVisibleMessagesByRoom() async throws {
        let user = try UserID("00000000-0000-0000-0000-00000000a008")
        let roomA = try RoomID("00000000-0000-0000-0000-00000000b201")
        let roomB = try RoomID("00000000-0000-0000-0000-00000000b202")
        let first = SummaryStoreFake(activity: .init(rooms: [], hasMore: false), messages: [])
        let second = SummaryStoreFake(activity: .init(rooms: [], hasMore: false), messages: [])
        let store = try V2RoutedRoomSummaryStore(
            router: SummaryRouter(routes: [
                roomA: try .init(shardID: "rooms-a", epoch: 1),
                roomB: try .init(shardID: "rooms-b", epoch: 1),
            ]),
            stores: ["rooms-a": first, "rooms-b": second]
        )
        _ = try await store.visibleMessages(roomIDs: [roomA, roomB], actorUserID: user)

        #expect(await first.requestedRoomIDs() == [roomA])
        #expect(await second.requestedRoomIDs() == [roomB])
    }

    @Test("routed store refuses a room whose shard has no configured store")
    func refusesUnknownShard() async throws {
        let user = try UserID("00000000-0000-0000-0000-00000000a009")
        let room = try RoomID("00000000-0000-0000-0000-00000000b301")
        let store = try V2RoutedRoomSummaryStore(
            // 路由解析成功但部署没有配置该分片的存储：必须显式报错，不能静默少一个房间。
            router: SummaryRouter(routes: [room: try .init(shardID: "rooms-zzz", epoch: 1)]),
            stores: ["rooms-a": SummaryStoreFake(activity: .init(rooms: [], hasMore: false), messages: [])]
        )
        await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) {
            _ = try await store.visibleMessages(roomIDs: [room], actorUserID: user)
        }
    }

    @Test("a full page of maximum previews stays inside the frame budget")
    func fullPageStaysInsideFrameBudget() throws {
        // 最坏情况：整页房间，每行都是 80 个 4 字节字符的预览，外加最长游标。
        // 预览截断的意义就在这里——否则一条超长消息就能让合法请求撑爆帧预算。
        var rooms: [IMV2RoomSummary] = []
        rooms.reserveCapacity(V2RoomSummaryRequest.maximumPageSize)
        for index in 0 ..< V2RoomSummaryRequest.maximumPageSize {
            var room = IMV2RoomSummary()
            room.roomID = String(format: "00000000-0000-0000-0000-%012d", index)
            room.roomKind = "group"
            room.head = UInt64(Int64.max / 2)
            room.lastEventAtMs = 1_750_000_000_000
            room.unreadCount = UInt64(Int64.max / 4)
            var message = IMV2RoomSummaryMessage()
            message.messageID = String(format: "00000000-0000-0000-0000-%012d", index)
            message.senderUserID = String(format: "00000000-0000-0000-0000-%012d", index)
            message.roomSequence = UInt64(Int64.max / 2)
            message.text = String(repeating: "😀", count: V2RoomSummaryLimits.maximumPreviewCharacters)
            message.mediaCount = 100
            message.serverCreatedAtMs = 1_750_000_000_000
            room.latestMessage = message
            rooms.append(room)
        }
        var envelope = IMV2Envelope()
        envelope.roomSummaryPage = .init()
        envelope.roomSummaryPage.rooms = rooms
        envelope.roomSummaryPage.nextCursor = String(repeating: "A", count: 512)
        let bytes = try envelope.serializedData().count
        // 网关默认帧预算是 64 KB；这里要求整页连同信封仍留出余量。
        #expect(bytes < 64 * 1_024)
    }

    @Test("cursor round-trips the exact microsecond key")
    func cursorRoundTripsMicroseconds() throws {
        let room = try RoomID("00000000-0000-0000-0000-00000000b401")
        // 同一毫秒内的两个房间靠微秒区分；毫秒游标会把较旧的那个跳过。
        let cursor = V2RoomSummaryCursor(lastEventAtMicroseconds: 1_750_004_000_123_456, roomID: room)
        let decoded = try V2RoomSummaryCursorCodec.decode(V2RoomSummaryCursorCodec.encode(cursor))
        #expect(decoded == cursor)
    }

    @Test("cursor rejects values it cannot prove it wrote")
    func cursorRejectsInvalidValues() throws {
        let room = try RoomID("00000000-0000-0000-0000-00000000b402")
        let valid = try V2RoomSummaryCursorCodec.encode(
            V2RoomSummaryCursor(lastEventAtMicroseconds: 1, roomID: room)
        )
        #expect(throws: V2RoomSummaryError.invalidRequest) {
            _ = try V2RoomSummaryCursorCodec.decode("")
        }
        #expect(throws: V2RoomSummaryError.invalidRequest) {
            _ = try V2RoomSummaryCursorCodec.decode("not-base64!!")
        }
        #expect(throws: V2RoomSummaryError.invalidRequest) {
            _ = try V2RoomSummaryCursorCodec.decode(String(repeating: "A", count: 1_024))
        }
        // 版本不符必须拒绝，而不是按当前格式猜测解析。
        let wrongVersion = Data(
            #"{"version":2,"lastEventAtMicroseconds":1,"roomID":"\#(room.rawValue)"}"#.utf8
        ).base64EncodedString()
        #expect(throws: V2RoomSummaryError.invalidRequest) {
            _ = try V2RoomSummaryCursorCodec.decode(wrongVersion)
        }
        // 负数时间戳不是本服务写出的键。
        let negative = Data(
            #"{"version":1,"lastEventAtMicroseconds":-1,"roomID":"\#(room.rawValue)"}"#.utf8
        ).base64EncodedString()
        #expect(throws: V2RoomSummaryError.invalidRequest) {
            _ = try V2RoomSummaryCursorCodec.decode(negative)
        }
        #expect(try V2RoomSummaryCursorCodec.decode(valid).roomID == room)
    }
}

/// 只记录调用并按预设结果回答的摘要存储。
private actor SummaryStoreFake: V2RoomSummaryStore {
    private let activity: V2RoomActivityPage
    private let messages: [V2RoomSummaryMessage]
    private var limits: [Int] = []
    private var roomIDs: [RoomID] = []

    init(activity: V2RoomActivityPage, messages: [V2RoomSummaryMessage]) {
        self.activity = activity
        self.messages = messages
    }

    func roomActivityWatermarks(
        after _: V2RoomSummaryCursor?,
        actorUserID _: UserID,
        limit: Int
    ) async throws -> V2RoomActivityPage {
        limits.append(limit)
        return activity
    }

    func visibleMessages(roomIDs: [RoomID], actorUserID _: UserID) async throws -> [V2RoomSummaryMessage] {
        self.roomIDs = roomIDs
        return messages.filter { roomIDs.contains($0.roomID) }
    }

    func requestedLimits() -> [Int] { limits }
    func requestedRoomIDs() -> [RoomID] { roomIDs }
}

/// 把展示时间转换成排序键使用的精确微秒整数。
private func summaryMicroseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
}

/// 固定房间归属的路由。
private actor SummaryRouter: V2RoomShardRouting {
    private let routesByRoom: [RoomID: V2RoomShardRoute]

    init(routes: [RoomID: V2RoomShardRoute]) {
        routesByRoom = routes
    }

    func route(for roomID: RoomID) throws -> V2RoomShardRoute {
        guard let route = routesByRoom[roomID] else { throw V2RoomShardRouteError.roomNotFound }
        return route
    }
}
