package com.xmtx.im

import android.app.Application
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import java.net.URI
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.UUID
import javax.net.ssl.*

/** Opt-in real UI/model/runtime test. No demo state, reflection, fake login, or seeded message projection. */
@OptIn(ExperimentalTestApi::class,ExperimentalCoroutinesApi::class)
class AppBackendUiTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>(effectContext=kotlinx.coroutines.test.StandardTestDispatcher())
    @Test fun loginDiscoveryChatReplyNavigationAndAccountReopenUseRealBackend() {
        val args=InstrumentationRegistry.getArguments();val endpoint=args.getString("e2eURL")
        assumeTrue("Requires explicit isolated backend",endpoint!=null)
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val certificate=CertificateFactory.getInstance("X.509").generateCertificate(Base64.getDecoder().decode(requireNotNull(args.getString("e2eCA"))).inputStream())
        val keys=KeyStore.getInstance(KeyStore.getDefaultType()).apply {load(null);setCertificateEntry("test",certificate)}
        val managers=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {init(keys)}
        val ssl=SSLContext.getInstance("TLS").apply {init(null,managers.trustManagers,null)}
        val importResponses=java.util.concurrent.CopyOnWriteArrayList<String>()
        val http=OkHttpClient.Builder().addInterceptor { chain ->
            val importing=chain.request().url.encodedPath.startsWith("/v2/resource-imports")
            if(importing) importResponses.add("${chain.request().url.encodedPath}: started")
            val response=try {chain.proceed(chain.request())} catch(error: Exception) {
                if(importing) importResponses.add("${chain.request().url.encodedPath}: ${error::class.simpleName}")
                throw error
            }
            if(importing) {
                val code=runCatching {org.json.JSONObject(response.peekBody(65536).string()).optString("code")}.getOrDefault("")
                importResponses.add("${chain.request().url.encodedPath}: ${response.code} ${code.take(80)}")
            }
            response
        }.sslSocketFactory(ssl.socketFactory,managers.trustManagers.single() as X509TrustManager).build()
        val port=requireNotNull(args.getString("e2eTLSPort")).toInt();val run=UUID.randomUUID().toString().replace("-","").take(12)
        val account="ui_${run}_a";val peerHandle="ui_${run}_b";val password=UUID.randomUUID().toString()+"aA1!"
        val api=AccountClient(endpoint!!,http)
        val seed=AuthSession(KeystoreSecretStore(context,"ui-$run-seed"),api)
        val peer=AuthSession(KeystoreSecretStore(context,"ui-$run-peer"),api)
        val peerSocket=RealtimeConnection("localhost",port,ssl.socketFactory)
        val appSockets=java.util.concurrent.CopyOnWriteArrayList<RealtimeConnection>()
        val networkOwners=java.util.concurrent.CopyOnWriteArrayList<AccountNetworkActivity>()
        val dependencies=AppDependencies(account={AccountClient(it,http)},networkActivity={AccountNetworkActivity().also(networkOwners::add)},realtime={RealtimeConnection(URI(it).host,port,ssl.socketFactory,authorPresentations=true).also(appSockets::add)},preferencesName="ui-$run-endpoint",credentialsName="ui-$run-credentials",download=MediaFileDownloader(http)::download)
        var model: AppViewModel?=null;var models=ViewModelStore();var peerStore: SqliteClientStore?=null
        var displayed by mutableStateOf<AppViewModel?>(null)
        var primaryFailure: Throwable?=null
        var phase = "register fixtures"
        fun mark(value: String) {phase=value;android.util.Log.i("AppBackendPhase",value)}
        fun waitFor(predicate: ()->Boolean)=compose.waitUntil(45000,predicate)
        fun awaitOwnerShutdown(owner:AppViewModel) {
            // Cleanup can drain tasks launched from Compose's test effect dispatcher.
            // Keep advancing that dispatcher while waiting for actual account I/O to close.
            val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
            val waiting=scope.async {owner.awaitShutdown()}
            try {compose.waitUntil(15000) {waiting.isCompleted};runBlocking {
                waiting.await()
                networkOwners.lastOrNull()?.scheduler?.snapshot()?.let {assertTrue(it.closed);assertEquals(0,it.active);assertEquals(0,it.waiting)}
            }}
            finally {waiting.cancel();scope.cancel()}
        }
        fun requirePeerPresentation() {
            val author=hasText("界面测试 B") and hasAnyAncestor(hasTestTag("chat-timeline"))
            waitFor {runCatching {compose.onNode(author).assertIsDisplayed();true}.getOrDefault(false)}
            compose.onNode(author).assertIsDisplayed()
            compose.onNode(hasText("资料暂不可用") and hasAnyAncestor(hasTestTag("chat-timeline"))).assertDoesNotExist()
        }
        try {
            val users=runBlocking {
                val a=seed.login(account,password,true,account,"界面测试 A")
                val b=peer.login(peerHandle,password,true,peerHandle,"界面测试 B")
                peerSocket.connect(peer.access());peerStore=openBoundFixtureStore(context,b.userId,b.deviceId)
                seed.logout();a to b
            }
            val invitation = runBlocking {
                prepareInvitationEntryFixture(context, endpoint, users.second, requireNotNull(peerStore),
                    AuthenticatedApi(peer,api,users.second.userId,users.second.deviceId), run)
            }
            compose.runOnUiThread {model=AppViewModel(context.applicationContext as Application,dependencies);models.put("app",model!!);displayed=model}
            compose.runOnUiThread { model!!.invitationInbox.offer(invitationURL(invitation.secret)) }
            val restoration=StateRestorationTester(compose)
            var keyboard: androidx.compose.ui.platform.SoftwareKeyboardController?=null
            restoration.setContent {keyboard=androidx.compose.ui.platform.LocalSoftwareKeyboardController.current;displayed?.let {ApplicationContent(it)}}
            fun hideKeyboard() {compose.runOnIdle {keyboard?.hide()};compose.waitForIdle()}
            fun loginScroll(matcher: SemanticsMatcher) {compose.onNodeWithTag("login-form").performScrollToNode(matcher)}
            mark("login through visible form")
            waitFor {model!!.state.value.session==SessionUi.SignedOut}
            compose.onNodeWithText("账号").performScrollTo().performTextInput(account)
            compose.onNodeWithText("密码").performScrollTo().performTextInput(password)
            hideKeyboard();loginScroll(hasText("服务连接设置"));compose.onNodeWithText("服务连接设置").performClick()
            loginScroll(hasText("HTTPS 服务地址"));compose.onNodeWithText("HTTPS 服务地址").performTextReplacement(endpoint)
            hideKeyboard();loginScroll(hasTestTag("login-submit"));compose.onNodeWithTag("login-submit").performClick()
            waitFor {model!!.state.value.session is SessionUi.SignedIn}
            assertEquals(users.first.userId,(model!!.state.value.session as SessionUi.SignedIn).user)
            assertFalse((model!!.state.value.session as SessionUi.SignedIn).demo)
            mark("login handoff and invitation preview without automatic submission")
            verifyInvitationEntryUi(compose, requireNotNull(model), invitation,
                InvitationDirectory(AuthenticatedApi(peer,api,users.second.userId,users.second.deviceId)), restoration)
            mark("public identity discovery and real direct room")
            compose.onNodeWithContentDescription("更多操作").performClick();compose.onNodeWithText("发起聊天").performClick()
            compose.onNodeWithText("公开标识，例如 @lin").performTextInput(peerHandle)
            hideKeyboard();compose.onNodeWithText("查找").performClick()
            waitFor {compose.onAllNodesWithText("发消息").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("发消息").performScrollTo().performClick()
            waitFor {model!!.state.value.snapshot.directOperations.any {it.status==DirectWorkStatus.Opened}}
            waitFor {compose.onAllNodesWithTag("persistent-message-draft").fetchSemanticsNodes().isNotEmpty() || compose.onAllNodesWithText("打开").fetchSemanticsNodes().isNotEmpty()}
            if(compose.onAllNodesWithTag("persistent-message-draft").fetchSemanticsNodes().isEmpty()) {
                // Automatic navigation may remove the fallback button between lookup and click.
                // The actual editor and subsequent send assertions remain mandatory below.
                runCatching {compose.onNodeWithText("打开").performScrollTo().performClick()}
            }
            val room=model!!.state.value.snapshot.directOperations.single().room!!
            waitFor {model!!.state.value.chatComposer?.let {it.room==room && it.available && it.draft!=null && !it.loading}==true}
            compose.onNodeWithText("我的",useUnmergedTree=true).assertDoesNotExist()
            mark("compose send and peer SQLite projection")
            val text="UI 发出 $run";val reply="真实对端回复 $run";val draft="恢复草稿 $run"
            compose.onNodeWithTag("persistent-message-draft").performTextInput(text)
            compose.onNodeWithContentDescription("发送").performClick();hideKeyboard()
            runBlocking {withTimeout(45000) {
                while(true) {
                    SyncEngine(peerSocket,peerStore!!).synchronize();RoomSyncEngine(peerSocket,peerStore!!).synchronize()
                    if(peerStore!!.snapshot().messages.any {it.text==text && it.revision>0}) break
                    delay(500)
                }
                MessageOutbox(peerSocket,peerStore!!).send(users.second.userId,room,reply)
                while(peerStore!!.pending().isNotEmpty()) {delay(500);MessageOutbox(peerSocket,peerStore!!).flush()}
            }}
            waitFor {compose.onAllNodesWithText(reply).fetchSemanticsNodes().isNotEmpty()}
            waitFor {runCatching {compose.onNode(hasText(reply) and hasAnyAncestor(hasTestTag("chat-timeline"))).assertIsDisplayed();true}.getOrDefault(false)}
            compose.onNode(hasText(reply) and hasAnyAncestor(hasTestTag("chat-timeline"))).assertIsDisplayed();assertTrue(model!!.state.value.snapshot.messages.isEmpty())
            mark("visible peer profile after realtime reply")
            requirePeerPresentation()
            if(args.getString("e2eAuthorPresentations")=="true") {
                mark("negotiated author stream and peer rename on visible page")
                assertNotNull(appSockets.last().state.value.authorStream)
                fun rename(name: String)=runBlocking {
                    val client=OwnProfileClient(AuthenticatedApi(peer,api,users.second.userId,users.second.deviceId),users.second.userId)
                    val current=client.current()
                    val result=client.submit(OwnProfileCommand(users.second.userId,UUID.randomUUID().toString().uppercase(),current.revision,OwnProfilePatch(name),System.currentTimeMillis()+86400000))
                    assertEquals(OwnProfileStatus.Committed,result.status)
                }
                rename("实时改名 B")
                waitFor {runCatching {compose.onNode(hasText("实时改名 B") and hasAnyAncestor(hasTestTag("chat-timeline"))).assertIsDisplayed();true}.getOrDefault(false)}
                compose.onNode(hasText("界面测试 B") and hasAnyAncestor(hasTestTag("chat-timeline"))).assertDoesNotExist()
                rename("界面测试 B");requirePeerPresentation()
            }
            mark("shared detail stack and saveable draft restoration")
            compose.onNodeWithTag("persistent-message-draft").performTextInput(draft)
            waitFor {model!!.state.value.chatComposer?.let {it.text==draft && !it.saving}==true}
            hideKeyboard();compose.onNodeWithContentDescription("聊天设置").performClick()
            restoration.emulateSavedInstanceStateRestore()
            compose.onNodeWithText("会话整理").assertExists();compose.onNodeWithText("我的",useUnmergedTree=true).assertDoesNotExist()
            compose.onNodeWithContentDescription("返回").performClick()
            waitFor {model!!.state.value.chatComposer?.text==draft}
            compose.onNodeWithTag("persistent-message-draft").assertTextContains(draft)
            mark("new account owner restores Keystore session and SQLite draft")
            val previous=model!!
            compose.runOnIdle {displayed=null};compose.waitForIdle();compose.runOnUiThread {models.clear()}
            awaitOwnerShutdown(previous)
            compose.waitForIdle()
            compose.runOnUiThread {models=ViewModelStore();model=AppViewModel(context.applicationContext as Application,dependencies);models.put("app",model!!);displayed=model}
            waitFor {model!!.state.value.session is SessionUi.SignedIn && model!!.state.value.snapshot.conversations.any {it.id==room}}
            assertEquals(users.first.userId,(model!!.state.value.session as SessionUi.SignedIn).user)
            compose.onNodeWithTag("conversation-list").performScrollToNode(hasText(reply))
            compose.onNodeWithText(reply).performClick()
            waitFor {model!!.state.value.chatComposer?.text==draft}
            compose.onNodeWithTag("persistent-message-draft").assertTextContains(draft)
            waitFor {runCatching {compose.onNode(hasText(reply) and hasAnyAncestor(hasTestTag("chat-timeline"))).assertIsDisplayed();true}.getOrDefault(false)}
            compose.onNode(hasText(reply) and hasAnyAncestor(hasTestTag("chat-timeline"))).assertIsDisplayed()
            mark("visible peer profile after account owner recreation")
            requirePeerPresentation()
            assertEquals(1,runBlocking {peerStore!!.snapshot().messages.count {it.text==text && it.revision>0}})
            if(args.getString("captureAppBackend")=="true") context.openFileOutput("app-backend-chat.png",0).use {
                compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)
            }
            val beforeBackground=networkOwners.last()
            verifyConversationActivityBackendUi(compose,{requireNotNull(model)},room,users.first.userId,users.second.userId,
                peerSocket,reply,::hideKeyboard,background={compose.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)},
                foreground={compose.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)}) {mark("live activity UI: $it")}
            assertSame(beforeBackground,networkOwners.last());assertFalse(runBlocking {beforeBackground.scheduler.snapshot().closed})
            runBlocking {peerSocket.connect(peer.access())}
            verifyConversationResourceBackendUi(compose,restoration,{requireNotNull(model)},reopen={ latest->
                val previousOwner=requireNotNull(model)
                compose.runOnIdle {displayed=null};compose.waitForIdle();compose.runOnUiThread {models.clear()}
                awaitOwnerShutdown(previousOwner);compose.waitForIdle()
                compose.runOnUiThread {models=ViewModelStore();model=AppViewModel(context.applicationContext as Application,dependencies);models.put("app",model!!);displayed=model}
                waitFor {model!!.state.value.session is SessionUi.SignedIn && model!!.state.value.snapshot.conversations.any {it.id==room}}
                compose.onNodeWithTag("conversation-list").performScrollToNode(hasText(latest));compose.onNodeWithText(latest).performClick()
                waitFor {model!!.state.value.chatComposer?.let {it.room==room && it.available && !it.loading}==true}
            },hideKeyboard=::hideKeyboard,room=room,actor=users.first.userId,peer=users.second,
                peerApi=AuthenticatedApi(peer,api,users.second.userId,users.second.deviceId),peerStore=requireNotNull(peerStore),peerSocket=peerSocket,http=http,run=run) {mark("chat attachment UI: $it")}
            mark("sign out through UI")
            compose.onNodeWithContentDescription("返回").performClick()
            compose.onNodeWithText("我的",useUnmergedTree=true).performClick()
            compose.onNodeWithTag("account-list").performScrollToNode(hasText("退出登录"));compose.onNodeWithText("退出登录").performClick()
            compose.onNodeWithText("退出",substring=false).performClick()
            waitFor {model!!.state.value.session==SessionUi.SignedOut && !model!!.state.value.cleanupPending}
            val networkStates=runBlocking {networkOwners.map {it.scheduler.snapshot()}}
            assertTrue(networkStates.size>=3);assertEquals(networkOwners.size,networkOwners.map {it.scheduler}.toSet().size)
            assertTrue(networkStates.all {it.closed && it.active==0 && it.waiting==0})
            context.openFileOutput("account-network-backend.json",0).use {output->
                output.write(org.json.JSONObject().put("accountActivations",networkStates.size).put("distinctSchedulers",true)
                    .put("retainedAcrossBackground",true).put("allClosedAndDrained",true).toString().toByteArray())
            }
        } catch(error: Throwable) {
            val state=model?.state?.value
            val imports=state?.snapshot?.resourceImports?.map {"attempts=${it.execution.attempts}, attention=${it.execution.attention}, issue=${it.execution.issue}, owned=${it.execution.owner!=null}"}
            val diagnostic="App backend UI phase: $phase; import responses: $importResponses; UI error: ${state?.error}; imports: $imports"
            android.util.Log.e("AppBackendPhase",diagnostic)
            throw AssertionError(diagnostic,error).also {primaryFailure=it}
        } finally {
            try {
                compose.runOnIdle {displayed=null};compose.waitForIdle();compose.runOnUiThread {models.clear()}
                model?.let(::awaitOwnerShutdown)
            } catch(cleanup: Throwable) {
                val primary=primaryFailure
                if(primary!=null) primary.addSuppressed(cleanup) else throw cleanup
            } finally {peerSocket.close();peerStore?.close();http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()}
        }
    }
}
