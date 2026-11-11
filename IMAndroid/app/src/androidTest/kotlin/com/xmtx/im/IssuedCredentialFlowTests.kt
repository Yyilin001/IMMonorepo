package com.xmtx.im

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.SyncBatch
import com.xmtx.imclientkit.generated.im.realtime.v2.SyncRecord
import com.xmtx.im.client.*
import com.xmtx.im.client.Credentials
import com.xmtx.im.platform.*
import kotlinx.coroutines.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class IssuedCredentialFlowTests {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun hash(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    private inner class Fixture {
        val name = "credential-issued-flow-${UUID.randomUUID()}"
        val endpoint = "https://issued.fixture.invalid/"
        val otherEndpoint = "https://replacement.fixture.invalid/"
        val user = UserId(UUID.randomUUID().toString())
        val credentials = Credentials(user, DeviceId(UUID.randomUUID().toString()), "fixture-access", System.currentTimeMillis() + 600_000,
            "fixture-refresh", "imv2-revoke-v1.${"A".repeat(43)}", System.currentTimeMillis() + 3_600_000)
        val allCredentials = CopyOnWriteArrayList<Credentials>().apply { add(credentials) }
        val requests = CopyOnWriteArrayList<Request>()
        val revokeOperations = CopyOnWriteArrayList<String>()
        @Volatile var revokeStatus = 401
        @Volatile var failAuthWrite = false
        @Volatile var failAuthDelete = false
        @Volatile var revokeOffline = false
        @Volatile var failAssertion = false
        @Volatile var cancellationStatus = 204
        val cancellationPayloads = CopyOnWriteArrayList<JsonObject>()
        var cancellationGate: CountDownLatch? = null
        val cancellationEntered = CountDownLatch(1)
        var revokeGate: CountDownLatch? = null
        val revokeEntered = CountDownLatch(1)
        var profileGate: CountDownLatch? = null
        val profileEntered = CountDownLatch(1)
        @Volatile var directSubmission: DirectRoomCommand? = null
        @Volatile var directReceiptReady = false
        val directRoom = RoomId(UUID.randomUUID().toString())
        var directGate: CountDownLatch? = null
        val directEntered = CountDownLatch(1)
        val secrets = KeystoreCredentialStore(context, name)
        val marker = FileLocalExitMarker(context, name)
        val owners = ViewModelStore(); var displayed by mutableStateOf<AppViewModel?>(null)
        val model get() = requireNotNull(displayed)
        val http = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request(); requests.add(request)
            val payload = request.body?.let { body -> Buffer().also { body.writeTo(it) }.readUtf8() }
                ?.let { Json.parseToJsonElement(it).jsonObject }
            var status = 200
            val response = when (request.url.encodedPath) {
                "/v2/account-auth/password/assertion" -> {
                    if (failAssertion) throw IOException()
                    buildJsonObject { put("accountAssertion", "fixture-assertion") }.toString()
                }
                "/v2/device-credentials" -> {
                    val c = credentials.copy(deviceId = DeviceId(payload!!.getValue("deviceID").jsonPrimitive.content),
                        revocationCredential = "imv2-revoke-v1." + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 1 }))
                    allCredentials.add(c)
                    buildJsonObject {
                        put("userID", c.userId.value); put("deviceID", c.deviceId.value); put("accessToken", c.accessToken)
                        put("accessTokenExpiresAtMilliseconds", c.accessExpiresAt); put("refreshCredential", c.refreshCredential)
                        put("revocationCredential", c.revocationCredential); put("revocationCredentialExpiresAtMilliseconds", c.revocationExpiresAt)
                        put("registrationCancellation", payload.getValue("cancellation"))
                    }.toString()
                }
                "/v2/device-credentials/revoke" -> {
                    assertNull(request.header("Authorization")); assertNull(request.header("X-IM-Device-ID"))
                    assertEquals(setOf("credential", "operationID"), payload!!.keys)
                    revokeOperations.add(payload.getValue("operationID").jsonPrimitive.content)
                    revokeEntered.countDown()
                    if (revokeOffline) throw IOException()
                    check(revokeGate?.await(10, TimeUnit.SECONDS) != false)
                    status = revokeStatus; if (status == 204) "" else "{}"
                }
                "/v2/device-credentials/cancel-registration" -> {
                    assertNull(request.header("Authorization")); assertNull(request.header("X-IM-Device-ID"))
                    cancellationPayloads.add(requireNotNull(payload)); cancellationEntered.countDown()
                    check(cancellationGate?.await(10, TimeUnit.SECONDS) != false)
                    status = cancellationStatus; if (status == 204 || status == 410) "" else "{}"
                }
                "/v2/direct-room-operations/submit", "/v2/direct-room-operations/operations/recover" -> {
                    val body = requireNotNull(payload)
                    if (request.url.encodedPath.endsWith("/submit")) {
                        fun id(field: String) = body.getValue(field).jsonObject.getValue("rawValue").jsonPrimitive.content
                        directSubmission = DirectRoomCommand(UserId(id("actorUserID")), UserId(id("targetUserID")), id("operationID"),
                            body.getValue("firstSubmissionDeadlineMilliseconds").jsonPrimitive.long)
                    }
                    val command = requireNotNull(directSubmission)
                    directEntered.countDown(); check(directGate?.await(15, TimeUnit.SECONDS) != false)
                    if (!directReceiptReady) throw IOException()
                    if (request.url.encodedPath.endsWith("/recover")) assertEquals(command.recovery(false), body)
                    buildJsonObject { put("receipt", buildJsonObject { put("_0", buildJsonObject {
                        put("identity", command.identity()); put("fingerprint", command.fingerprintPayload()); put("resolvedAtMilliseconds", System.currentTimeMillis())
                        put("outcome", buildJsonObject { put("opened", buildJsonObject {
                            put("roomID", buildJsonObject { put("rawValue", directRoom.value) }); put("createdAtMilliseconds", 1000)
                        }) })
                    }) }) }.toString()
                }
                "/v2/profile-presentations/batch" -> {
                    profileEntered.countDown()
                    check(profileGate?.await(10, TimeUnit.SECONDS) != false)
                    throw IOException()
                }
                else -> "{}"
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status).message("fixture")
                .body(response.toResponseBody("application/json".toMediaType())).build()
        }.build()
        init { context.getSharedPreferences("$name-prefs", 0).edit().putString("url", endpoint).commit() }
        fun recovery(url: String = endpoint) = KeystoreIssuedCredentialRecovery(context, credentialRecoveryNamespace(name, url))
        fun receiptFile() = File(context.noBackupFilesDir, "credential-receipts-${hash(credentialRecoveryNamespace(name, endpoint))}.enc")
        fun seed(owned: Boolean): CredentialRevocationIntent = runBlocking {
            if (owned) secrets.write(buildJsonObject { put("credentials", Json.encodeToJsonElement(credentials)) }.toString())
            recovery().receipts.receive(credentials, UUID.randomUUID().toString().uppercase())
        }
        fun seedLocalDisplay() = runBlocking {
            val peer = UserId(UUID.randomUUID().toString()); val key = ProfileKey(peer, ProfileContext.Relationship)
            val profile = ProfileReadResult.Available(AuthorizedProfile(ProfileView(peer,
                PublicIdentity(peer, PublicHandle("friend"), "待清理姓名", AccountKind.Regular), null, ProfileState.Active, 1, 1),
                ProfileLease(user, credentials.deviceId, key, 1, 1, 0, ProfileAuthority(1, null, 0, 0), 0, 60_000)), System.nanoTime() + 60_000_000_000)
            LocalStoreBootstrapper(context).open(user, credentials.deviceId).use {
                assertTrue(it.saveLocalProfileDisplays(persistentListOf(profile), it.profileFences(persistentListOf(key))))
            }
            displayDatabase { it.execSQL("CREATE TABLE cleanup_sentinel(value TEXT NOT NULL)"); it.execSQL("INSERT INTO cleanup_sentinel VALUES('保留业务记录')") }
            key
        }
        fun <T> displayDatabase(body: (android.database.sqlite.SQLiteDatabase) -> T): T {
            val file = File(context.noBackupFilesDir, "im-${hash("${user.value}/${credentials.deviceId.value}")}.db")
            return android.database.sqlite.SQLiteDatabase.openDatabase(file.path, null, android.database.sqlite.SQLiteDatabase.OPEN_READWRITE).use(body)
        }
        fun displayCount(): Long = displayDatabase { db -> db.rawQuery("SELECT COUNT(*) FROM local_profile_displays", null).use { it.moveToFirst(); it.getLong(0) } }
        fun start(inForeground: Boolean = false) {
            compose.runOnIdle {
                displayed = AppViewModel(context.applicationContext as Application, AppDependencies(credentialsName = name, preferencesName = "$name-prefs",
                    account = { AccountClient(it, http) }, credentialStore = { _, _ -> object : SecretStore by secrets {
                        override suspend fun write(value: String) {
                            if (failAuthWrite && Json.parseToJsonElement(value).jsonObject["credentials"] != null) throw IOException()
                            secrets.write(value)
                        }
                        override suspend fun delete() { if (failAuthDelete) throw IOException(); secrets.delete() }
                    } }))
                owners.put("issued", model)
                if (inForeground) model.foreground(true)
            }
            compose.waitUntil(15_000) { model.state.value.session != SessionUi.Loading }
        }
        fun stop() {
            val old = displayed ?: return
            compose.runOnIdle { displayed = null; owners.clear() }
            runBlocking { withTimeout(15_000) { old.awaitShutdown() } }
        }
        fun close() {
            revokeGate?.countDown(); cancellationGate?.countDown(); profileGate?.countDown(); directGate?.countDown(); stop(); runBlocking { secrets.delete() }
            context.getSharedPreferences("$name-prefs", 0).edit().clear().commit()
            val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            keys.deleteEntry("com.xmtx.im.$name.v1")
            for (url in listOf(endpoint, otherEndpoint)) for (kind in listOf("receipts", "revocations", "registrations")) {
                val journal = "credential-$kind-${hash(credentialRecoveryNamespace(name, url))}"
                for (suffix in listOf("", ".bak", ".new")) File(context.noBackupFilesDir, "$journal.enc$suffix").delete()
                keys.deleteEntry("com.xmtx.im.$journal.v1")
            }
            for (suffix in listOf("", ".bak", ".new")) File(context.noBackupFilesDir, "local-exit-${hash(name)}.json$suffix").delete()
            allCredentials.forEach { c ->
                val scope = hash("${c.userId.value}/${c.deviceId.value}")
                android.database.sqlite.SQLiteDatabase.deleteDatabase(File(context.noBackupFilesDir, "im-$scope.db"))
                File(context.noBackupFilesDir, "resources-$scope").deleteRecursively()
            }
            http.connectionPool.evictAll(); http.dispatcher.executorService.shutdown()
        }
    }
    private fun fixture(body: Fixture.() -> Unit) {
        val f = Fixture()
        try {
            compose.activityRule.scenario.onActivity {
                it.enableEdgeToEdge()
            }
            compose.setContent { f.displayed?.let { model -> val state by model.state.collectAsState(); MaterialTheme { IMApp(state, model) } } }
            f.body()
        } finally { f.close() }
    }

    @Test fun localChatSavesWhileCreationHttpIsStalledAndMovesDraftOnlyAfterMessageHandoff() = fixture {
        seed(true); directGate = CountDownLatch(1); directReceiptReady = true; start(inForeground = true)
        val selected = PublicIdentity(UserId(UUID.randomUUID().toString()), PublicHandle("offline_friend"), "本地聊天朋友", AccountKind.Regular)
        val destination = runBlocking { withContext(Dispatchers.Main.immediate) {
            withTimeout(1000) { model.openLocalDirect(selected.user, identity = selected) }
        } } as DirectConversationDestination.Pending
        compose.onNodeWithContentDescription("更多操作").performClick()
        compose.onNodeWithText("发起聊天").performClick()
        compose.onNodeWithText("打开聊天").performClick()
        compose.onNodeWithTag("local-direct-chat").assertIsDisplayed()
        assertTrue(directEntered.await(8, TimeUnit.SECONDS))
        compose.onNodeWithTag("local-direct-draft").performTextInput("网络等待中的消息")
        compose.onNodeWithTag("local-direct-send").performClick()
        compose.waitUntil(10_000) { model.state.value.snapshot.localDirectMessages.size == 1 }
        val saved = model.state.value.snapshot.localDirectMessages.single()
        assertEquals(destination.operation, saved.operation)
        compose.onNodeWithText("等待会话连接后发送").performScrollTo()
        compose.waitUntil(5_000) { compose.onNodeWithText("等待会话连接后发送").isDisplayed() }
        compose.onNodeWithText("等待会话连接后发送").assertIsDisplayed()
        compose.onNodeWithTag("local-direct-draft").performTextInput("留给正式聊天的输入")
        directGate!!.countDown()
        compose.waitUntil(15_000) { model.state.value.snapshot.localDirectMessages.isEmpty() && model.state.value.snapshot.sendIntents.any { it.intent.id == saved.id } }
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("local-direct-chat").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithContentDescription("聊天设置").assertIsDisplayed()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("留给正式聊天的输入").fetchSemanticsNodes().isNotEmpty() }
        assertEquals(saved.id, model.state.value.snapshot.sendIntents.single().intent.operation)
        assertEquals(saved.createdAt, model.state.value.snapshot.sendIntents.single().intent.createdAt)
        compose.onNodeWithContentDescription("返回").performClick()
        compose.onNodeWithText("通过公开标识查找朋友").assertIsDisplayed()
        compose.onNodeWithContentDescription("返回").performClick()
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
    }
    @Test fun selectedDirectIdentitySurvivesOwnerRestartAndUncertainCreationRecovery() = fixture {
        seed(true); start()
        val selected = PublicIdentity(UserId(UUID.randomUUID().toString()), PublicHandle("selected_friend"), "创建时的对方", AccountKind.CustomerSupport)
        runBlocking { withContext(Dispatchers.Main.immediate) { assertNull(model.openDirect(selected.user, identity = selected)) } }
        val pending = model.state.value.snapshot.directOperations.single()
        assertEquals(selected, pending.publicIdentity); assertEquals(true, pending.executionStarted)
        assertEquals(pending.command, directSubmission)
        stop(); start(); assertEquals(selected, model.state.value.snapshot.directOperations.single().publicIdentity)
        directReceiptReady = true
        runBlocking {
            delay((pending.nextAttemptMilliseconds - System.currentTimeMillis()).coerceAtLeast(0))
            withContext(Dispatchers.Main.immediate) { model.retryDirect(pending.command.operation) }
        }
        assertEquals(DirectWorkStatus.Opened, model.state.value.snapshot.directOperations.single().status)
        assertEquals(selected.user, model.state.value.snapshot.conversations.single().peer)
        assertEquals("会话", model.state.value.snapshot.conversations.single().title)
        assertEquals(1000L, model.state.value.snapshot.conversations.single().updatedAt)
        stop(); start()
        assertEquals(selected, model.state.value.snapshot.directOperations.single().publicIdentity)
        assertEquals(directRoom, model.state.value.snapshot.conversations.single().id)
        assertEquals(1, requests.count { it.url.encodedPath == "/v2/direct-room-operations/submit" })
        assertEquals(1, requests.count { it.url.encodedPath == "/v2/direct-room-operations/operations/recover" })
        assertEquals(0L, displayCount())
    }
    @Test fun ordinaryColdStartupAndTabReentryUseLocalNameWhileProfileHttpIsStalled() = fixture {
        seed(true); val key = seedLocalDisplay(); val room = RoomId(UUID.randomUUID().toString())
        runBlocking {
            LocalStoreBootstrapper(context).open(user, credentials.deviceId).use { store ->
                val payload = buildJsonObject {
                    put("room_id", room.value); put("target_user_id", key.user.value); put("display_name", "不可显示的发现姓名")
                    put("public_handle", "friend"); put("account_kind", "regular"); put("revision", 1); put("updated_at_ms", 1); put("room_created_at_ms", 1)
                }
                val cursor = store.cursor()
                store.commit(SyncBatch.newBuilder().setGeneration(cursor.generation.coerceAtLeast(1)).setNextSyncToken("local")
                    .addRecords(SyncRecord.newBuilder().setSourceEventId(UUID.randomUUID().toString()).setProjectionKind("direct_room_profile")
                        .setUserSyncSequence(cursor.sequence + 1).setPayload(ByteString.copyFromUtf8(payload.toString()))).build(), cursor)
            }
        }
        profileGate = CountDownLatch(1); start(inForeground = true)
        compose.waitUntil(10_000) { compose.onAllNodesWithText("待清理姓名").fetchSemanticsNodes().isNotEmpty() }
        assertTrue(profileEntered.await(5, TimeUnit.SECONDS))
        compose.onNodeWithText("待清理姓名").assertIsDisplayed()
        compose.onNodeWithText("不可显示的发现姓名").assertDoesNotExist()
        compose.onNodeWithTag("root-tab-Contacts").performClick()
        compose.onNodeWithText("待清理姓名").assertDoesNotExist()
        compose.onNodeWithTag("root-tab-Messages").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("待清理姓名").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("待清理姓名").assertIsDisplayed()
    }
    @Test fun startupAdoptsTheDurableSessionBeforeStartingIndependentCleanup() = fixture {
        seed(true); val original = runBlocking { secrets.read() }; start()
        assertTrue(model.state.value.session is SessionUi.SignedIn)
        assertEquals(original, runBlocking { secrets.read() }); assertFalse(runBlocking { recovery().receipts.hasPendingReceipts() })
        assertTrue(requests.isEmpty()); compose.onNodeWithTag("credential-recovery").assertDoesNotExist()
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
    }
    @Test fun unclaimedSessionPausesAndExplicitRetryUsesTheOriginalAuthorityWhileSignedOut() = fixture {
        val receipt = seed(false); start()
        compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Paused }
        assertEquals(SessionUi.SignedOut, model.state.value.session); assertNull(runBlocking { secrets.read() })
        compose.onNodeWithTag("credential-recovery-retry").assertIsDisplayed()
        assertEquals(listOf(receipt.operation), revokeOperations.toList())
        revokeStatus = 204; compose.onNodeWithTag("credential-recovery-retry").performClick()
        compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Empty && model.state.value.session == SessionUi.SignedOut }
        assertEquals(listOf(receipt.operation, receipt.operation), revokeOperations.toList())
        assertTrue(runBlocking { recovery().revocations.jobs().isEmpty() }); assertFalse(runBlocking { marker.isPending() })
    }
    @Test fun unreadableReceiptBlocksRegistrationAndPreservesTheOriginalServerUntilRetry() = fixture {
        seed(false); val valid = receiptFile().readBytes(); val damaged = byteArrayOf(1, 2); receiptFile().writeBytes(damaged)
        start(); compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Unavailable }
        compose.runOnIdle { model.login("account", "password123456", false, "", "", otherEndpoint) }
        assertEquals(SessionUi.SignedOut, model.state.value.session); assertTrue(requests.isEmpty())
        assertEquals(endpoint, context.getSharedPreferences("$name-prefs", 0).getString("url", null)); assertArrayEquals(damaged, receiptFile().readBytes())
        receiptFile().writeBytes(valid); revokeStatus = 204; compose.onNodeWithTag("credential-recovery-retry").performClick()
        compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Empty && model.state.value.session == SessionUi.SignedOut }
        assertEquals(1, revokeOperations.size); assertNull(runBlocking { secrets.read() })
    }
    @Test fun clearingTheViewModelDrainsTheActualCallbackAndTheNextOwnerResumesTheSameJob() = fixture {
        val receipt = seed(false); revokeGate = CountDownLatch(1); start()
        assertTrue(revokeEntered.await(5, TimeUnit.SECONDS)); val old = model
        compose.runOnIdle { displayed = null; owners.clear() }
        runBlocking { assertNull(withTimeoutOrNull(100) { old.awaitShutdown(); true }) }
        revokeGate!!.countDown(); runBlocking { withTimeout(15_000) { old.awaitShutdown() } }
        assertEquals(0L, runBlocking { recovery().revocations.jobs().single().attempts })
        revokeStatus = 204; start(); compose.waitUntil(15_000) { revokeOperations.size == 2 && model.credentialRecovery.value == CredentialRecoveryUi.Empty }
        assertEquals(listOf(receipt.operation, receipt.operation), revokeOperations.toList())
    }
    @Test fun endpointSwitchWaitsForOldCleanupThenProductionLoginUsesTheNewNamespace() = fixture {
        seed(false); start(); compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Paused }
        compose.runOnIdle { model.login("account", "password123456", false, "", "", otherEndpoint) }
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && model.state.value.error != null }
        assertEquals(endpoint, context.getSharedPreferences("$name-prefs", 0).getString("url", null))
        assertTrue(requests.none { it.url.host == "replacement.fixture.invalid" })
        revokeStatus = 204; compose.onNodeWithTag("credential-recovery-retry").performClick()
        compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Empty && model.state.value.session == SessionUi.SignedOut }
        compose.runOnIdle { model.login("account", "password123456", false, "", "", otherEndpoint) }
        compose.waitUntil(15_000) { model.state.value.session is SessionUi.SignedIn }
        assertEquals(otherEndpoint, context.getSharedPreferences("$name-prefs", 0).getString("url", null))
        assertFalse(runBlocking { recovery(otherEndpoint).receipts.hasPendingReceipts() })
        assertTrue(runBlocking { recovery(otherEndpoint).revocations.jobs().isEmpty() })
        stop(); start(); assertTrue(model.state.value.session is SessionUi.SignedIn)
        assertEquals(1, requests.count { it.url.encodedPath == "/v2/device-credentials" })
    }
    @Test fun failedProductionAuthSaveRecoversIntoCleanupWithoutReissuingCredentials() = fixture {
        start(); failAuthWrite = true
        compose.runOnIdle { model.login("account", "password123456", false, "", "", endpoint) }
        compose.waitUntil(15_000) { model.state.value.session is SessionUi.CredentialsUnavailable }
        assertTrue(runBlocking { recovery().receipts.hasPendingReceipts() })
        failAuthWrite = false; revokeStatus = 204; compose.onNodeWithTag("credentials-retry").performClick()
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && !model.state.value.cleanupPending && model.credentialRecovery.value == CredentialRecoveryUi.Empty }
        assertNull(runBlocking { secrets.read() }); assertFalse(runBlocking { marker.isPending() })
        assertEquals(1, requests.count { it.url.encodedPath == "/v2/device-credentials" })
        assertEquals(1, requests.count { it.url.encodedPath.endsWith("cancel-registration") })
    }

    @Test fun interruptedAssertionCanRetryWithTheSameIdentityOrExplicitlyQueueCleanup() = fixture {
        start(); failAssertion = true
        compose.runOnIdle { model.login("account", "password123456", false, "", "", endpoint) }
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && model.credentialRecovery.value == CredentialRecoveryUi.AwaitingRegistration }
        val pending = runBlocking { recovery().registrations.prepare("account").load() }
        compose.onNodeWithTag("credential-recovery-retry").assertIsDisplayed()
        assertTrue(cancellationPayloads.isEmpty())
        failAssertion = false
        compose.runOnIdle { model.login("ACCOUNT", "password123456", false, "", "", endpoint) }
        compose.waitUntil(15_000) { model.state.value.session is SessionUi.SignedIn && model.credentialRecovery.value == CredentialRecoveryUi.Empty }
        assertEquals(pending.device, allCredentials.last().deviceId); assertTrue(cancellationPayloads.isEmpty())
        assertFalse(runBlocking { recovery().registrations.hasWork() })
    }

    @Test fun pendingRegistrationBlocksServerSwitchAndExplicitCleanupSurvivesRestart() = fixture {
        start(); failAssertion = true; cancellationStatus = 409
        compose.runOnIdle { model.login("account", "password123456", false, "", "", endpoint) }
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && model.credentialRecovery.value == CredentialRecoveryUi.AwaitingRegistration }
        val pending = runBlocking { recovery().registrations.prepare("account").load() }
        compose.runOnIdle { model.login("account", "password123456", false, "", "", otherEndpoint) }
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && model.state.value.error != null }
        assertTrue(requests.none { it.url.host == "replacement.fixture.invalid" })
        compose.onNodeWithTag("credential-recovery-retry").performClick()
        compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Paused }
        assertEquals(listOf(pending.payload()), cancellationPayloads.toList())
        stop(); start(); compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Paused }
        assertEquals(1, cancellationPayloads.size); cancellationStatus = 410
        compose.onNodeWithTag("credential-recovery-retry").performClick()
        compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Empty }
        assertEquals(listOf(pending.payload(), pending.payload()), cancellationPayloads.toList())
        assertNull(runBlocking { secrets.read() }); assertFalse(runBlocking { marker.isPending() })
    }

    @Test fun coldPendingRegistrationIsCanceledAndOwnerShutdownDrainsItsHttpCallback() = fixture {
        val pending = runBlocking { recovery().registrations.prepare("account").load() }
        cancellationGate = CountDownLatch(1); start(); assertTrue(cancellationEntered.await(5, TimeUnit.SECONDS))
        val old = model; compose.runOnIdle { displayed = null; owners.clear() }
        runBlocking { assertNull(withTimeoutOrNull(100) { old.awaitShutdown(); true }) }
        cancellationGate!!.countDown(); runBlocking { withTimeout(15_000) { old.awaitShutdown() } }
        assertEquals(0L, runBlocking { recovery().registrations.jobs().single().attempts })
        start(); compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Empty && cancellationPayloads.size == 2 }
        assertEquals(listOf(pending.payload(), pending.payload()), cancellationPayloads.toList())
        assertEquals(SessionUi.SignedOut, model.state.value.session)
    }

    @Test fun oldCleanupRemainsVisibleAfterNewLoginAndDoesNotRetireTheNewAccount() = fixture {
        val old = seed(false); start(); compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Paused }
        compose.runOnIdle { model.login("account", "password123456", false, "", "", endpoint) }
        compose.waitUntil(15_000) { model.state.value.session is SessionUi.SignedIn }
        val active = model.state.value.session
        assertEquals(CredentialRecoveryUi.Paused, model.credentialRecovery.value)
        assertNotEquals(old.device, allCredentials.last().deviceId)
        compose.onNodeWithTag("credential-recovery-retry").assertIsDisplayed()
        compose.onNodeWithTag("root-tab-Messages").assertIsSelected()
        revokeStatus = 204; compose.onNodeWithTag("credential-recovery-retry").performClick()
        compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Empty }
        assertEquals(active, model.state.value.session); assertFalse(runBlocking { marker.isPending() })
        assertEquals(listOf(old.operation, old.operation), revokeOperations.toList())
        assertTrue(runBlocking { recovery().revocations.jobs().isEmpty() })
    }

    @Test fun ordinaryLogoutCompletesLocallyWhileRevocationCallbackIsStillWaiting() = fixture {
        seed(true); start(); revokeGate = CountDownLatch(1)
        compose.runOnIdle { model.signOut() }
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && !model.state.value.cleanupPending }
        assertTrue(revokeEntered.await(5, TimeUnit.SECONDS)); assertNull(runBlocking { secrets.read() }); assertFalse(runBlocking { marker.isPending() })
        val old = runBlocking { recovery().revocations.jobs().single().intent }; assertEquals(credentials.deviceId, old.device)
        revokeGate!!.countDown(); compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Paused }
        stop(); start(); compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Paused }
        assertEquals(listOf(old.operation), revokeOperations.toList())
        compose.runOnIdle { model.login("account", "password123456", false, "", "", endpoint) }
        compose.waitUntil(15_000) { model.state.value.session is SessionUi.SignedIn }; val newSession = model.state.value.session
        revokeStatus = 204; compose.onNodeWithTag("credential-recovery-retry").performClick()
        compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Empty }
        assertEquals(newSession, model.state.value.session); assertEquals(listOf(old.operation, old.operation), revokeOperations.toList())
    }

    @Test fun ownerRecreationRetainsLocalNamesButOrdinaryLogoutClearsThem() = fixture {
        seed(true); start()
        val peer = UserId(UUID.randomUUID().toString()); val key = ProfileKey(peer, ProfileContext.Relationship)
        val keys = persistentListOf(key); val bootstrap = LocalStoreBootstrapper(context)
        val profile = ProfileReadResult.Available(AuthorizedProfile(ProfileView(peer,
            PublicIdentity(peer, PublicHandle("friend"), "本地授权姓名", AccountKind.Regular), null, ProfileState.Active, 1, 1),
            ProfileLease(user, credentials.deviceId, key, 1, 1, 0, ProfileAuthority(1, null, 0, 0), 0, 60_000)), System.nanoTime() + 60_000_000_000)
        runBlocking { bootstrap.open(user, credentials.deviceId).use { assertTrue(it.saveLocalProfileDisplays(persistentListOf(profile), it.profileFences(keys))) } }
        stop()
        assertEquals("本地授权姓名", runBlocking { bootstrap.open(user, credentials.deviceId).use { it.cachedLocalProfileDisplays(keys).value(key)?.name } })
        start(); compose.runOnIdle { model.signOut() }
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && !model.state.value.cleanupPending }
        assertNull(runBlocking { bootstrap.open(user, credentials.deviceId).use { it.cachedLocalProfileDisplays(keys).value(key) } })
    }

    @Test fun coldPendingExitClearsNamesWithoutOpeningOrMigratingTheAccount() = fixture {
        seed(true); seedLocalDisplay()
        displayDatabase { it.execSQL("DROP TABLE account_room_heads") }
        runBlocking { marker.markPending() }; val original = runBlocking { secrets.read() }
        start()
        assertEquals(SessionUi.SignedOut, model.state.value.session); assertTrue(model.state.value.cleanupPending)
        assertEquals(0L, displayCount()); assertEquals(original, runBlocking { secrets.read() }); assertTrue(runBlocking { marker.isPending() })
        compose.onNodeWithTag("root-tab-Messages").assertDoesNotExist()
        displayDatabase { db ->
            db.rawQuery("SELECT 1 FROM sqlite_master WHERE name='account_room_heads'", null).use { assertFalse(it.moveToFirst()) }
            db.rawQuery("SELECT value FROM cleanup_sentinel", null).use { it.moveToFirst(); assertEquals("保留业务记录", it.getString(0)) }
        }
        stop(); start(); assertEquals(0L, displayCount()); assertTrue(model.state.value.cleanupPending)
        assertTrue(requests.none { it.url.encodedPath == "/v2/profile-presentations/batch" })
    }

    @Test fun coldCacheDeleteFailureKeepsCredentialsAndRetryClearsOnlyTheCache() = fixture {
        val received = seed(true)
        // A fully established session has settled its issuance receipt. An awaiting receipt is
        // independently eligible for cold recovery and is not gated by this cache-delete failure.
        runBlocking { recovery().receipts.adopt(received) }; seedLocalDisplay()
        displayDatabase { it.execSQL("CREATE TRIGGER reject_display_delete BEFORE DELETE ON local_profile_displays WHEN OLD.key LIKE 'basic|%' BEGIN SELECT RAISE(IGNORE); END") }
        runBlocking { marker.markPending() }; start()
        assertEquals(2L, displayCount()); assertTrue(model.state.value.cleanupPending)
        compose.runOnIdle { model.signOut() }
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && model.state.value.cleanupPending }
        assertEquals(2L, displayCount()); assertNotNull(runBlocking { secrets.read() }); assertTrue(runBlocking { marker.isPending() })
        assertTrue(revokeOperations.isEmpty())
        displayDatabase { it.execSQL("DROP TRIGGER reject_display_delete") }
        compose.runOnIdle { model.signOut() }
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && !model.state.value.cleanupPending }
        assertEquals(0L, displayCount()); assertNull(runBlocking { secrets.read() }); assertFalse(runBlocking { marker.isPending() })
        displayDatabase { db -> db.rawQuery("SELECT value FROM cleanup_sentinel", null).use { it.moveToFirst(); assertEquals("保留业务记录", it.getString(0)) } }
    }

    @Test fun offlineOrdinaryLogoutSurvivesRecreationAndEventuallyConfirmsTheOriginalOperation() = fixture {
        seed(true); start(); revokeOffline = true
        compose.runOnIdle { model.signOut() }
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && !model.state.value.cleanupPending && model.credentialRecovery.value == CredentialRecoveryUi.Pending }
        compose.waitUntil(15_000) { revokeOperations.isNotEmpty() }
        stop(); val pending = runBlocking { recovery().revocations.jobs().single() }
        assertEquals(credentials.deviceId, pending.intent.device); assertNull(runBlocking { secrets.read() }); assertFalse(runBlocking { marker.isPending() })
        revokeOffline = false; revokeStatus = 204; start()
        compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Empty }
        assertEquals(SessionUi.SignedOut, model.state.value.session); assertFalse(model.state.value.cleanupPending)
        assertTrue(revokeOperations.size >= 2); assertTrue(revokeOperations.all { it == pending.intent.operation })
    }

    @Test fun failedLocalDeletionRetainsPausedQueueAndRestartRetryOnlyFinishesTheLocalExit() = fixture {
        seed(true); start(); failAuthDelete = true
        compose.runOnIdle { model.signOut() }
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && model.state.value.cleanupPending && model.credentialRecovery.value == CredentialRecoveryUi.Paused }
        val queued = runBlocking { recovery().revocations.jobs().single() }; assertNotNull(runBlocking { secrets.read() }); assertTrue(runBlocking { marker.isPending() })
        stop(); start(); assertTrue(model.state.value.cleanupPending); failAuthDelete = false
        compose.onNodeWithText("重试完成退出登录").performScrollTo().performClick()
        compose.waitUntil(15_000) { model.state.value.session == SessionUi.SignedOut && !model.state.value.cleanupPending }
        assertNull(runBlocking { secrets.read() }); assertFalse(runBlocking { marker.isPending() })
        assertEquals(queued, runBlocking { recovery().revocations.jobs().single() }); assertEquals(listOf(queued.intent.operation), revokeOperations.toList())
        revokeStatus = 204; compose.onNodeWithTag("credential-recovery-retry").performClick()
        compose.waitUntil(15_000) { model.credentialRecovery.value == CredentialRecoveryUi.Empty }
    }
}
