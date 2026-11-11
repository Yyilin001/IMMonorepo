package com.xmtx.im

import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import com.google.protobuf.ByteString
import androidx.compose.ui.graphics.toPixelMap
import java.util.concurrent.CopyOnWriteArrayList
import androidx.activity.ComponentActivity
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import org.junit.*
import org.junit.Assert.*
import java.net.URI
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.UUID
import javax.net.ssl.*

/** Real membership-review authority with two accounts and the production Compose/Nav3 page. */
class InvitationReviewBackendTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun applicantPresentationDisappearsAfterWithdrawalAndConfirmedRejection() {
        val args=InstrumentationRegistry.getArguments();val endpoint=args.getString("e2eURL")
        Assume.assumeTrue("Requires isolated backend",endpoint!=null)
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val certificate=CertificateFactory.getInstance("X.509").generateCertificate(Base64.getDecoder().decode(requireNotNull(args.getString("e2eCA"))).inputStream())
        val keys=KeyStore.getInstance(KeyStore.getDefaultType()).apply {load(null);setCertificateEntry("test",certificate)}
        val trust=TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {init(keys)}
        val ssl=SSLContext.getInstance("TLS").apply {init(null,trust.trustManagers,null)}
        val http=OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory,trust.trustManagers.single() as X509TrustManager).build()
        val port=requireNotNull(args.getString("e2eTLSPort")).toInt()
        val run=UUID.randomUUID().toString().replace("-","").take(12)
        val api=AccountClient(endpoint!!,http)
        val owner=AuthSession(KeystoreSecretStore(context,"review-$run-owner"),api)
        val peer=AuthSession(KeystoreSecretStore(context,"review-$run-peer"),api)
        var ownerStore:SqliteClientStore?=null;var peerStore:SqliteClientStore?=null
        var primaryFailure:Throwable?=null;var ownerLoggedOut=false
        val avatarGrants=CopyOnWriteArrayList<AvatarReadGrant>()
        val models=ViewModelStore();var model:AppViewModel?=null;var displayed by mutableStateOf<AppViewModel?>(null)
        fun waitFor(predicate:()->Boolean)=compose.waitUntil(30000,predicate)
        suspend fun settle(service:InvitationService,store:SqliteClientStore,work:InvitationWork) {
            withTimeout(30000) {while(!store.invitationWorks().first {it.intent.key==work.intent.key}.terminal) {service.flush();delay(100)}}
            assertEquals(InvitationStatus.Committed,store.invitationWorks().first {it.intent.key==work.intent.key}.status)
        }
        try {
            val name="入群申请者 $run"
            val users=runBlocking {
                owner.login("review_${run}_a",UUID.randomUUID().toString()+"aA1!",true,"review_${run}_a","邀请管理员") to
                    peer.login("review_${run}_b",UUID.randomUUID().toString()+"aA1!",true,"review_${run}_b",name)
            }
            ownerStore=openBoundFixtureStore(context,users.first.userId,users.first.deviceId)
            peerStore=openBoundFixtureStore(context,users.second.userId,users.second.deviceId)
            val link=runBlocking {prepareInvitationEntryFixture(context,endpoint,users.first,requireNotNull(ownerStore),
                AuthenticatedApi(owner,api,users.first.userId,users.first.deviceId),run)}
            val peerApi=AuthenticatedApi(peer,api,users.second.userId,users.second.deviceId)
            val avatarMedia=runBlocking {uploadReviewAvatar(context,users.second,peerApi,requireNotNull(peerStore),http)}
            val client=InvitationClient(peerApi);val directory=InvitationDirectory(peerApi)
            val service=InvitationService(users.second.userId,client,requireNotNull(peerStore),KeystoreInvitationSecrets(context,endpoint,users.second.userId,users.second.deviceId))
            fun submit()=runBlocking {
                val work=service.enqueue(service.confirmation(link.room,InvitationAction.Submit(link.invite,link.secret.digest,"申请说明")),link.secret)
                settle(service,requireNotNull(peerStore),work)
                requireNotNull(directory.preview(link.secret).request)
            }
            var request=submit()
            ownerStore?.close();ownerStore=null
            assertTrue(context.getSharedPreferences("review-$run-prefs",0).edit().putString("url",endpoint).commit())
            compose.runOnUiThread {
                model=AppViewModel(context.applicationContext as Application,AppDependencies(account={AccountClient(it,http)},
                    realtime={RealtimeConnection(URI(it).host,port,ssl.socketFactory,authorPresentations=true)},
                    preferencesName="review-$run-prefs",credentialsName="review-$run-owner",
                    avatarDownload={grant->avatarGrants.add(grant);AvatarDownloader(http).download(grant)}))
                models.put("app",model!!);displayed=model
            }
            compose.setContent {displayed?.let {ApplicationContent(it)}}
            waitFor {model!!.state.value.snapshot.conversations.any {it.id==link.room}}
            waitFor {compose.onAllNodesWithText(link.title).fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText(link.title).performScrollTo().performClick()
            compose.onNodeWithContentDescription("聊天设置").performClick()
            compose.onNode(SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsActions.ScrollToIndex))
                .performScrollToNode(hasText("邀请与入群申请"))
            compose.onNodeWithText("邀请与入群申请").performClick()
            fun showApplicant() {
                waitFor {runCatching {
                    compose.onNodeWithTag("invitation-page").performScrollToNode(hasTestTag("invite-applicant/$request"))
                }.isSuccess}
                waitFor {compose.onAllNodesWithText(name).fetchSemanticsNodes().isNotEmpty()}
                compose.onNodeWithText(name).assertIsDisplayed()
                compose.onNodeWithText(users.second.userId.value,substring=true).assertDoesNotExist()
                val avatar=hasTestTag("avatar-image") and hasAnyAncestor(hasTestTag("invite-request/$request"))
                waitFor {compose.onAllNodes(avatar,useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()}
                val pixels=compose.onNode(avatar,useUnmergedTree=true).assertIsDisplayed().captureToImage().toPixelMap()
                val center=pixels[pixels.width/2,pixels.height/2]
                assertTrue("Uploaded green avatar must actually render",center.green>0.9f && center.red<0.1f && center.blue<0.1f)
                assertTrue(avatarGrants.any {it.content.media==avatarMedia && it.home==ResourceHome.Account(users.second.userId)})
            }
            fun refresh() {compose.onNodeWithText("刷新",substring=false).performScrollTo().performClick()}
            showApplicant()
            runBlocking {val work=service.enqueue(service.confirmation(link.room,InvitationAction.Cancel(request)));settle(service,requireNotNull(peerStore),work)}
            refresh()
            waitFor {compose.onAllNodesWithText("暂无待审批申请").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText(name).assertDoesNotExist()
            compose.onNodeWithTag("invite-request/$request").assertDoesNotExist()
            runBlocking {avatarGrants.filter {it.content.media==avatarMedia}.forEach {
                assertTrue(runCatching {it.requireValid()}.exceptionOrNull() is AvatarAccessFailure)
            }}
            request=submit();refresh();showApplicant()
            compose.onNodeWithText("拒绝申请").performScrollTo().performClick()
            compose.onNodeWithText("拒绝申请？").assertIsDisplayed()
            compose.onNodeWithText("确认").performClick()
            waitFor {compose.onAllNodesWithText("暂无待审批申请").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText(name).assertDoesNotExist()
            compose.onNodeWithTag("invite-request/$request").assertDoesNotExist()
            assertEquals("rejected",runBlocking {directory.preview(link.secret).requestState})
            compose.runOnUiThread {model!!.signOut()}
            waitFor {model!!.state.value.session==SessionUi.SignedOut && !model!!.state.value.cleanupPending}
            ownerLoggedOut=true
        } catch(error:Throwable) {
            val tree=runCatching {compose.onRoot(useUnmergedTree=true).printToString()}.getOrDefault("UI unavailable")
            val failure=AssertionError("Invitation review UI:\n$tree",error)
            primaryFailure=failure;throw failure
        }
        finally {
            val cleanupErrors=mutableListOf<Throwable>()
            fun cleanup(block:()->Unit) {try {block()} catch(error:Throwable) {cleanupErrors.add(error)}}
            cleanup {
            compose.runOnIdle {displayed=null};compose.waitForIdle();compose.runOnUiThread {models.clear()}
            }
            cleanup { model?.let {value->
                val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default);val done=scope.async {value.awaitShutdown()}
                try {compose.waitUntil(15000) {done.isCompleted};runBlocking {done.await()}} finally {scope.cancel()}
            }
            }
            cleanup {ownerStore?.close()};cleanup {peerStore?.close()}
            cleanup {runBlocking {peer.logout()}};cleanup {if(!ownerLoggedOut) runBlocking {owner.logout()}}
            cleanup {http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()}
            if(primaryFailure!=null) cleanupErrors.forEach {primaryFailure!!.addSuppressed(it)}
            else cleanupErrors.firstOrNull()?.let {first->cleanupErrors.drop(1).forEach(first::addSuppressed);throw first}
        }
    }
}

/** Uses the same durable upload and profile intent chain as the application. */
private suspend fun uploadReviewAvatar(context:Context,credentials:Credentials,api:AuthenticatedTransport,
    store:SqliteClientStore,http:OkHttpClient):String {
    val resources=AccountResourceActivity(context,store,ResourceUploadClient(api,credentials.userId)) {
        ManagedResourceUploadBytes(it,ResourcePlanUploader(http))
    }
    try {
        val client=OwnProfileClient(api,credentials.userId)
        val own=OwnProfileService(credentials.userId,client,store)
        val intents=ProfileIntentService(credentials.userId,own,store)
        val original=intents.refresh()
        val pixels=Bitmap.createBitmap(80,80,Bitmap.Config.ARGB_8888);val bytes=ByteString.newOutput()
        try {pixels.eraseColor(android.graphics.Color.GREEN);assertTrue(pixels.compress(Bitmap.CompressFormat.PNG,100,bytes))}
        finally {pixels.recycle()}
        val asset=resources.files.importPhoto(PhotoPreparation().prepare(bytes.toByteString()),ResourceUsage.UserAvatar)
        val upload=ProfileAvatarUpload(UUID.randomUUID().toString().uppercase(),asset.id,asset.displayName,asset.contentType,asset.byteCount)
        val intent=intents.enqueue(original,upload=upload)
        intents.prepareNext()
        coroutineScope {
            val transfer=launch {resources.runForeground()}
            try {withTimeout(30000) {while(store.resourceUploads().first {it.id==upload.id}.stage!=ResourceUploadStage.Ready) {
                assertFalse(store.resourceUploads().first {it.id==upload.id}.execution.attention);delay(100)
            }}} finally {transfer.cancelAndJoin()}
        }
        intents.prepareNext();own.flush()
        assertEquals(ProfileIntentPhase.Committed,store.profileIntents().first {it.intent.id==intent.id}.phase)
        assertEquals(upload.id,client.current().avatarMediaId)
        return upload.id
    } finally {resources.close()}
}
