package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class LocalDirectTests {
    private val identity = PublicIdentity(targetId, PublicHandle("friend"), "已知朋友", AccountKind.Regular)
    private open class Memory : DirectRoomStore, LocalDirectMessageStore {
        val works = mutableListOf<DirectRoomWork>(); val messages = mutableListOf<LocalDirectMessage>()
        override val localDirectMessageChanges = MutableStateFlow(0L)
        var existing: RoomId? = null
        override suspend fun prepareDirect(command: DirectRoomCommand) = prepareDirect(command, PublicIdentity(command.target, PublicHandle("friend"), "对方", AccountKind.Regular))
        override suspend fun prepareDirect(command: DirectRoomCommand, identity: PublicIdentity): DirectRoomWork =
            works.firstOrNull { !it.terminal && it.command.target == command.target } ?: DirectRoomWork.fresh(command, identity).also { works.add(it) }
        override suspend fun directWorks() = works.toPersistentList()
        override suspend fun updateDirect(expected: DirectRoomWork, updated: DirectRoomWork) { works[works.indexOf(expected)] = updated }
        override suspend fun existingDirectRoom(actor: UserId, target: UserId) = existing
        override suspend fun saveLocalDirectMessage(actor: UserId, message: LocalDirectMessage) { messages.add(message) }
        override suspend fun localDirectMessages(actor: UserId, operation: String?) = messages.filter { operation == null || it.operation == operation }.toPersistentList()
        override suspend fun prepareNextLocalDirectMessage(actor: UserId, now: Long) = false
    }
    @Test fun `known peer enters durable local chat without waiting for a network request`() = runTest {
        val store = Memory()
        val service = DirectRoomService(actorId, DirectRoomClient(FakeEdge { _, _ -> fail("local opening requested HTTP") }), store, {1000}, {0})
        val destination = service.openLocal(identity) as DirectConversationDestination.Pending
        assertEquals(destination, service.openLocal(identity))
        assertEquals(destination.operation, store.works.single().command.operation)
        val message = LocalDirectMessage.create(destination.operation, "  本机正文  ", 1000)
        service.enqueueLocalMessage(message); assertEquals("本机正文", service.pendingMessages(destination.operation).single().text)
        assertFalse(service.prepareLocalMessages())
        store.existing = RoomId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")
        assertEquals(DirectConversationDestination.Room(store.existing!!), service.openLocal(identity)); assertEquals(1, store.works.size)
        assertFailsWith<IllegalArgumentException> { service.openLocal(identity.copy(user = actorId)) }
    }
    @Test fun `preparation waits for a new signal after storage failure and retires with owner`() = runTest {
        var calls = 0; var fail = true; var ready = false; var changes = 0; var errors = 0
        val store = object : Memory() {
            override suspend fun prepareNextLocalDirectMessage(actor: UserId, now: Long): Boolean {
                calls++; if (fail) throw java.io.IOException()
                return ready.also { ready = false }
            }
        }
        val service = DirectRoomService(actorId, DirectRoomClient(FakeEdge { _, _ -> error("HTTP") }), store)
        val job = backgroundScope.launch { service.runLocalMessagePreparation({ changes++ }, { errors++ }) }
        runCurrent(); assertEquals(1, calls); assertEquals(1, errors)
        advanceTimeBy(60_000); runCurrent(); assertEquals(1, calls)
        fail = false; ready = true; store.localDirectMessageChanges.value++; runCurrent()
        assertEquals(3, calls); assertEquals(2, changes)
        job.cancelAndJoin(); store.localDirectMessageChanges.value++; runCurrent(); assertEquals(3, calls)
    }
    @Test fun `waiting locally preserves creation time without consuming send preparation deadline`() {
        val message = LocalDirectMessage.create(directCommand().operation, "等待了两天", 1000)
        val now = 2 * 86_400_000L
        val intent = SendIntent(message.id, actorId, RoomId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"), message.id,
            message.text, persistentListOf(), message.createdAt, now + 86_400_000, preparationStartedAt = now)
        assertEquals(1000, intent.createdAt); assertEquals(now + 86_400_000, intent.deadline)
        assertEquals(intent, Json.decodeFromString<SendIntent>(Json.encodeToString(SendIntent.serializer(), intent)))
        val legacy = intent.copy(createdAt = 1000, preparationStartedAt = 1000, deadline = 86_401_000)
        val legacyJson = Json.encodeToJsonElement(SendIntent.serializer(), legacy).jsonObject
        assertEquals(legacy, Json.decodeFromJsonElement<SendIntent>(JsonObject(legacyJson - "preparationStartedAt")))
    }
    @Test fun `local and wire text share the Swift 65536 byte boundary`() {
        val operation = directCommand().operation; val text = "界".repeat(21845) + "a"
        val message = LocalDirectMessage.create(operation, text, 1)
        assertEquals(65536, message.text.toByteArray().size)
        val room = RoomId("EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")
        val command = MessageCommand.text(actorId, room, text, 600001, message.id)
        assertEquals(message.id, command.clientMessageId); assertEquals(text, command.text)
        assertFails { LocalDirectMessage.create(operation, text + "b", 1) }
        assertFails { MessageCommand.text(actorId, room, text + "b", 600001) }
        assertFails { LocalDirectMessage.create(operation, " \n ", 1) }
        assertFails { LocalDirectMessage("fake-room", operation, "正文", 1) }
    }
}
