package com.xmtx.im

import android.app.Application
import androidx.core.content.edit
import androidx.compose.runtime.Immutable
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.persistentSetOf
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toPersistentList
import kotlinx.collections.immutable.toPersistentSet
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.net.URI
import java.util.UUID

@Immutable
sealed interface SessionUi {
    data object Loading : SessionUi
    data object SignedOut : SessionUi
    data object Authenticating : SessionUi
    data class CredentialsUnavailable(val reason: CredentialStoreFailure.Reason) : SessionUi
    data class LocalUnavailable(val reason: LocalStoreFailure.Reason) : SessionUi
    data class SignedIn(val user: UserId, val demo: Boolean = false,
        val databaseIdentity: LocalDatabaseIdentity? = null) : SessionUi
}
enum class LocalRecoveryPhase { Idle, Preparing, Recovering }
@Immutable data class LocalRecoveryUi(val phase: LocalRecoveryPhase = LocalRecoveryPhase.Idle,
    val preview: LocalStoreRecoverySummary? = null, val error: String? = null)
@Immutable
data class SocialPrompt(val target: UserId, val action: SocialAction, val relationship: RelationshipState,
    val blocked: Boolean, val deadlineNanos: Long, val confirmation: SocialConfirmation? = null)
@Immutable
data class WithdrawalPrompt(val room: RoomId, val message: MessageId, val revision: Long, val actor: UserId, val deadlineNanos: Long)
@Immutable
data class AppState(val session: SessionUi = SessionUi.Loading, val snapshot: ClientSnapshot = ClientSnapshot(),
    val localRecovery: LocalRecoveryUi = LocalRecoveryUi(),
    val conversationActivity: ConversationActivityState = ConversationActivityState(),
    val resourceLibrary:ResourceLibraryState=ResourceLibraryState(),val resourceDetail:ResourceDetailState?=null,
    val resourceTransfers:ResourceTransfersState=ResourceTransfersState(),
    val resourceBackground:ResourceBackgroundState=ResourceBackgroundState.Unavailable,
    val resourceBusiness:ResourceBusinessState?=null,
    val resourceDownloads:ResourceDownloadsState=ResourceDownloadsState(),
    val unavailableRetention:UnavailableRetentionState=UnavailableRetentionState(),
    val resourceStorage:ResourceStorageState=ResourceStorageState(),
    val chatComposer: ChatComposerState? = null, val draftImage: DraftImageState? = null, val chatImages: ChatImagesState? = null, val messageImage: MessageImageState? = null, val messageFile: MessageFileState? = null, val messagePlayback: MessagePlaybackState? = null, val conversationResources: ConversationResourcePickerState? = null, val avatarResources: AvatarResourcePickerState? = null, val avatarEditor: AvatarEditorState? = null, val groupAvatarEditor: GroupAvatarEditorState? = null,
    val resourceUploads: PersistentList<ResourceUploadWork> = persistentListOf(),
    val connection: String = "连接中", val error: String? = null, val notice: String? = null, val securityBusy: Boolean = false, val cleanupPending: Boolean = false, val socialPrompt: SocialPrompt? = null,
    val withdrawalPrompt: WithdrawalPrompt? = null, val preferenceLoading: Boolean = false, val demoPreferences: PersistentList<PreferenceValue> = demoPreferenceDefaults(),
    val members: MembersState? = null, val memberPrompt: MemberPrompt? = null, val capabilityPrompt: CapabilityPrompt? = null, val administrationPrompt: AdministrationPrompt? = null, val moderationPrompt: MessageModerationPrompt? = null, val moderationLoading: Boolean = false)

class AppViewModel internal constructor(application: Application,private val dependencies: AppDependencies) : AndroidViewModel(application) {
    constructor(application: Application):this(application,AppDependencies())
    internal val invitationInbox = InvitationInbox()
    private val mutableState = MutableStateFlow(AppState())
    val state = mutableState.asStateFlow()
    private val preferences = application.getSharedPreferences(dependencies.preferencesName, 0)
    private var endpoint: String = preferences.getString("url", "https://localhost:8443")!!
    val initialEndpoint: String get() = endpoint
    private val secrets = ClassifiedCredentialStore(dependencies.credentialStore(application, dependencies.credentialsName))
    private val exitMarker = FileLocalExitMarker(application, dependencies.credentialsName)
    private val nativeExitCleanup = AccountNativeTransferCleanup(application, exitMarker = exitMarker)
    private var sendAdmission = AccountRetryAdmission()
    private var issuedRecovery = KeystoreIssuedCredentialRecovery(application, credentialRecoveryNamespace(dependencies.credentialsName, endpoint))
    private var auth = AuthSession(secrets, dependencies.account(endpoint), exitMarker, issuedRecovery.receipts, issuedRecovery.registrations)
    private val mutableCredentialRecovery = MutableStateFlow(CredentialRecoveryUi.Empty)
    val credentialRecovery = mutableCredentialRecovery.asStateFlow()
    private var credentialRecoveryReady = false
    private var credentialRevocationTask: Job? = null
    private var registrationCancellationTask: Job? = null
    private var credentialRecoveryObservation: Job? = null
    private var authenticationObservation: Job? = null
    private var authenticationObservationGeneration = 0L
    private var activeAuthenticationIdentity: LocalAccountIdentity? = null
    private var accountNetwork:AccountNetworkActivity?=null
    private var local: SqliteClientStore? = null
    private var resourceActivity: AccountResourceActivity? = null
    private var resourceBackground:ResourceBackgroundSession?=null
    private var resourceBackgroundObservation:Job?=null
    private var cleared = false
    private val shutdownComplete=CompletableDeferred<Unit>()
    internal suspend fun awaitShutdown() {check(cleared);shutdownComplete.await()}
    private var syncWakeups: RealtimeSyncWakeups? = null
    private var conversationActivity: ConversationActivityScene? = null
    private var conversationActivityCollector: Job? = null
    private val closingActivityScenes = mutableSetOf<ConversationActivityScene>()
    private var presencePublication: ConversationActivitySession? = null
    private var retiringLocalAccount = false
    private var roomSubscriptionIntents: RoomSubscriptions? = null
    private var visibleRoomSubscription: RoomSubscriptionLease? = null
    private var activityRoom: RoomId? = null
    private var privacyWrites = 0
    private var connection: RealtimeConnection? = null
    private var runtime: Job? = null
    private var backgroundSync: AppBackgroundSync? = null
    private var visibilityRevision = 0L
    private var foreground = false
    private var messageReadGeneration=0L
    private var operation: Job? = null
    private var directory: PublicIdentityDirectory? = null
    private var profiles: ProfilePresentationClient? = null
    private val profilePages = mutableSetOf<ProfilePresentationPage>()
    private var authorPresentations: AuthorPresentationCoordinator? = null
    private fun startAuthorPresentations(socket: RealtimeConnection,parent: CoroutineScope): AuthorPresentationCoordinator {
        val owner=AuthorPresentationCoordinator(socket,AuthorPresentationClient(socket),parent)
        authorPresentations=owner
        profilePages.toList().forEach(owner::register)
        refreshConversationActivity()
        return owner
    }
    private suspend fun stopAuthorPresentations(owner: AuthorPresentationCoordinator?) {
        owner?.close()
        if(authorPresentations===owner) authorPresentations=null
        withContext(NonCancellable) {owner?.awaitClosed()}
    }
    private var messagePreviews: MessageImagePreviews? = null
    private var messageOriginals: MessageOriginalFiles? = null
    private var messageImage: MessageImageController? = null
    private var conversationResourcePicker: ConversationResourcePickerController?=null
    private var resourceLibrary:ResourceLibraryController?=null
    private var resourceDetail:ResourceDetailController?=null
    private var resourceLibraryVisible=false
    private var transferTasks:ResourceTransfersController?=null
    private var transferTasksVisible=false
    private var resourceBusiness:ResourceBusinessController?=null
    private var downloadTasks:ResourceDownloadsController?=null
    private var downloadTasksVisible=false
    private var unavailableRetention:UnavailableRetentionController?=null
    private var unavailableRetentionVisible=false
    private var resourceStorage:ResourceStorageController?=null
    private var resourceStorageVisible=false
    private var messageFile: MessageFileController? = null
    private var messagePlayback: MessagePlaybackController? = null
    private val closingPlaybacks=mutableSetOf<MessagePlaybackController>()
    private var temporaryFiles: TemporaryResourceFiles? = null
    private val closingMessageFiles=mutableSetOf<MessageFileController>()
    private var chatImages: ChatImagesController? = null
    private var chatComposers: ChatComposerRepository? = null
    private var avatarCache: AvatarCache? = null
    private var directRooms: DirectRoomService? = null
    private var social: SocialService? = null
    private var groupCreation: GroupCreationService? = null
    private var membership: MembershipService? = null
    private var messageModeration: MessageModerationService? = null
    private var messageModerationClient: MessageModerationClient? = null
    private var moderationGeneration = 0L
    private var administration: AdministrationService? = null
    private var capabilities: GroupCapabilityService? = null
    private var invitations: InvitationService? = null
    private var invitationClient: InvitationClient? = null
    private var invitationDirectory: InvitationDirectory? = null
    private var invitationManagement: InvitationManagement? = null
    private var forwards: ForwardPlanService? = null
    private var deviceClient: DeviceSessionClient? = null
    private var deviceJournal: DeviceRevocationJournal? = null
    private var deviceOwner: Pair<UserId, DeviceId>? = null
    private var deviceManagement: DeviceManagement? = null
    private var demoDevices = DemoDevices()
    private var reactions: MessageReactionService? = null
    private var mutations: MessageMutationService? = null
    private var readService: ReadReceiptService? = null
    private var readClient: ReadReceiptClient? = null
    private var ownProfile: OwnProfileService? = null
    private var sendIntents: SendIntentService? = null
    private var profileIntents: ProfileIntentService? = null
    private var groupAvatarIntents: GroupAvatarIntentService? = null
    private var groupAvatarRepository: GroupAvatarRepository? = null
    private var groupAvatarDisplayBudget: GroupAvatarDisplayBudget? = null
    private var resourceCapabilities: ResourceUploadClient? = null
    private var groupAvatarEditor: GroupAvatarEditorController? = null
    private var groupAvatarRelated:ResourceTransferId?=null
    private val groupAvatarPages=mutableSetOf<GroupAvatarPage>()
    private var avatarResourcePicker: AvatarResourcePickerController? = null
    private var avatarEditor: AvatarEditorController? = null
    private var names: NameOperationService? = null
    private var personalPreferences: PersonalPreferenceService? = null
    private var accountPreferences: AccountPreferenceService? = null
    private var capabilityClient: GroupCapabilityClient? = null
    private var memberGeneration = 0L
    private val demoMembers = mutableMapOf<RoomId, MembersState>()
    private val memberCursors = mutableSetOf<String>()
    private var socialGeneration = 0L
    private val businessJobs = mutableSetOf<Job>()

    private val relationshipPages = mutableSetOf<RelationshipPageSession>()
    private val closingRelationshipPages = mutableSetOf<RelationshipPageSession>()
    fun openRelationships(): RelationshipPageSession? {
        val session=state.value.session as? SessionUi.SignedIn ?: return null
        val store=local ?: return null
        if(cleared || !foreground || session.demo || relationshipPages.size>=16) return null
        lateinit var page:RelationshipPageSession
        page=RelationshipPageSession(store,session.user,viewModelScope,store.localDisplayChanges,onClosed={
            relationshipPages.remove(page);closingRelationshipPages.add(page)
            viewModelScope.launch {page.awaitClosed();closingRelationshipPages.remove(page)}
        })
        relationshipPages.add(page);return page
    }

    private val searchPages = mutableSetOf<MessageSearchSession>()
    private val closingSearchPages = mutableSetOf<MessageSearchSession>()
    private var searchWorker: Job? = null
    private val closingSearchWorkers = mutableSetOf<Job>()
    private fun closeSearchPages() {searchPages.toList().forEach {it.close()};relationshipPages.toList().forEach {it.close()} }
    private fun stopSearchWorker() {searchWorker?.let {it.cancel();closingSearchWorkers.add(it)};searchWorker=null}
    private fun refreshSearchRuntime() {
        val session=state.value.session as? SessionUi.SignedIn
        val store=local
        if(cleared || !foreground || session==null || session.demo || store==null) {stopSearchWorker();closeSearchPages();return}
        if(searchWorker?.isActive==true) return
        closingSearchWorkers.removeAll {it.isCompleted}
        searchWorker=viewModelScope.launch {
            var prior: MessageSearchProgress?=null
            while(isActive && local===store) {
                try {
                    val progress=store.processMessageSearchIndex(32)
                    if(progress!=prior) {prior=progress;searchPages.toList().forEach {it.indexChanged(progress)}}
                    delay(if(!progress.ready || progress.pending>0) 10 else 500)
                } catch(e: CancellationException) {throw e}
                catch(_: Exception) {prior=null;searchPages.toList().forEach {it.indexFailed()};delay(2000)}
            }
        }
    }
    fun openMessageSearch(): MessageSearchSession? {
        val session=state.value.session as? SessionUi.SignedIn ?: return null
        val store=local ?: return null
        if(cleared || !foreground || session.demo || searchPages.size>=16) return null
        lateinit var page: MessageSearchSession
        page=MessageSearchSession(store,session.user,viewModelScope,closed={
            searchPages.remove(page);closingSearchPages.add(page)
            viewModelScope.launch {page.awaitClosed();closingSearchPages.remove(page)}
        })
        searchPages.add(page);return page
    }

    suspend fun resumeSendConfirmation(room: RoomId,operation: String) = business {
        val session=state.value.session as? SessionUi.SignedIn ?: return@business
        if(!foreground || session.demo || room in state.value.snapshot.revokedRooms) return@business
        try {local?.resumeSend(room,session.user,operation,System.currentTimeMillis());publishLocal()}
        catch(e: CancellationException) {throw e}
        catch(e: Exception) {mutableState.update {it.copy(error=message(e))}}
    }

    suspend fun replaceUnsentText(room: RoomId,operation: String) = business {
        val session=state.value.session as? SessionUi.SignedIn ?: return@business
        if(!foreground || session.demo || room in state.value.snapshot.revokedRooms) return@business
        try {local?.replaceUnsentText(room,session.user,operation,System.currentTimeMillis());publishLocal()}
        catch(e: CancellationException) {throw e}
        catch(e: Exception) {mutableState.update {it.copy(error=message(e))}}
    }

    suspend fun abandonUnsentText(room: RoomId,operation: String) = business {
        val session=state.value.session as? SessionUi.SignedIn ?: return@business
        if(!foreground || session.demo || room in state.value.snapshot.revokedRooms) return@business
        try {local?.abandonUnsentText(room,session.user,operation);publishLocal()}
        catch(e: CancellationException) {throw e}
        catch(e: Exception) {mutableState.update {it.copy(error=message(e))}}
    }

    private val sendHistoryPages=mutableSetOf<SendHistorySession>()
    private val closingSendHistoryPages=mutableSetOf<SendHistorySession>()
    private fun closeSendHistoryPages() {sendHistoryPages.toList().forEach {it.close()}}
    fun openSendHistory(room: RoomId): SendHistorySession? {
        val session=state.value.session as? SessionUi.SignedIn ?: return null
        val store=local ?: return null
        if(cleared || !foreground || session.demo || room in state.value.snapshot.revokedRooms || sendHistoryPages.size>=8) return null
        lateinit var page: SendHistorySession
        page=SendHistorySession(store,room,session.user,viewModelScope,closed={
            sendHistoryPages.remove(page);closingSendHistoryPages.add(page)
            viewModelScope.launch {page.awaitClosed();closingSendHistoryPages.remove(page)}
        })
        sendHistoryPages.add(page);return page
    }

    private val favoritePages=mutableSetOf<FavoriteMessageSession>()
    private val closingFavoritePages=mutableSetOf<FavoriteMessageSession>()
    private fun closeFavoritePages() {favoritePages.toList().forEach {it.close()}}
    fun openFavorites(): FavoriteMessageSession? {
        val session=state.value.session as? SessionUi.SignedIn ?: return null
        val store=local ?: return null
        if(cleared || !foreground || session.demo || favoritePages.size>=8) return null
        lateinit var page: FavoriteMessageSession
        page=FavoriteMessageSession(store,session.user,viewModelScope,closed={
            favoritePages.remove(page);closingFavoritePages.add(page)
            viewModelScope.launch {page.awaitClosed();closingFavoritePages.remove(page)}
        })
        favoritePages.add(page);return page
    }

    private val sourcePages=mutableSetOf<MessageSourceSession>()
    private val closingSourcePages=mutableSetOf<MessageSourceSession>()
    private fun closeSourcePages() {sourcePages.toList().forEach {it.close()}}
    fun openMessageSources(room: RoomId): MessageSourceSession? {
        val session=state.value.session as? SessionUi.SignedIn ?: return null
        val store=local ?: return null
        if(cleared || !foreground || session.demo || room in state.value.snapshot.revokedRooms || sourcePages.size>=32) return null
        lateinit var page: MessageSourceSession
        page=MessageSourceSession(store,room,session.user,viewModelScope,closed={
            sourcePages.remove(page);closingSourcePages.add(page)
            viewModelScope.launch {page.awaitClosed();closingSourcePages.remove(page)}
        })
        sourcePages.add(page);return page
    }

    private val timelinePages = mutableSetOf<ConversationTimelineSession>()
    private val closingTimelinePages = mutableSetOf<ConversationTimelineSession>()
    private fun closeTimelinePages() { timelinePages.toList().forEach { it.close() } }
    fun openTimelinePage(room: RoomId): ConversationTimelineSession? {
        val session = state.value.session as? SessionUi.SignedIn ?: return null
        val store = local ?: return null
        if (cleared || !foreground || session.demo || room in state.value.snapshot.revokedRooms || timelinePages.size >= 32) return null
        lateinit var page: ConversationTimelineSession
        page = ConversationTimelineSession(store, room, session.user, viewModelScope, closed = {
            timelinePages.remove(page); closingTimelinePages.add(page)
            viewModelScope.launch { page.awaitClosed(); closingTimelinePages.remove(page) }
        })
        timelinePages.add(page)
        return page
    }

    private val summaryPages=linkedMapOf<ConversationSummaryPage,PersistentList<RoomId>>()
    private var visibleSummaryRooms=persistentListOf<RoomId>()
    private var summaryDemandRevision=0L
    private fun refreshSummaryDemand() {
        val session=state.value.session as? SessionUi.SignedIn
        val valid=state.value.snapshot.conversations.map {it.id}.toSet()-state.value.snapshot.revokedRooms
        val next=if(!cleared && foreground && session!=null && !session.demo)
            summaryPages.values.flatten().filter {it in valid}.distinct().take(100).toPersistentList() else persistentListOf()
        if(next!=visibleSummaryRooms) {visibleSummaryRooms=next;summaryDemandRevision++;syncWakeups?.wakeUp()}
    }
    private fun closeSummaryPages() {summaryPages.keys.toList().forEach {it.close()};summaryPages.clear();refreshSummaryDemand()}
    fun openSummaryPage(): ConversationSummaryPage? {
        val session=state.value.session as? SessionUi.SignedIn ?: return null
        if(cleared || !foreground || session.demo || summaryPages.size>=32) return null
        val store=local ?: return null
        lateinit var page: ConversationSummaryPage
        page=ConversationSummaryPage(changed={rooms ->
            if(!cleared && foreground && state.value.session==session && local===store && page in summaryPages) {
                summaryPages[page]=rooms;refreshSummaryDemand()
            }
        },closed={summaryPages.remove(page);refreshSummaryDemand()})
        summaryPages[page]=persistentListOf()
        return page
    }
    init { viewModelScope.launch { state.collect { refreshConversationActivity();refreshSummaryDemand();refreshSearchRuntime() } } }
    fun activateConversationActivity(room: RoomId?) { activityRoom = room; refreshConversationActivity() }
    private fun refreshConversationActivity() {
        val current = state.value
        val signedIn = current.session as? SessionUi.SignedIn
        val allowed = !cleared && !retiringLocalAccount && foreground && signedIn != null && !signedIn.demo
        val conversation = current.snapshot.conversations.firstOrNull { it.id == activityRoom && it.id !in current.snapshot.revokedRooms }
        val selectedRoom = conversation?.id.takeIf { allowed }
        roomSubscriptionIntents?.let { intents ->
            if (visibleRoomSubscription?.room != selectedRoom) {
                visibleRoomSubscription?.let(intents::release)
                visibleRoomSubscription = selectedRoom?.let { intents.acquire(it, persistentSetOf(RoomSubscriptionChannel.RoomEvents)) }
            }
        }
        syncWakeups?.select(selectedRoom)
        authorPresentations?.selectMessageRoom(conversation?.id.takeIf { allowed })
        val policy = PreferencePublicationPolicy.derive(current.snapshot.preferences,current.snapshot.preferenceOperations)
        val draft = current.chatComposer?.takeIf { it.room == conversation?.id }
        // This per-connection controller owns account publication policy only, never room leases.
        presencePublication?.update(ConversationActivityInterest(
            onlineAllowed = allowed && privacyWrites == 0 && policy.online,
            typingAllowed = allowed && privacyWrites == 0 && policy.typing))
        if (allowed && conversationActivity == null) roomSubscriptionIntents?.let { intents ->
            val scene = ConversationActivityScene(requireNotNull(signedIn).user, intents, viewModelScope)
            conversationActivity = scene
            conversationActivityCollector = viewModelScope.launch { scene.state.collect { value ->
                if (conversationActivity === scene && foreground && state.value.session == signedIn)
                    mutableState.update { it.copy(conversationActivity = value) }
            } }
        }
        conversationActivity?.update(ConversationActivityInterest(
            room = conversation?.id.takeIf { allowed }, peer = conversation?.peer,
            group = conversation?.kind == RoomKind.Group,
            hasDraft = draft?.text?.isNotBlank() == true && !draft.sending,
            onlineAllowed = allowed && privacyWrites == 0 && policy.online,
            typingAllowed = allowed && privacyWrites == 0 && policy.typing))
    }
    private fun closeConversationActivity() {
        val old = conversationActivity; conversationActivity = null
        conversationActivityCollector?.cancel(); conversationActivityCollector = null
        old?.let { scene ->
            scene.close(); closingActivityScenes.add(scene)
            viewModelScope.launch { try { scene.awaitClosed() } finally { closingActivityScenes.remove(scene) } }
        }
        mutableState.update { it.copy(conversationActivity = ConversationActivityState()) }
    }
    private val localBootstrapper = LocalStoreBootstrapper(application, dependencies.installationBindings(application))
    private data class RecoveryReview(val preview: LocalStoreRecoveryPreview, val user: UserId, val device: DeviceId)
    private var localRecoveryReview: RecoveryReview? = null
    private var localRecoveryGeneration = 0L
    init { operation = viewModelScope.launch { restoreLocalSession() } }
    private fun startCredentialRecovery() {
        if (cleared || !credentialRecoveryReady) return
        val owner = issuedRecovery
        if (credentialRecoveryObservation?.isActive != true) credentialRecoveryObservation = viewModelScope.launch {
            try { owner.statusUpdates().collect { status ->
                if (!cleared && issuedRecovery === owner && credentialRecoveryReady) mutableCredentialRecovery.value = when (status.cancellations) {
                    CredentialRevocationStatus.Empty -> if (status.awaitingRegistration) CredentialRecoveryUi.AwaitingRegistration else CredentialRecoveryUi.Empty
                    CredentialRevocationStatus.Pending -> CredentialRecoveryUi.Pending
                    CredentialRevocationStatus.Paused -> CredentialRecoveryUi.Paused
                }
            } } catch (error: CancellationException) { throw error }
            catch (_: Exception) { if (!cleared && issuedRecovery === owner) { credentialRecoveryReady = false; mutableCredentialRecovery.value = CredentialRecoveryUi.Unavailable } }
        }
        if (credentialRevocationTask?.isActive != true) {
            val runner = owner.runner(dependencies.account(endpoint))
            credentialRevocationTask = viewModelScope.launch {
                try { runner.run() }
                catch (error: CancellationException) { throw error }
                catch (_: Exception) { if (!cleared && issuedRecovery === owner) { credentialRecoveryReady = false; mutableCredentialRecovery.value = CredentialRecoveryUi.Unavailable } }
            }
        }
        if (registrationCancellationTask?.isActive != true) {
            val runner = owner.cancellationRunner(dependencies.account(endpoint))
            registrationCancellationTask = viewModelScope.launch {
                try { runner.run() }
                catch (error: CancellationException) { throw error }
                catch (_: Exception) { if (!cleared && issuedRecovery === owner) { credentialRecoveryReady = false; mutableCredentialRecovery.value = CredentialRecoveryUi.Unavailable } }
            }
        }
    }
    private suspend fun stopCredentialRecovery() = withContext(NonCancellable) {
        val tasks = listOfNotNull(credentialRevocationTask, registrationCancellationTask, credentialRecoveryObservation)
        tasks.forEach { it.cancel() }; tasks.forEach { it.join() }
        credentialRevocationTask = null; registrationCancellationTask = null; credentialRecoveryObservation = null
    }
    fun retryCredentialRecovery() {
        if (cleared || operation?.isActive == true) return
        operation = viewModelScope.launch {
            stopCredentialRecovery(); mutableCredentialRecovery.value = CredentialRecoveryUi.Checking
            try {
                auth.recoverIssuedCredentials(); issuedRecovery.revocations.retryPaused(); issuedRecovery.registrations.retryPaused()
                if (state.value.session == SessionUi.SignedOut || state.value.session is SessionUi.CredentialsUnavailable) {
                    mutableState.value = AppState(session = SessionUi.Loading)
                    restoreLocalSession()
                } else { credentialRecoveryReady = true; startCredentialRecovery() }
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                credentialRecoveryReady = false; mutableCredentialRecovery.value = CredentialRecoveryUi.Unavailable
                if (error is CredentialStoreFailure) mutableState.value = AppState(session = SessionUi.CredentialsUnavailable(error.reason))
            }
        }
    }
    private suspend fun restoreLocalSession() {
        try {
            stopCredentialRecovery(); credentialRecoveryReady = false
            // A stale camera cache must not prevent restoring an authenticated account.
            try { TemporaryResourceFiles.cleanup(getApplication()) } catch(e: CancellationException) { throw e } catch(_: Exception) { }
            try { CameraCaptureFiles.cleanup(getApplication()) } catch(e: CancellationException) { throw e } catch(_: Exception) { }
            val wasCleaning = auth.hasCleanup()
            var issueRecoveryError: Exception? = null
            try {
                auth.recoverIssuedCredentials(); credentialRecoveryReady = true; startCredentialRecovery()
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                credentialRecoveryReady = false; mutableCredentialRecovery.value = CredentialRecoveryUi.Unavailable
                if (!wasCleaning) throw error else issueRecoveryError = error
            }
            if (auth.hasCleanup()) {
                var cleanupError: String? = null
                try { auth.drainLocalExitWork(::drainLocalExit) }
                catch (e: CancellationException) { throw e }
                catch (e: Exception) { cleanupError = message(e) }
                mutableState.value = AppState(session = SessionUi.SignedOut, cleanupPending = true, error = cleanupError ?: issueRecoveryError?.let(::message))
            }
            else auth.current()?.let { open(it) } ?: run { mutableState.value = AppState(session = SessionUi.SignedOut) }
        } catch (e: CancellationException) { throw e }
        catch (e: LocalExitFailure) { mutableState.value = AppState(session = SessionUi.SignedOut, cleanupPending = true, error = "本机退出状态暂时无法读取，请重试完成退出。") }
        catch (e: CredentialStoreFailure) { mutableState.value = AppState(session = SessionUi.CredentialsUnavailable(e.reason)) }
        catch (e: LocalStoreFailure) { mutableState.value = AppState(session = SessionUi.LocalUnavailable(e.reason)) }
        catch (e: Exception) { mutableState.value = AppState(session = SessionUi.SignedOut, error = message(e)) }
    }
    fun retryLocalSession() {
        if (cleared || operation?.isActive == true || state.value.session !is SessionUi.LocalUnavailable) return
        dismissLocalRecovery()
        mutableState.value = AppState(session = SessionUi.Loading)
        operation = viewModelScope.launch { restoreLocalSession() }
    }
    fun retryCredentialAccess() {
        if (cleared || operation?.isActive == true || state.value.session !is SessionUi.CredentialsUnavailable) return
        mutableState.value = AppState(session = SessionUi.Loading)
        operation = viewModelScope.launch { restoreLocalSession() }
    }
    fun prepareLocalRecovery() {
        val session = state.value.session as? SessionUi.LocalUnavailable ?: return
        if (cleared || !foreground || operation?.isActive == true || session.reason == LocalStoreFailure.Reason.BindingUnavailable) return
        val generation = ++localRecoveryGeneration
        localRecoveryReview = null
        mutableState.update { it.copy(localRecovery = LocalRecoveryUi(phase = LocalRecoveryPhase.Preparing)) }
        operation = viewModelScope.launch {
            try {
                val identity = auth.current() ?: throw ClientFailure.SignedOut()
                val preview = localBootstrapper.previewRecovery(identity.userId, identity.deviceId)
                if (!cleared && foreground && generation == localRecoveryGeneration && state.value.session == session) {
                    localRecoveryReview = RecoveryReview(preview, identity.userId, identity.deviceId)
                    mutableState.update { it.copy(localRecovery = LocalRecoveryUi(preview = preview.summary)) }
                }
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) {
                if (generation == localRecoveryGeneration) mutableState.update { it.copy(localRecovery = LocalRecoveryUi(error = "暂时无法准备恢复，请重试打开本机数据。")) }
            } finally {
                if (generation == localRecoveryGeneration && state.value.localRecovery.phase == LocalRecoveryPhase.Preparing)
                    mutableState.update { it.copy(localRecovery = LocalRecoveryUi()) }
            }
        }
    }
    fun dismissLocalRecovery() {
        val current = state.value.localRecovery
        if (current.phase == LocalRecoveryPhase.Recovering || current == LocalRecoveryUi() && localRecoveryReview == null) return
        ++localRecoveryGeneration; localRecoveryReview = null
        if (current.phase == LocalRecoveryPhase.Preparing) operation?.cancel()
        mutableState.update { it.copy(localRecovery = LocalRecoveryUi()) }
    }
    fun confirmLocalRecovery() {
        val review = localRecoveryReview ?: return
        if (cleared || !foreground || operation?.isActive == true || state.value.session !is SessionUi.LocalUnavailable) return
        localRecoveryReview = null
        mutableState.update { it.copy(localRecovery = LocalRecoveryUi(phase = LocalRecoveryPhase.Recovering)) }
        operation = viewModelScope.launch {
            try {
                val credentials = auth.access()
                if (credentials.userId != review.user || credentials.deviceId != review.device) throw ClientFailure.SignedOut()
                closeLocalAccount()
                val current = auth.current() ?: throw ClientFailure.SignedOut()
                if (current.userId != review.user || current.deviceId != review.device) throw ClientFailure.SignedOut()
                localBootstrapper.recoverLocalStore(review.preview)
                val restored = auth.current() ?: throw ClientFailure.SignedOut()
                if (restored.userId != review.user || restored.deviceId != review.device) throw ClientFailure.SignedOut()
                open(restored)
            } catch (error: CancellationException) { throw error }
            catch (_: ClientFailure.SignedOut) { restoreLocalSession() }
            catch (_: Exception) {
                if (!cleared) mutableState.update { it.copy(localRecovery = LocalRecoveryUi(error = "恢复未完成。原文件或恢复副本已保留，可重试打开。")) }
            }
        }
    }

    fun login(account: String, password: String, register: Boolean, handle: String, name: String, url: String) {
        if (cleared || operation?.isActive == true || state.value.cleanupPending || state.value.session != SessionUi.SignedOut) return
        if (credentialRecovery.value in listOf(CredentialRecoveryUi.Unavailable, CredentialRecoveryUi.Checking)) return
        operation = viewModelScope.launch {
            mutableState.update { it.copy(session = SessionUi.Authenticating, error = null) }
            try {
                check(!auth.hasCleanup()) { "请先完成退出登录" }
                val parsed = URI(url)
                require(parsed.scheme == "https" && parsed.host != null && parsed.userInfo == null && parsed.query == null && parsed.fragment == null) { "请输入有效的 HTTPS 服务地址" }
                // Pending credentials/cleanup are bound to the original server; don't send them to a different endpoint.
                if (url != endpoint) {
                    check(secrets.read() == null && !issuedRecovery.receipts.hasPendingReceipts() && !issuedRecovery.registrations.hasWork() && issuedRecovery.revocations.status() == CredentialRevocationStatus.Empty) { "请先完成原服务器的登录清理" }
                }
                val api = dependencies.account(url) // Validate the complete endpoint before persisting it for next launch.
                if (url != endpoint) stopCredentialRecovery()
                check(withContext(Dispatchers.IO) { preferences.edit().putString("url", url).commit() }) { "无法保存服务地址，请重试" }
                if (url != endpoint) {
                    endpoint = url
                    issuedRecovery = KeystoreIssuedCredentialRecovery(getApplication(), credentialRecoveryNamespace(dependencies.credentialsName, endpoint))
                    credentialRecoveryReady = false; mutableCredentialRecovery.value = CredentialRecoveryUi.Empty
                }
                auth = AuthSession(secrets, api, exitMarker, issuedRecovery.receipts, issuedRecovery.registrations)
                open(auth.login(account, password, register, handle, name))
            } catch (e: CancellationException) { throw e }
            catch (e: CredentialStoreFailure) { mutableState.value = AppState(session = SessionUi.CredentialsUnavailable(e.reason)) }
            catch (e: CredentialRecoveryFailure) { credentialRecoveryReady = false; mutableCredentialRecovery.value = CredentialRecoveryUi.Unavailable; mutableState.value = AppState(session = SessionUi.SignedOut, error = message(e)) }
            catch (e: LocalStoreFailure) { mutableState.value = AppState(session = SessionUi.LocalUnavailable(e.reason)) }
            catch (e: Exception) { mutableState.update { it.copy(session = SessionUi.SignedOut, error = message(e), cleanupPending = runCatching { auth.hasCleanup() }.getOrDefault(true)) } }
            finally { if (!cleared) { if (credentialRecovery.value != CredentialRecoveryUi.Unavailable) credentialRecoveryReady = true; startCredentialRecovery() } }
        }
    }
    private suspend fun open(credentials: Credentials) {
        chatComposers?.activate(null);closeChatImages();closeMessageImage();closeMessageFile();closeMessagePlayback();closeAvatarEditor();closeGroupAvatarEditor();closeConversationResources();closeResourceManagement()
        drainBusinessJobs()
        closeLocalAccount()
        val openingAuth = auth
        val identity = openingAuth.localAccountIdentity()
        if (identity.userId != credentials.userId || identity.deviceId != credentials.deviceId) throw ClientFailure.SessionInvalidated()
        // Allocation cannot lose its handle if clearing cancels the dispatcher handoff.
        val store = withContext(NonCancellable+Dispatchers.IO) { localBootstrapper.open(openingAuth, identity) }
        try { currentCoroutineContext().ensureActive();check(!cleared) } catch(error: Throwable) { withContext(NonCancellable+Dispatchers.IO) { store.close() };throw error }
        local = store
        roomSubscriptionIntents = RoomSubscriptions(credentials.userId, viewModelScope)
        retiringLocalAccount = false
        sendAdmission = AccountRetryAdmission()
        val network=dependencies.networkActivity();accountNetwork=network
        store.installNetworkDiagnostics(network.scheduler.networkDiagnostics)
        val api = network.authenticated(auth, dependencies.account(endpoint), credentials.userId, credentials.deviceId)
        resourceCapabilities=ResourceUploadClient(api,credentials.userId)
        resourceActivity = AccountResourceActivity(getApplication(),store,requireNotNull(resourceCapabilities),imports=ResourceImportClient(api,credentials.userId),download=dependencies.download,targets=MediaDownloadTargetClient(api),scheduler=network.scheduler,bytes=dependencies.uploadBytes,
            systemUploads=ResourceSystemUploadDriver(getApplication(),exitMarker=exitMarker),systemDownloads=ResourceSystemDownloadDriver(getApplication(),exitMarker=exitMarker))
        requireNotNull(resourceActivity).prepareNetworkTransfers()
        val backgroundSession=ResourceBackgroundSessions.register(requireNotNull(resourceActivity));resourceBackground=backgroundSession
        resourceBackgroundObservation=viewModelScope.launch {backgroundSession.state.collect {value->
            if(!cleared && local===store && (state.value.session as? SessionUi.SignedIn)?.user==credentials.userId) mutableState.update {it.copy(resourceBackground=value)}
        }}
        directory = PublicIdentityDirectory(api, credentials.userId, credentials.deviceId)
        closeProfilePages()
        profiles = ProfilePresentationClient(api,credentials.userId,credentials.deviceId)
        avatarCache = AvatarCache(credentials.userId,credentials.deviceId,fetch={grant->
            withContext(NetworkWorkScope(network.scheduler,NetworkWorkContext("mediaProvider",kind=NetworkWorkKind.Download))) {dependencies.avatarDownload(grant)}
        })
        val accountFiles=requireNotNull(resourceActivity).files
        chatComposers=ChatComposerRepository(getApplication(),credentials.userId,store,accountFiles,readProfiles=profiles,lookupMention={ handle->lookup(handle)?.takeIf {it.valid()}?.identity?.user ?: error("无法解析提及对象") },publishImage={ value -> if(local===store && !cleared && state.value.session is SessionUi.SignedIn) mutableState.update { it.copy(draftImage=value) } }) { value -> if(local===store && !cleared && state.value.session is SessionUi.SignedIn) mutableState.update { it.copy(chatComposer=value) } }
        chatComposers?.foreground(foreground)
        messagePreviews=MessageImagePreviews(MediaDownloadTargetClient(api),store,fetch={ target ->
            require(target.preview!=null && target.plan.expectedBytes in 1..2L*1024*1024)
            requireNotNull(accountFiles.withDownloaded(target,false) { file ->
                file.inputStream().use(com.google.protobuf.ByteString::readFrom)
            })
        })
        messageOriginals=MessageOriginalFiles(MediaDownloadTargetClient(api),store,accountFiles)
        temporaryFiles=TemporaryResourceFiles(getApplication(),viewModelScope,store.resourceDirectoryChanges) { read ->
            !cleared && local===store && state.value.session is SessionUi.SignedIn && store.isMessageResourceCurrent(read)
        }
        groupAvatarDisplayBudget=GroupAvatarDisplayBudget()
        deviceManagement?.close()
        deviceClient = DeviceSessionClient(api, credentials.deviceId)
        val binding = java.security.MessageDigest.getInstance("SHA-256").digest(endpoint.toByteArray()).joinToString("") { "%02x".format(it) }
        deviceJournal = DeviceRevocationJournal(KeystoreSecretStore(getApplication(), "device-revocations-$binding-${credentials.userId.value}-${credentials.deviceId.value}"), credentials.userId, credentials.deviceId)
        deviceOwner = credentials.userId to credentials.deviceId
        directRooms = DirectRoomService(credentials.userId, DirectRoomClient(api), store)
        social = SocialService(credentials.userId, SocialClient(api, credentials.userId), store)
        groupCreation = GroupCreationService(credentials.userId, GroupCreationClient(api), store)
        membership = MembershipService(credentials.userId, MembershipClient(api), store)
        capabilityClient = GroupCapabilityClient(api)
        messageModerationClient = MessageModerationClient(api)
        messageModeration = MessageModerationService(credentials.userId, requireNotNull(messageModerationClient), store)
        administration = AdministrationService(credentials.userId, AdministrationClient(api), store)
        capabilities = GroupCapabilityService(credentials.userId, requireNotNull(capabilityClient), store)
        invitationClient = InvitationClient(api)
        invitationDirectory = InvitationDirectory(api)
        invitations = InvitationService(credentials.userId, requireNotNull(invitationClient), store,
            KeystoreInvitationSecrets(getApplication(), endpoint, credentials.userId, credentials.deviceId))
        forwards = ForwardPlanService(credentials.userId, ForwardPlanClient(api), store)
        reactions = MessageReactionService(credentials.userId, MessageReactionClient(api), store)
        mutations = MessageMutationService(credentials.userId, MessageMutationClient(api), store)
        accountPreferences = AccountPreferenceService(credentials.userId, AccountPreferenceClient(api, credentials.userId), store,
            commandNow = { if (accountNetwork !== network) throw ClientFailure.SignedOut()
                connection?.takeIf { it.state.value.connected }?.serverTime?.now()
                ?: throw ServerTimeAnchor.Failure(ServerTimeAnchor.Reason.Unavailable) })
        ownProfile = OwnProfileService(credentials.userId,OwnProfileClient(api,credentials.userId),store)
        ownProfile?.recoverAfterPreviousOwnerDrained()
        sendIntents = SendIntentService(credentials.userId,store)
        profileIntents = ProfileIntentService(credentials.userId,requireNotNull(ownProfile),store)
        groupAvatarIntents = GroupAvatarIntentService(credentials.userId,credentials.deviceId,GroupAvatarCommandClient(api,credentials.userId,credentials.deviceId),
            GroupAvatarPresentationClient(api,credentials.userId,credentials.deviceId),store)
        groupAvatarRepository=GroupAvatarRepository(credentials.userId,credentials.deviceId,GroupAvatarPresentationClient(api,credentials.userId,credentials.deviceId),{ room ->
            check(!cleared && foreground && local===store)
            store.groupAvatarFence(room)
        },viewModelScope)
        names = NameOperationService(credentials.userId,NameOperationClient(api),store)
        // open() has drained business jobs and the prior account runtime before this handoff.
        names?.recoverAfterPreviousOwnerDrained()
        personalPreferences = PersonalPreferenceService(credentials.userId, PersonalPreferenceClient(object : EnvelopeTransport {
            override suspend fun request(body: com.xmtx.imclientkit.generated.im.realtime.v2.Envelope.Builder) = (connection ?: throw java.io.IOException("Realtime unavailable")).request(body)
        }, api), store)
        readClient = ReadReceiptClient(object : EnvelopeTransport {
            override suspend fun request(body: Envelope.Builder) = (connection ?: throw java.io.IOException("Realtime unavailable")).request(body)
        },api)
        readService = ReadReceiptService(credentials.userId,requireNotNull(readClient),store,batchSize = 4)
        val initialSnapshot = store.observedAppSnapshot()
        val snapshot = initialSnapshot.snapshot
        try {
            if (auth !== openingAuth) throw ClientFailure.SessionInvalidated()
            openingAuth.requireLocalIdentity(identity)
        } catch (error: Throwable) { closeLocalAccount(); throw error }
        backgroundSync = AppBackgroundSync(dependencies.backgroundRealtime(endpoint), openingAuth, identity, store, network, viewModelScope)
        mutableState.value = AppState(session = SessionUi.SignedIn(credentials.userId, databaseIdentity = store.databaseIdentity), snapshot = snapshot,resourceBackground=backgroundSession.state.value)
        initialSnapshot.conversationCommit?.didPublishSnapshot()
        observeAuthentication(openingAuth, identity, store)
        startRuntime()
    }
    private fun stopAuthenticationObservation() {
        authenticationObservationGeneration++
        authenticationObservation?.cancel(); authenticationObservation = null
    }
    private fun observeAuthentication(source: AuthSession, identity: LocalAccountIdentity, store: SqliteClientStore) {
        stopAuthenticationObservation()
        activeAuthenticationIdentity = identity
        val generation = authenticationObservationGeneration
        authenticationObservation = viewModelScope.launch {
            source.sessionUpdates(identity.epoch).collect { snapshot ->
                if (generation != authenticationObservationGeneration || cleared || auth !== source || local !== store ||
                    state.value.session !is SessionUi.SignedIn) return@collect
                val status = snapshot.status
                val active = (status as? AuthSessionSnapshot.Status.Active)?.state
                val ended = (status as? AuthSessionSnapshot.Status.Ended)?.reason
                val unavailable = active as? AuthSessionState.CredentialsUnavailable
                val pending = active == AuthSessionState.CleanupPending || active is AuthSessionState.ExitUnavailable || ended == AuthSessionSnapshot.EndReason.CredentialDeletionPending
                if (unavailable != null || pending || active == AuthSessionState.Unauthenticated || ended != null)
                    withdrawAuthentication(source, unavailable?.reason, pending)
            }
        }
    }
    /** Withdraw presentation synchronously; drain from a separate owner, never from the observed worker. */
    private fun withdrawAuthentication(source: AuthSession, unavailable: CredentialStoreFailure.Reason?, pending: Boolean, ensureExitIntent: Boolean = false) {
        val expectedEpoch = activeAuthenticationIdentity?.epoch
        stopAuthenticationObservation()
        invitationInbox.clear(); dismissLocalRecovery()
        deviceManagement?.close(); deviceManagement = null
        invitationManagement?.close(); invitationManagement = null
        backgroundSync?.interrupt(); connection?.close()
        mutableState.value = AppState(session = SessionUi.Loading)
        val previous = operation
        previous?.cancel()
        val retiring = viewModelScope.launch(start = CoroutineStart.LAZY) {
            try {
                previous?.join()
                drainBusinessJobs()
                closeLocalAccount(clearLocalDisplay = unavailable == null)
                currentCoroutineContext().ensureActive()
                if (cleared || auth !== source || operation !== currentCoroutineContext().job) return@launch
                // The ended epoch may already have completed deletion. Never revoke a replacement session.
                var cleanup = false
                if (ensureExitIntent && expectedEpoch != null) {
                    try { source.prepareLocalExit(expectedEpoch); cleanup = true }
                    catch (_: ClientFailure.SessionInvalidated) { /* A replacement credential is never retired here. */ }
                    catch (error: CancellationException) { throw error }
                    catch (_: Exception) { cleanup = true /* Intent failed to persist; explicit cleanup must retry. */ }
                }
                if (!cleanup) cleanup = try { pending && source.hasCleanup() } catch (_: LocalExitFailure) { true }
                mutableState.value = if (unavailable != null && !cleanup)
                    AppState(session = SessionUi.CredentialsUnavailable(unavailable))
                else AppState(session = SessionUi.SignedOut, cleanupPending = cleanup)
            } catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                if (!cleared && auth === source && operation === currentCoroutineContext().job)
                    mutableState.value = AppState(session = if (unavailable != null) SessionUi.CredentialsUnavailable(unavailable) else SessionUi.LocalUnavailable(LocalStoreFailure.Reason.StoreUnavailable),
                        error = "账号任务尚未完成关闭，请重试。", cleanupPending = pending)
            }
        }
        operation = retiring; retiring.start()
    }
    fun foreground(active: Boolean) {
        if(cleared) return
        if(foreground!=active) {messageReadGeneration++;replyGeneration++;visibilityRevision++}
        foreground = active
        refreshConversationActivity()
        if (!active) dismissLocalRecovery()
        resourceLibrary?.foreground(active && resourceLibraryVisible);resourceDetail?.foreground(active)
        transferTasks?.foreground(active && transferTasksVisible)
        resourceBusiness?.foreground(active)
        downloadTasks?.foreground(active && downloadTasksVisible)
        unavailableRetention?.foreground(active && unavailableRetentionVisible)
        resourceStorage?.foreground(active && resourceStorageVisible)
        refreshSearchRuntime()
        chatComposers?.foreground(active);chatImages?.foreground(active);messageImage?.foreground(active);messageFile?.foreground(active);messagePlayback?.foreground(active);avatarEditor?.foreground(active);avatarResourcePicker?.foreground(active);conversationResourcePicker?.foreground(active);groupAvatarEditor?.foreground(active)
        if (active) {backgroundSync?.interrupt();startRuntime()} else { closeSendHistoryPages();closeFavoritePages();closeSourcePages();closeTimelinePages();closeSummaryPages();closeConversationActivity();closeProfilePages();closeGroupAvatarPages();dismissWithdrawal(); dismissSocialPrompt(); clearMembers(); invitationManagement?.close(); deviceManagement?.close(); connection?.close(); runtime?.cancel() }
    }
    /** Process-owned wake entry. A system/push caller supplies its original monotonic deadline.
     * Going into the background alone does not schedule a sync. A cancelled waiter cannot cancel
     * shared work; foreground/account retirement explicitly interrupts and drains its owner.
     */
    suspend fun synchronizeInBackground(deadlineNanos: Long = System.nanoTime() + 25_000_000_000L): BackgroundSyncOutcome =
        withContext(Dispatchers.Main.immediate) {
            if (cleared || foreground) return@withContext BackgroundSyncOutcome.NoData
            val revision = visibilityRevision
            suspend fun awaitPreparation(job: Job?) {
                val remaining = deadlineNanos - System.nanoTime()
                if (remaining <= 0) throw BackgroundSyncDeadlineReached()
                withTimeout(remaining / 1_000_000 + if (remaining % 1_000_000 == 0L) 0 else 1) { job?.join() }
            }
            try {
                if (state.value.session == SessionUi.Loading) awaitPreparation(operation)
                if (cleared || foreground || revision != visibilityRevision || retiringLocalAccount)
                    return@withContext BackgroundSyncOutcome.NoData
                val session = state.value.session as? SessionUi.SignedIn ?: return@withContext BackgroundSyncOutcome.NoData
                if (session.demo) return@withContext BackgroundSyncOutcome.NoData
                val owner = backgroundSync ?: return@withContext BackgroundSyncOutcome.NoData
                val source = auth
                // The foreground driver may still be draining after ON_STOP. Its directory scope
                // and database work must finish before a background connection can replace it.
                awaitPreparation(runtime)
                if (cleared || foreground || revision != visibilityRevision || retiringLocalAccount ||
                    backgroundSync !== owner || state.value.session != session) return@withContext BackgroundSyncOutcome.NoData
                try {
                    val result = owner.run(deadlineNanos)
                    if (cleared || foreground || revision != visibilityRevision || backgroundSync !== owner || state.value.session != session)
                        BackgroundSyncOutcome.NoData
                    else if (result.didCommitNewRecords) BackgroundSyncOutcome.NewData else BackgroundSyncOutcome.NoData
                } catch (error: CancellationException) { throw error }
                catch (error: Exception) {
                    if (cleared || foreground || revision != visibilityRevision || retiringLocalAccount || backgroundSync !== owner || state.value.session != session)
                        return@withContext BackgroundSyncOutcome.NoData
                    if (auth === source) {
                        if (error is CredentialStoreFailure || error is ClientFailure.SessionInvalidated)
                            withdrawAuthentication(source, (error as? CredentialStoreFailure)?.reason, false)
                        else if (error is ClientFailure.SignedOut || error is ClientFailure.Http && error.status in setOf(401,403) ||
                            error is GatewayFailure && error.code in setOf("SESSION_REVOKED","DEVICE_REVOKED"))
                            withdrawAuthentication(source, null, true, ensureExitIntent = true)
                    }
                    BackgroundSyncOutcome.Failed
                }
            } catch (error: TimeoutCancellationException) {
                currentCoroutineContext().ensureActive()
                BackgroundSyncOutcome.Failed
            }
            catch (error: CancellationException) {
                currentCoroutineContext().ensureActive() // External waiter cancellation remains cancellation.
                BackgroundSyncOutcome.NoData // Account/foreground retirement cancelled the shared flight.
            } catch (_: Exception) { BackgroundSyncOutcome.Failed }
        }

    private fun closeProfilePages() {
        authorPresentations?.close();authorPresentations=null
        profilePages.toList().forEach { it.close() };profilePages.clear()
    }
    fun openProfiles(): ProfilePresentationPage? {
        val session = state.value.session as? SessionUi.SignedIn ?: return null
        if(!foreground || session.demo || profilePages.size>=16) return null
        val store = local ?: return null;val client = profiles ?: return null;val device = deviceOwner?.second ?: return null;val cache=avatarCache ?: return null
        return ProfilePresentationPage(session.user,device,client,{ keys ->
            if(!foreground || local !== store || state.value.session != session) throw ClientFailure.SignedOut()
            store.profileFences(keys)
        },viewModelScope,onClose = { profilePages.remove(it);authorPresentations?.remove(it) },avatarReader=cache::read,
            localDisplays = LocalProfileDisplaySaving { values, expected ->
                if (!foreground || local !== store || state.value.session != session) throw ClientFailure.SignedOut()
                store.saveLocalProfileDisplays(values, expected)
            }, localDisplayReader = LocalProfileDisplayReading { keys, expected ->
                if (!foreground || local !== store || state.value.session != session) throw ClientFailure.SignedOut()
                store.readLocalProfileDisplays(keys, expected)
            }, localDisplayChanges = store.localDisplayChanges).also {
            profilePages.add(it);authorPresentations?.register(it)
        }
    }
    private fun closeGroupAvatarPages() { groupAvatarPages.toList().forEach { it.close() };groupAvatarPages.clear() }
    fun openGroupAvatar(room: RoomId): GroupAvatarPage? {
        val session=state.value.session as? SessionUi.SignedIn ?: return null
        if(cleared || !foreground || session.demo || room in state.value.snapshot.revokedRooms || groupAvatarPages.size>=32) return null
        val repository=groupAvatarRepository ?: return null;val cache=avatarCache ?: return null;val budget=groupAvatarDisplayBudget ?: return null
        return GroupAvatarPage(room,repository,cache::read,viewModelScope,onClose={ groupAvatarPages.remove(it) },budget=budget).also { if(!it.isClosed) groupAvatarPages.add(it) }
    }
    private fun startRuntime() {
        val session = state.value.session as? SessionUi.SignedIn ?: return
        if (cleared || !foreground || session.demo || runtime?.isActive == true) return
        val previous = runtime
        runtime = viewModelScope.launch(start=CoroutineStart.UNDISPATCHED) {
            withContext(NonCancellable) { previous?.join(); backgroundSync?.stop() }
            currentCoroutineContext().ensureActive()
            if(cleared || !foreground || state.value.session != session) return@launch
            val commandStore = local ?: return@launch
            val resources = resourceActivity
            val recovery=accountNetwork?.recoveryScope() ?: return@launch
            val resourceWorker = launch {
                try { resources?.runForeground { uploads ->
                    if(!cleared && foreground && local === commandStore && state.value.session == session)
                        mutableState.update { it.copy(resourceUploads=uploads) }
                } } catch(error: CancellationException) { throw error }
                catch(error: Exception) { if(!cleared && local === commandStore && state.value.session == session) mutableState.update { it.copy(error=message(error)) } }
            }
            val sends=sendIntents
            val sendWorker=launch(recovery) {
                try { sends?.runPreparation() }
                catch(error: CancellationException) { throw error }
                catch(error: Exception) { if(!cleared && local===commandStore && state.value.session==session) mutableState.update { it.copy(error=message(error)) } }
            }
            val preparation=profileIntents
            val profileWorker=launch(recovery) {
                try { preparation?.runPreparation() }
                catch(error: CancellationException) { throw error }
                catch(error: Exception) { if(!cleared && local===commandStore && state.value.session==session) mutableState.update { it.copy(error=message(error)) } }
            }
            val groupAvatarPreparation=groupAvatarIntents
            val groupAvatarWorker=launch(recovery) {
                try { groupAvatarPreparation?.runForeground() }
                catch(error: CancellationException) { throw error }
                catch(error: Exception) { if(!cleared && local===commandStore && state.value.session==session) mutableState.update { it.copy(error=message(error)) } }
            }
            val localDirectWorker = launch(recovery) {
                try { directRooms?.runLocalMessagePreparation(onChanged = {
                    if (!cleared && local === commandStore && state.value.session == session) publishLocal()
                }, onFailure = { error ->
                    if (!cleared && local === commandStore && state.value.session == session) mutableState.update { it.copy(error = message(error)) }
                }) } catch (error: CancellationException) { throw error }
                catch (error: Exception) { if (!cleared && local === commandStore && state.value.session == session) mutableState.update { it.copy(error = message(error)) } }
            }
            val commandWorker = launch(recovery) commandWorker@ {
                while (isActive) {
                    try {
                        directRooms?.flush(); publishLocal(); social?.flush(); membership?.flush(); capabilities?.flush(); administration?.flush(); messageModeration?.flush(); invitations?.flush(); accountPreferences?.flush(); personalPreferences?.flush(); names?.flush(); ownProfile?.flush(); mutations?.flush(); reactions?.flush(); forwards?.flush(); readService?.flush()
                        withContext(Dispatchers.Default) { groupCreation?.flush() }
                        val observed = commandStore.observedAppSnapshot()
                        publishSnapshot(observed.snapshot)
                        observed.conversationCommit?.didPublishSnapshot()
                    } catch (e: CancellationException) { throw e }
                    catch (e: Exception) {
                        if (e is ClientFailure.SignedOut) {
                            if (state.value.session == session) withdrawAuthentication(auth, null, true, ensureExitIntent = true)
                            return@commandWorker
                        }
                        mutableState.update { it.copy(error = message(e)) }
                    }
                    delay(3_000)
                }
            }
            try {
                runRealtimeConnections(session)
            } finally { withContext(NonCancellable) { localDirectWorker.cancelAndJoin();sendWorker.cancelAndJoin();groupAvatarWorker.cancelAndJoin();profileWorker.cancelAndJoin();resourceWorker.cancelAndJoin();commandWorker.cancelAndJoin() } }
        }
    }
    private suspend fun CoroutineScope.runRealtimeConnections(session: SessionUi.SignedIn) {
        val network=accountNetwork ?: return
        val intents = roomSubscriptionIntents ?: return
        var retry = 1_000L
        while (isActive) {
            val socket = dependencies.realtime(endpoint)
            connection = socket
            var activity: ConversationActivitySession? = null
            var authors: AuthorPresentationCoordinator? = null
            var wakes: RealtimeSyncWakeups? = null
            var connectionWatcher: Job? = null
            var roomSubscriptions: RoomEventSubscriptionCoordinator? = null
            var sharedActivity: LiveActivitySubscriptionCoordinator? = null
            var subscriptionConnectionId: String? = null
            try {
                mutableState.update { it.copy(connection = "连接中") }
                val credentials = network.access(auth)
                if(credentials.userId!=session.user) throw ClientFailure.SignedOut()
                try { socket.connect(credentials,network.scheduler) }
                catch (e: GatewayFailure) {
                    if (e.code != "UNAUTHENTICATED" || e.retryable) throw e
                    val refreshed=network.access(auth,rejectedAccess = credentials)
                    if(refreshed.userId!=session.user) throw ClientFailure.SignedOut()
                    socket.connect(refreshed,network.scheduler)
                }
                val store = local ?: return
                store.resumeNetworkWaitingSends(session.user,System.currentTimeMillis())
                val sync = SyncEngine(socket, store)
                val outbox = MessageOutbox(socket, store,sendAdmission)
                val rooms = RoomSyncEngine(socket, store)
                val heartbeat = HeartbeatClient(socket) { room -> if(store.pendingSnapshot()==null && store.pendingReset()==null) store.roomCursor(room).sequence else null }
                val policyRecovery = RolePolicyRecoveryRunner(store,MemberDirectory(socket)::policies,batchSize = 4)
                val pending = RealtimeSyncWakeups(socket.state.value.epoch,socket.syncEvents,this)
                wakes = pending; syncWakeups = pending; refreshConversationActivity()
            connectionWatcher = launch { socket.state.collect { if(!it.connected) {authors?.close();pending.account()} } }
                val accountChanges = AccountRoomChangesClient(socket)
                var recoveryEpoch = accountChanges.start()
                val directory = RoomDirectoryRecovery(socket,store,rooms)
                directory.start()
                var recoveryVerified = false
                var verifiedNotifications = pending.notificationRevision
                var verifiedDemand = summaryDemandRevision
                var headScan: RoomId? = null
                var subscriptionRevocations = state.value.snapshot.revokedRooms
                var subscriptionAccessChanged = false
                val subscriptions = RoomEventSubscriptionCoordinator(socket.state.value.epoch,
                    RoomEventSubscriptionClient(socket), socket.state, socket.syncEvents, this,
                    isAuthorized = { room -> !store.isRoomLocallyRevoked(room) },
                    roomCursor = { room -> store.roomCursor(room).sequence },
                    onSubscribed = { seed -> pending.room(seed.room, seed.head, true) },
                    onRevoked = { room -> store.unavailable(room); subscriptionAccessChanged = true }, wake = pending::wakeUp)
                roomSubscriptions = subscriptions
                val shared = LiveActivitySubscriptionCoordinator(socket.state.value.epoch, LiveActivityClient(socket),
                    socket.activityEvents, socket.state, this, socket::close, { room -> !store.isRoomLocallyRevoked(room) })
                sharedActivity = shared
                var nextMaintenance = System.nanoTime()
                var personalCaughtUp = false
                retry = 1_000
                while (isActive) {
                    val work = pending.take()
                    val maintenance = System.nanoTime() >= nextMaintenance || work.refreshDirectory
                    work.restartAccountEpoch?.let { lost ->
                        if(lost != recoveryEpoch) throw ClientFailure.Protocol()
                        recoveryEpoch = accountChanges.start();headScan=null
                    }
                    if(work.refreshDirectory) {directory.restart();recoveryVerified=false}
                    if(pending.notificationRevision != verifiedNotifications || summaryDemandRevision != verifiedDemand) recoveryVerified=false
                    if (maintenance || work.account) {
                        recoveryVerified = false
                        personalCaughtUp = !sync.synchronizeTurn()
                        if (!personalCaughtUp) pending.account()
                    }
                    if(store.pendingSnapshot()!=null || store.pendingReset()!=null) {
                        pending.deferForSnapshot(work)
                        if(maintenance) {
                            heartbeat.send()
                            nextMaintenance=System.nanoTime()+5_000_000_000L
                        }
                        mutableState.update {it.copy(connection="正在恢复同步",error=null)}
                        yield()
                        continue
                    }
                    if (subscriptionConnectionId == null && personalCaughtUp) {
                        subscriptionConnectionId = intents.attach(RoomSubscriptionConnection(socket.state.value.epoch,
                            socket.state, subscriptions, shared, socket::close))
                    }
                    subscriptionConnectionId?.let { intents.reconcile(it) }
                    if (maintenance) {
                        heartbeat.send()
                        policyRecovery.recoverOnce(); outbox.flush()
                        nextMaintenance = System.nanoTime()+5_000_000_000L
                    }
                    for (hint in work.rooms) {
                        if (!hint.force && store.roomCursor(hint.room).sequence >= hint.head) continue
                        if(hint.liveEvents.isNotEmpty()) {
                            val applied=rooms.applyOnlineEvents(RealtimeSyncHint.Room(hint.room,hint.head,hint.liveEvents))
                            if(applied && !hint.force) continue
                        }
                        val result = rooms.synchronizeRoom(hint.room,maximumPages=2)
                        if(result.retryAfterMillis > 0 || result.hasMore || !result.unavailable && result.appliedThrough < hint.head) pending.room(hint.room,
                            maxOf(hint.head,result.observedHead),true,maxOf(if(result.hasMore) 250 else 1_000,result.retryAfterMillis))
                    }
                    // Directory discovery and its durable work progress independently of hot room hints.
                    directory.ensureVisible(visibleSummaryRooms)
                    val directoryProgress=directory.runTurn()
                    val slots=minOf(32,pending.availableRoomSlots)
                    if(slots > 0) {
                        val heads=store.pendingRoomHeads(headScan,slots)
                        heads.lastOrNull()?.let {headScan=it.room}
                        heads.forEach {pending.room(it.room,it.sequence)}
                    }
                    if(!recoveryVerified && directoryProgress.complete && directoryProgress.pendingRooms == 0 && !pending.hasPendingRecovery) {
                        val revision=pending.notificationRevision
                        val demand=summaryDemandRevision
                        recoveryVerified=directory.completeIfCaughtUp(sync) {
                            socket.state.value.connected && pending.notificationRevision == revision && summaryDemandRevision == demand && !pending.hasPendingRecovery
                        }
                        if(recoveryVerified) {verifiedNotifications=revision;verifiedDemand=demand} else pending.account()
                    }
                    var observed = store.observedAppSnapshot()
                    var snapshot = observed.snapshot
                    if (subscriptionRevocations != snapshot.revokedRooms) {
                        subscriptionRevocations = snapshot.revokedRooms; intents.authorityDidChange()
                    }
                    subscriptionAccessChanged = false
                    subscriptionConnectionId?.let { intents.reconcile(it) }
                    if (subscriptionAccessChanged) {
                        val next=store.observedAppSnapshot()
                        observed=next.copy(conversationCommit=ConversationCommitMeasurement.earliest(observed.conversationCommit,next.conversationCommit))
                        snapshot=observed.snapshot
                    }
                    publishSnapshot(snapshot)
                    observed.conversationCommit?.didPublishSnapshot()
                    if(authors==null && personalCaughtUp && socket.state.value.authorStream!=null) {
                        authors=startAuthorPresentations(socket,this)
                    }
                    if (activity == null && personalCaughtUp) {
                        val live = ConversationActivitySession(session.user,socket.state.value.epoch,shared.consumerCommands(),
                            socket.activityEvents,socket.state,this,{ socket.latestActivitySequence },socket::close, disconnectOnClose = false)
                        activity = live; presencePublication = live
                        refreshConversationActivity()
                    }
                    mutableState.update { it.copy(connection = "已连接", error = null) }
                    val directoryWait=if(!directoryProgress.complete) 1L else directoryProgress.nextAttemptAt?.let {
                        (it-System.currentTimeMillis()).coerceAtLeast(1)
                    } ?: Long.MAX_VALUE
                    pending.await(minOf(directoryWait,((nextMaintenance-System.nanoTime())/1_000_000).coerceAtLeast(1)))
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                if (e is CredentialStoreFailure || e is ClientFailure.SessionInvalidated) {
                    if (state.value.session == session) withdrawAuthentication(auth, (e as? CredentialStoreFailure)?.reason, false)
                    return
                }
                if (e is ClientFailure.SignedOut || (e is ClientFailure.Http && e.status in setOf(401, 403)) || (e is GatewayFailure && e.code in setOf("SESSION_REVOKED","DEVICE_REVOKED"))) {
                    if (state.value.session == session) withdrawAuthentication(auth, null, true, ensureExitIntent = true)
                    return
                }
                if(e is RealtimeUnavailableBeforeAdmission || e is GatewayFailure && e.code=="UNAUTHENTICATED") {
                    try {publishLocal()} catch(cancelled: CancellationException) {throw cancelled} catch(_: Exception) { /* Preserve the connection failure as feedback. */ }
                }
                mutableState.update { it.copy(connection = "离线 · 自动重连", error = message(e)) }
                delay(retry); retry = (retry * 2).coerceAtMost(30_000)
            } finally {
                // Closing first unblocks scheduled on-wire calls before awaiting their owners.
                socket.close(); if (connection === socket) connection = null
                connectionWatcher?.cancel();wakes?.close(); if(syncWakeups === wakes) syncWakeups = null
                withContext(NonCancellable) {
                    subscriptionConnectionId?.let { intents.detach(it) }
                    roomSubscriptions?.awaitClosed(); sharedActivity?.awaitClosed()
                }
                activity?.close()
                if (presencePublication === activity) presencePublication = null
                stopAuthorPresentations(authors)
            }
        }
    }
    private suspend fun <T> business(body: suspend () -> T): T = coroutineScope {
        check(!cleared)
        val job = coroutineContext.job
        businessJobs.add(job)
        try { coroutineScope { body() } } finally { businessJobs.remove(job) }
    }
    suspend fun lookup(handle: String): IdentityLookup? = business {
        try {
            mutableState.update { it.copy(error = null) }
            val session = state.value.session as? SessionUi.SignedIn ?: return@business null
            if (session.demo) {
                val canonical = PublicHandle(handle)
                val contact = state.value.snapshot.contacts.firstOrNull { it.handle == canonical.value }
                    ?: throw ClientFailure.Http(404)
                IdentityLookup(PublicIdentity(contact.id, canonical, contact.name, AccountKind.Regular), System.nanoTime() + 60_000_000_000)
            } else directory?.resolve(handle)
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) }; null }
    }
    suspend fun openLocalDirect(target: UserId, profile: ProfileReadResult.Available? = null, identity: PublicIdentity? = null): DirectConversationDestination? = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business null
        if (session.demo) return@business DirectConversationDestination.Room(RoomId(target.value))
        try {
            val selected = identity ?: profile?.takeIf { it.valid() }?.profile?.view?.identity
                ?: throw IllegalArgumentException("请先获取对方的公开身份")
            require(selected.user == target)
            val result = directRooms?.openLocal(selected) ?: return@business null
            publishLocal(); mutableState.update { it.copy(error = null) }; result
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { mutableState.update { it.copy(error = message(error)) }; null }
    }
    suspend fun sendLocalDirect(value: LocalDirectMessage): Boolean = business {
        try {
            (directRooms ?: return@business false).enqueueLocalMessage(value)
            publishLocal(); mutableState.update { it.copy(error = null) }; true
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { mutableState.update { it.copy(error = message(error)) }; false }
    }
    suspend fun prepareLocalDirectMessages() = business {
        try { directRooms?.prepareLocalMessages(); publishLocal() }
        catch (error: CancellationException) { throw error }
        catch (error: Exception) { publishLocal(); mutableState.update { it.copy(error = message(error)) } }
    }
    suspend fun retryLocalDirect(operation: String): DirectConversationDestination? = business {
        try {
            val work = state.value.snapshot.directOperations.firstOrNull { it.command.operation == operation } ?: return@business null
            val service = directRooms ?: return@business null
            val destination = if (work.terminal && work.status != DirectWorkStatus.Opened) {
                DirectConversationDestination.Pending(service.prepare(requireNotNull(work.publicIdentity)).command.operation)
            } else { service.retry(operation); DirectConversationDestination.Pending(operation) }
            publishLocal(); destination
        } catch (error: CancellationException) { throw error }
        catch (error: Exception) { mutableState.update { it.copy(error = message(error)) }; null }
    }
    suspend fun enterLocalDirectRoom(operation: String, text: String): RoomId? = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business null
        try { local?.enterLocalDirectRoom(session.user, operation, text)?.also { publishLocal() } }
        catch (error: CancellationException) { throw error }
        catch (error: Exception) { mutableState.update { it.copy(error = message(error)) }; null }
    }
    suspend fun openDirect(target: UserId,profile: ProfileReadResult.Available?=null,identity: PublicIdentity?=null): RoomId? = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business null
        if (session.demo) return@business RoomId(target.value)
        try {
            val service = directRooms ?: return@business null
            val store = local ?: return@business null
            val selected = identity ?: profile?.takeIf { it.valid() }?.profile?.view?.identity
                ?: throw IllegalArgumentException("请先获取对方的公开身份")
            require(selected.user == target)
            val work = service.prepare(selected)
            val prepared = store.observedAppSnapshot()
            mutableState.update { it.copy(snapshot = prepared.snapshot, error = null) }
            prepared.conversationCommit?.didPublishSnapshot()
            service.flush()
            val observed = store.observedAppSnapshot()
            val snapshot = observed.snapshot
            mutableState.update { it.copy(snapshot = snapshot) }
            observed.conversationCommit?.didPublishSnapshot()
            snapshot.directOperations.firstOrNull { it.command.operation == work.command.operation }?.room?.also {room->
                if(local===store && state.value.session==session && profile?.valid()==true && profile.key.user==target)
                    store.adoptDirectAccountKind(room,profile,store.profileFences(persistentListOf(profile.key)))
            }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) }; null }
    }
    suspend fun retryDirect(operation: String) = business {
        try {
            directRooms?.retry(operation); directRooms?.flush()
            local?.observedAppSnapshot()?.let { observed ->
                mutableState.update { it.copy(snapshot = observed.snapshot, error = null) }
                observed.conversationCommit?.didPublishSnapshot()
            }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    fun dismissMemberPrompt() { mutableState.update { it.copy(memberPrompt = null) } }
    fun clearMembers() { dismissMessageModeration(); memberGeneration++; memberCursors.clear(); mutableState.update { it.copy(members = null, memberPrompt = null, capabilityPrompt = null, administrationPrompt = null) } }
    suspend fun loadMembers(room: RoomId, more: Boolean = false) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        val previous = state.value.members?.takeIf { it.room == room }
        if (previous?.loading == true || more && (previous == null || previous.stale || previous.nextCursor == null)) return@business
        val generation = ++memberGeneration
        if (!more) memberCursors.clear()
        mutableState.update { it.copy(members = (previous ?: MembersState(room)).copy(loading = true, stale = !more, error = null), memberPrompt = null, capabilityPrompt = null, administrationPrompt = null) }
        try {
            val loaded = if (session.demo) demoMembers.getOrPut(room) {
                MembersState(room, 1, MemberRole.Owner, persistentListOf(GroupMember(session.user, MemberRole.Owner), GroupMember(UserId("lin"), MemberRole.Admin), GroupMember(UserId("chen"), MemberRole.Member)),
                    policies = GroupPolicies(room, 1, 1, 0, GroupPermission.entries.toPersistentSet(), setOf(GroupPermission.Send).toPersistentSet()), stale = false)
            } else {
                val reader = MemberDirectory(connection ?: throw IllegalStateException("请等待实时连接后重试"))
                val cursor = if (more) previous?.nextCursor else null
                var page = reader.page(room, cursor)
                var policies = if (more) requireNotNull(previous?.policies) else reader.policies(room)
                var reset = !more
                if (page.revision != policies.membershipRevision || more && (page.revision != previous?.revision || page.actorRole != previous?.actorRole)) {
                    page = reader.page(room); policies = reader.policies(room); reset = true
                }
                check(page.revision == policies.membershipRevision) { "成员目录已变化，请刷新后重试" }
                val known = if (reset) persistentListOf() else requireNotNull(previous).items
                check(page.members.none { member -> known.any { it.user == member.user } }) { "成员分页重复，请刷新" }
                if (reset) memberCursors.clear()
                page.nextCursor?.let { check(memberCursors.add(it)) { "成员分页未推进，请刷新" } }
                val combined = known.addAll(page.members)
                MembersState(room, page.revision, page.actorRole, combined.takeLast(1000).toPersistentList(), page.nextCursor, policies,
                    stale = false, earlier = combined.size > 1000 || (!reset && previous?.earlier == true))
            }
            if (memberGeneration == generation && foreground) mutableState.update { it.copy(members = loaded.observeAccess(it.snapshot,session.user)) }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { if (memberGeneration == generation) mutableState.update { it.copy(members = (it.members?.takeIf { current -> current.room == room } ?: MembersState(room)).copy(loading = false,stale = true,error = message(e))) } }
    }
    suspend fun reportRead(room: RoomId,sequence: Long) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        if(!foreground || session.demo || room in state.value.snapshot.revokedRooms) return@business
        try {
            if(sequence > 0) { readService?.enqueue(room,sequence);publishLocal() }
        } catch(e: CancellationException) { throw e }
        catch(_: Exception) { /* Local reading remains available when the bounded queue is full. */ }
    }
    suspend fun retryRead(operation: String) = readAction { readService?.retry(operation) }
    suspend fun archiveRead(operation: String) = readAction { readService?.archive(operation) }
    suspend fun restoreRead(operation: String) = readAction { readService?.restore(operation) }
    private suspend fun readAction(action: suspend () -> Unit) = business {
        try { action();publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    /** Operation-time source reads never depend on whichever timeline window is visible. */
    private suspend fun operationSources(session: SessionUi.SignedIn, room: RoomId,
        ids: kotlinx.collections.immutable.PersistentSet<MessageId>): kotlinx.collections.immutable.PersistentMap<MessageId,Message> {
        require(ids.size <= 100)
        val readGeneration=messageReadGeneration
        fun current() = !cleared && foreground && state.value.session == session && messageReadGeneration==readGeneration
        check(current()) { "页面已失效，请重新打开" }
        if(room in state.value.snapshot.revokedRooms) return kotlinx.collections.immutable.persistentMapOf()
        if(session.demo) return state.value.snapshot.messages.filter { it.roomId==room && it.id in ids &&
            !it.withdrawn && !it.redacted && it.delivery==Delivery.Accepted && it.revision>0 }
            .associateBy {it.id}.let { kotlinx.collections.immutable.persistentMapOf<MessageId,Message>().putAll(it) }
        val store=local ?: throw ClientFailure.SignedOut()
        val sources=store.messageSources(room,session.user,ids)
        currentCoroutineContext().ensureActive()
        check(current() && local===store) { "账号或页面已变化，请重新打开" }
        return if(room in state.value.snapshot.revokedRooms) kotlinx.collections.immutable.persistentMapOf() else sources
    }
    private suspend fun operationSource(session: SessionUi.SignedIn,room: RoomId,id: MessageId) =
        operationSources(session,room,kotlinx.collections.immutable.persistentSetOf(id))[id]

    suspend fun readReaders(room: RoomId,message: MessageId,cursor: String?): ReadReadersPage = business {
        val session = state.value.session as? SessionUi.SignedIn ?: throw ClientFailure.SignedOut()
        check(!session.demo)
        val readGeneration=messageReadGeneration
        val source = operationSource(session,room,message)
        check(source?.sender == session.user) { "消息当前不可查看已读名单" }
        val page = requireNotNull(readClient).readers(room,message,cursor)
        check(readGeneration==messageReadGeneration && operationSource(session,room,message)?.revision == source.revision) { "消息已变化，请重新打开" }
        page
    }
    suspend fun retryPolicyRecovery(room: RoomId) = business {
        try { local?.requestPolicyRecovery(room,resume = true);publishLocal() }
        catch(e: CancellationException) { throw e }
        catch(e: PolicyRecoverySyncPending) { mutableState.update { it.copy(error = "请等待同步恢复完成") } }
        catch(e: PolicyRecoveryUnauthorized) { mutableState.update { it.copy(error = "群权限当前不可访问，请刷新群状态") } }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun prepareMember(room: RoomId, target: UserId?, action: MembershipAction, handle: String? = null, draft: String? = null) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        val directory = state.value.members ?: return@business
        val generation = memberGeneration
        try {
            check(directory.room == room && !directory.stale && !directory.loading) { "请先刷新群成员" }
            val confirmation = if (session.demo) null else membership?.confirmation(room, action, requireNotNull(directory.revision)) ?: return@business
            val resolved = target ?: lookup(requireNotNull(handle))?.takeIf { it.valid() }?.identity?.user ?: return@business
            if (generation != memberGeneration || !foreground) return@business
            if (action == MembershipAction.Add) check(resolved != session.user && directory.allows(GroupPermission.Invite)) { "当前无法邀请该成员" }
            else if (resolved == session.user) check(directory.actorRole != MemberRole.Owner) { "群主需先转让群主后退群" }
            else check(directory.allows(GroupPermission.Remove) && directory.items.any { it.user == resolved && it.role != MemberRole.Owner }) { "当前无法移除此成员" }
            mutableState.update { it.copy(memberPrompt = MemberPrompt(room, resolved, action, confirmation, System.nanoTime() + 30_000_000_000, draft), error = null) }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun confirmMember() = business {
        val prompt = state.value.memberPrompt ?: return@business
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        dismissMemberPrompt()
        try {
            check(prompt.deadlineNanos - System.nanoTime() > 0 && state.value.members?.stale == false) { "确认已过期，请刷新成员后重试" }
            if (session.demo) {
                val directory = requireNotNull(state.value.members)
                val items = if (prompt.action == MembershipAction.Add) directory.items.filter { it.user != prompt.target }.toPersistentList().add(GroupMember(prompt.target, MemberRole.Member)) else directory.items.filter { it.user != prompt.target }.toPersistentList()
                val revision = requireNotNull(directory.revision) + 1
                val next = directory.copy(items = items, revision = revision, policies = directory.policies?.copy(membershipRevision = revision))
                demoMembers[prompt.room] = next; mutableState.update { it.copy(members = next) }
            } else {
                val service = membership ?: return@business
                if (prompt.draft == null) service.enqueue(prompt.target, requireNotNull(prompt.confirmation))
                else service.reconfirm(prompt.draft, requireNotNull(prompt.confirmation))
                publishLocal(); mutableState.update { it.copy(members = it.members?.copy(stale = true)) }
            }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun retryMember(id: String) = business {
        try { membership?.retry(id); publishLocal() } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun discardMember(id: String) = business {
        try { membership?.discard(id); publishLocal() } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    fun dismissMessageModeration() { moderationGeneration++; mutableState.update { it.copy(moderationPrompt = null,moderationLoading = false) } }
    suspend fun prepareMessageModeration(room: RoomId,id: MessageId) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        if(state.value.snapshot.conversations.none { it.id == room && it.kind == RoomKind.Group }) return@business
        val generation = ++moderationGeneration
        mutableState.update { it.copy(moderationLoading = true,moderationPrompt = null,error = null) }
        try {
            val original = operationSource(session,room,id) ?: return@business
            loadMembers(room)
            if(generation != moderationGeneration || !foreground || state.value.session != session) return@business
            val directory = requireNotNull(state.value.members)
            check(directory.room == room && directory.allows(GroupPermission.Moderate)) { "当前权限不允许审核此消息" }
            val baseline = if(session.demo) null else requireNotNull(messageModerationClient).baseline(room,id)
            if(generation != moderationGeneration || !foreground || state.value.session != session) return@business
            check(baseline == null || !baseline.redacted && baseline.messageRevision == original.revision && baseline.membershipRevision == directory.revision) { "消息或成员版本已变化，请同步后重新选择" }
            check(operationSource(session,room,id)?.revision == original.revision) { "消息已变化，请重新选择" }
            if(generation!=moderationGeneration) return@business
            val confirmation = baseline?.let { requireNotNull(messageModeration).confirmation(it,"ADMIN_ACTION") }
            mutableState.update { it.copy(moderationPrompt = MessageModerationPrompt(room,id,original.revision,requireNotNull(directory.revision),original.text.take(240),confirmation,System.nanoTime()+30000000000)) }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { if(generation == moderationGeneration) mutableState.update { it.copy(error = when {
            e is ClientFailure.Http && e.status == 404 -> "消息或群聊已不可访问"
            e is ClientFailure.Http && e.status == 403 -> "当前权限不允许审核此消息"
            else -> message(e)
        }) } }
        finally { if(generation == moderationGeneration) mutableState.update { it.copy(moderationLoading = false) } }
    }
    suspend fun confirmMessageModeration() = business {
        val prompt = state.value.moderationPrompt ?: return@business
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        dismissMessageModeration()
        try {
            val directory = requireNotNull(state.value.members)
            check(prompt.deadlineNanos > System.nanoTime() && directory.room == prompt.room && directory.revision == prompt.membershipRevision && directory.allows(GroupPermission.Moderate)) { "确认已过期，请重新选择消息" }
            check(operationSource(session,prompt.room,prompt.message)?.revision == prompt.messageRevision) { "消息已变化，请重新选择" }
            if(session.demo) mutableState.update { current -> current.copy(snapshot = current.snapshot.copy(
                messages = current.snapshot.messages.map { if(it.id == prompt.message && it.roomId == prompt.room) it.copy(text = "消息已由管理员移除",withdrawn = true,redacted = true,revision = it.revision+1,forwardedFrom = null) else it }.toPersistentList(),
                pins = current.snapshot.pins.filterNot { it.room == prompt.room && it.message == prompt.message }.toPersistentList(),
                reactions = current.snapshot.reactions.filterNot { it.room == prompt.room && it.message == prompt.message }.toPersistentList())) }
            else { requireNotNull(messageModeration).enqueue(requireNotNull(prompt.confirmation));publishLocal() }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun retryMessageModeration(id: String) = business {
        try { messageModeration?.retry(id);publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    fun dismissAdministration() { mutableState.update { it.copy(administrationPrompt = null) } }
    suspend fun prepareAdministration(room: RoomId,target: UserId,mute: Boolean,draft: AdministrationWork? = null) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        try {
            val directory = requireNotNull(state.value.members)
            val permission = if(mute) GroupPermission.Mute else GroupPermission.Remove
            check(directory.room == room && directory.allows(permission) && target != session.user && directory.items.any { it.user == target && it.role != MemberRole.Owner }) { "请刷新成员与管理权限" }
            val revision = requireNotNull(directory.revision)
            val action = draft?.intent?.action ?: if(mute) AdministrationAction.Mute(System.currentTimeMillis()+3600000) else AdministrationAction.Remove
            check((action is AdministrationAction.Mute) == mute)
            val confirmation = if(session.demo) null else requireNotNull(administration).confirmation(room,target,action,draft?.intent?.reason ?: "ADMIN_ACTION",revision)
            mutableState.update { it.copy(administrationPrompt = AdministrationPrompt(room,target,action,revision,confirmation,System.nanoTime()+30000000000,draft?.intent?.key),error = null) }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun confirmAdministration() = business {
        val prompt = state.value.administrationPrompt ?: return@business
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        dismissAdministration()
        try {
            val directory = requireNotNull(state.value.members)
            val mute = prompt.action is AdministrationAction.Mute
            check(prompt.deadlineNanos > System.nanoTime() && directory.room == prompt.room && directory.revision == prompt.revision && directory.allows(if(mute) GroupPermission.Mute else GroupPermission.Remove)) { "确认已过期，请刷新成员后重试" }
            check(prompt.target != session.user && directory.items.any { it.user == prompt.target && it.role != MemberRole.Owner })
            if(session.demo) {
                val revision = requireNotNull(directory.revision) + if(mute) 0 else 1
                val next = directory.copy(items = if(mute) directory.items else directory.items.filter { it.user != prompt.target }.toPersistentList(),revision = revision,
                    policies = directory.policies?.copy(membershipRevision = revision),administrationFeedback = if(mute) "离线演示：已禁言 1 小时" else "离线演示：已管理移除成员")
                demoMembers[prompt.room] = next; mutableState.update { it.copy(members = next) }
            } else {
                val service = requireNotNull(administration)
                if(prompt.draft == null) service.enqueue(requireNotNull(prompt.confirmation)) else service.reconfirm(prompt.draft,requireNotNull(prompt.confirmation))
                publishLocal(); mutableState.update { it.copy(members = it.members?.copy(stale = true)) }
            }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun retryAdministration(id: String) = business {
        try { administration?.retry(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun discardAdministration(id: String) = business {
        try { administration?.discard(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    private var withdrawalGeneration=0L
    fun dismissWithdrawal() { withdrawalGeneration++;mutableState.update { it.copy(withdrawalPrompt = null) } }
    fun prepareWithdrawal(room: RoomId, messageId: MessageId) {
        val session = state.value.session as? SessionUi.SignedIn ?: return
        val generation=++withdrawalGeneration
        mutableState.update {it.copy(withdrawalPrompt=null)}
        viewModelScope.launch { business {
            try {
                val message=operationSource(session,room,messageId) ?: return@business
                if(generation!=withdrawalGeneration || message.sender!=session.user) return@business
                mutableState.update { it.copy(withdrawalPrompt = WithdrawalPrompt(room,messageId,message.revision,session.user,System.nanoTime()+30_000_000_000),error=null) }
            } catch(e: CancellationException) {throw e}
            catch(e: Exception) {if(generation==withdrawalGeneration && state.value.session==session) mutableState.update {it.copy(error=message(e))}}
        } }
    }
    suspend fun confirmWithdrawal() = business {
        val prompt = state.value.withdrawalPrompt ?: return@business
        dismissWithdrawal()
        if(prompt.deadlineNanos - System.nanoTime() <= 0) { mutableState.update { it.copy(error = "确认已过期，请重新选择消息") }; return@business }
        mutateMessage(prompt.room, prompt.message, prompt.revision, null, prompt.actor)
    }
    suspend fun editMessage(room: RoomId, messageId: MessageId, revision: Long, text: String): Boolean = business {
        val actor = (state.value.session as? SessionUi.SignedIn)?.user ?: return@business false
        val trimmed = text.trim()
        if(trimmed.isEmpty() || trimmed.toByteArray().size > 65536) { mutableState.update { it.copy(error = "消息内容不能为空，且不能超过 65536 UTF-8 字节") }; return@business false }
        mutateMessage(room, messageId, revision, trimmed, actor)
    }
    private suspend fun mutateMessage(room: RoomId, messageId: MessageId, revision: Long, text: String?, actor: UserId): Boolean {
        val session = state.value.session as? SessionUi.SignedIn ?: return false
        try {
            check(session.user == actor && room !in state.value.snapshot.revokedRooms) { "此会话已不可访问" }
            val message = operationSource(session,room,messageId)
            check(message != null && message.sender == actor && !message.withdrawn && message.delivery == Delivery.Accepted && message.revision == revision && revision > 0) { "消息已变化，请重新查看后操作；草稿仍保留" }
            if(session.demo) {
                mutableState.update { current ->
                    val messages = current.snapshot.messages.map { if(it.id == messageId && it.roomId == room) it.copy(text = text ?: "消息已撤回", withdrawn = text == null, revision = revision + 1, forwardedFrom = if(text == null) null else it.forwardedFrom) else it }.toPersistentList()
                    current.copy(snapshot = current.snapshot.copy(messages = messages,
                        reactions = current.snapshot.reactions.filter { text != null || it.message != messageId || it.room != room }.toPersistentList(),
                        pins = current.snapshot.pins.filter { text != null || it.message != messageId || it.room != room }.toPersistentList(),
                        conversations = current.snapshot.conversations.map { if(it.id == room) it.copy(preview = messages.lastOrNull { value -> value.roomId == room }?.text.orEmpty()) else it }.toPersistentList()), error = null)
                }
            } else { requireNotNull(mutations).enqueue(room, messageId, revision, text); publishLocal() }
            return true
        } catch(e: CancellationException) { throw e } catch(e: Exception) { mutableState.update { it.copy(error = message(e)) }; return false }
    }
    suspend fun retryMutation(id: String) = business {
        try { mutations?.retry(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    internal suspend fun forwardMessages(room: RoomId, sources: PersistentList<SelectedForwardMessage>, targets: kotlinx.collections.immutable.PersistentList<RoomId>): Boolean = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business false
        try {
            val snapshot = state.value.snapshot
            check(sources.size in 1..100 && targets.size in 1..10 && sources.map { it.message }.distinct().size == sources.size && targets.distinct().size == targets.size)
            check(room !in snapshot.revokedRooms && targets.all { target -> target !in snapshot.revokedRooms && snapshot.conversations.any { it.id == target } }) { "来源或目标会话当前不可用" }
            check(foreground && sources.all {it.revision>0 && it.sequence>=0})
            val ordered=sources.sortedWith(compareBy<SelectedForwardMessage> {it.sequence}.thenBy {it.message.value})
            if(session.demo) {
                val currentSources=operationSources(session,room,sources.map {it.message}.toPersistentSet())
                val messages=ordered.map {selected -> currentSources[selected.message]?.takeIf {it.revision==selected.revision}
                    ?: error("演示来源已变化，请重新选择")}
                mutableState.update { current ->
                    val added = targets.flatMap { target -> messages.map { message -> Message(MessageId(UUID.randomUUID().toString()), target, session.user, message.text,
                        System.currentTimeMillis(), forwardedFrom = message.forwardedFrom ?: ForwardAttribution(message.id, message.sender)) } }
                    current.copy(snapshot = current.snapshot.copy(messages = current.snapshot.messages.addAll(added), conversations = current.snapshot.conversations.map { conversation ->
                        added.lastOrNull { it.roomId == conversation.id }?.let { conversation.copy(preview = it.text, updatedAt = it.createdAt) } ?: conversation
                    }.toPersistentList()), error = null)
                }
            } else { requireNotNull(forwards).enqueue(ordered.map { ForwardSource(room,it.message,it.revision) }.toPersistentList(), targets); publishLocal() }
            true
        } catch(e: CancellationException) { throw e } catch(e: Exception) { mutableState.update { it.copy(error = message(e)) }; false }
    }
    suspend fun retryForward(id: String) = business {
        try { forwards?.retry(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun cancelForward(id: String) = business {
        try { forwards?.cancel(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun changeReaction(room: RoomId, messageId: MessageId, reaction: String, present: Boolean) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        try {
            val key = normalizedReaction(reaction)
            check(operationSource(session,room,messageId) != null) { "消息当前不可添加反应" }
            if(session.demo) {
                mutableState.update { current ->
                    val summaries = current.snapshot.reactions
                    val old = summaries.firstOrNull { it.room == room && it.message == messageId && it.reaction == key }
                    val count = (old?.count ?: 0) + (if(present) 1 else 0) - (if(old?.own == true) 1 else 0)
                    val rest = summaries.filter { it != old }.toPersistentList()
                    current.copy(snapshot = current.snapshot.copy(reactions = if(count > 0) rest.add(MessageReactionSummary(room, messageId, key, count, present)) else rest), error = null)
                }
            } else { requireNotNull(reactions).enqueue(room, messageId, key, present); publishLocal() }
        } catch(e: CancellationException) { throw e } catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun retryReaction(id: String) = business {
        try { reactions?.retry(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun discardReaction(id: String) = business {
        try { reactions?.discard(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun changeConversation(room: RoomId, patch: ConversationPatch) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        try {
            if(session.demo) {
                val snapshot = state.value.snapshot
                val conversation = snapshot.conversations.first { it.id == room }
                val old = snapshot.personalStates.firstOrNull { it.target.key == PersonalTarget.Conversation(room).key }
                val target = patch.apply(old?.target as? PersonalTarget.Conversation ?: PersonalTarget.Conversation(room, conversation.pinned, conversation.archived, if(conversation.muted) Long.MAX_VALUE else 0))
                val updated = PersonalState(target, (old?.revision ?: 0) + 1, System.currentTimeMillis())
                mutableState.update { it.copy(snapshot = it.snapshot.copy(
                    personalStates = (it.snapshot.personalStates.filter { value -> value.target.key != target.key } + updated).toPersistentList(),
                    conversations = it.snapshot.conversations.map { value -> if(value.id == room) value.copy(pinned = target.pinned, archived = target.archived, muted = target.muteUntil > System.currentTimeMillis()) else value }
                        .sortedWith(compareByDescending<Conversation> { it.pinned }.thenByDescending { it.updatedAt }).toPersistentList()), error = null) }
            } else { requireNotNull(personalPreferences).conversation(room, patch); publishLocal() }
        } catch(e: CancellationException) { throw e } catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun changeFavorite(room: RoomId, messageId: MessageId, favorite: Boolean) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        try {
            if(session.demo) {
                val target = PersonalTarget.Favorite(room, messageId, favorite)
                val prior = state.value.snapshot.personalStates.firstOrNull { it.target.key == target.key }
                val updated = PersonalState(target, (prior?.revision ?: 0) + 1, System.currentTimeMillis())
                mutableState.update { it.copy(snapshot = it.snapshot.copy(personalStates = (it.snapshot.personalStates.filter { value -> value.target.key != target.key } + updated).toPersistentList()), error = null) }
            } else { requireNotNull(personalPreferences).favorite(room, messageId, favorite); publishLocal() }
        } catch(e: CancellationException) { throw e } catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    fun activateGroupAvatarEditor(id: String?,room: RoomId?,related:ResourceTransferId?=null) {
        if(cleared || id!=null && groupAvatarEditor?.id==id && groupAvatarEditor?.room==room && groupAvatarRelated==related) return
        closeGroupAvatarEditor();groupAvatarRelated=related
        val session=state.value.session as? SessionUi.SignedIn ?: return
        if(id==null || room==null) return
        mutableState.update { it.copy(groupAvatarEditor=GroupAvatarEditorState(id,room)) }
        if(session.demo) return
        val store=local ?: return;val resources=resourceActivity ?: return;val service=groupAvatarIntents ?: return;val capability=resourceCapabilities ?: return
        fun valid()=!cleared && foreground && local===store && state.value.session==session && groupAvatarEditor?.id==id
        suspend fun maximum(): Long? {
            val value=capability.capabilities()
            return if("groupAvatar" in value.usages && ResourceTransferMode.Put in value.modes) minOf(value.maximumBytes,value.maximumImageBytes ?: Long.MAX_VALUE,10L*1024*1024) else null
        }
        suspend fun relatedAvailable()=related==null || store.resourceHasBusinessOwner(related,ResourceBusinessOwner.Group(room,id))
        val processor=PhotoPreparation()
        groupAvatarEditor=GroupAvatarEditorController(id,room,viewModelScope,
            load={ business {
                check(valid());val authority=service.refresh(room)
                val maximum=if(authority.presentation.canManage) try { maximum() } catch(error: CancellationException) { throw error } catch(_: Exception) { null } else null
                check(valid() && authority.presentation.valid());GroupAvatarManagementAccess(authority,maximum)
            } },
            read={ processor.prepare(getApplication<Application>().contentResolver,it) },crop={ photo,rect -> processor.crop(photo,rect) },
            submit={ authority,photo -> business {
                check(valid());check(store.groupAvatarIntents().none { it.command.room==room && it.pending })
                var asset: ResourceLocalAsset?=null
                try {
                    asset=photo?.let { resources.files.importPhoto(it,ResourceUsage.GroupAvatar(room)) }
                    currentCoroutineContext().ensureActive();check(valid())
                    val intent=service.enqueue(authority,asset);currentCoroutineContext().ensureActive()
                    if(valid()) publishLocal();intent.id
                } finally { asset?.let { original -> withContext(NonCancellable) { resources.files.discardSelection(original.id);resources.files.cleanup() } } }
            } },
            act={ intent,action,authority -> business {
                check(valid());check(relatedAvailable());require(related==null || intent==id);val value=store.groupAvatarIntents().first { it.id==intent };require(value.command.room==room && value.actor==session.user)
                when(action) {
                    GroupAvatarTaskAction.Retry -> service.retry(intent)
                    GroupAvatarTaskAction.Cancel -> service.cancel(intent)
                    GroupAvatarTaskAction.Abandon -> service.abandon(intent)
                    GroupAvatarTaskAction.Replace -> {
                        if(value.upload!=null) {
                            val maximum=requireNotNull(maximum());val original=store.resourceAssets().first { it.id==value.asset }
                            require(original.byteCount<=maximum)
                        }
                        currentCoroutineContext().ensureActive();check(valid());service.replace(intent,requireNotNull(authority))
                    }
                }
                currentCoroutineContext().ensureActive();if(valid()) publishLocal()
            } },publish={ value -> if(!cleared && local===store && state.value.session==session && groupAvatarEditor?.id==id) mutableState.update { it.copy(groupAvatarEditor=value) } },focused=related!=null,verifyRelated={business {check(valid());relatedAvailable()}})
        groupAvatarEditor?.foreground(foreground)
    }
    private fun closeGroupAvatarEditor() { groupAvatarRelated=null;if(avatarResourcePicker?.targetRoom!=null) closeAvatarResourcePicker();groupAvatarEditor?.close();groupAvatarEditor=null;mutableState.update { it.copy(groupAvatarEditor=null) } }
    fun beginGroupAvatarPick(id: String)=groupAvatarEditor?.takeIf { it.id==id }?.beginPick() ?: false
    fun groupAvatarPicked(id: String,uri: android.net.Uri?) { groupAvatarEditor?.takeIf { it.id==id }?.picked(uri) }
    fun groupAvatarPickerFailed(id: String) { groupAvatarEditor?.takeIf { it.id==id }?.pickerFailed() }
    fun groupAvatarCropOpened(id: String) { groupAvatarEditor?.takeIf { it.id==id }?.cropOpened() }
    fun changeGroupAvatarCrop(id: String,value: AvatarCrop) { groupAvatarEditor?.takeIf { it.id==id }?.changeCrop(value) }
    fun clearGroupAvatarPhoto(id: String) { groupAvatarEditor?.takeIf { it.id==id }?.clearPhoto() }
    fun saveGroupAvatar(id: String,remove: Boolean=false) { groupAvatarEditor?.takeIf { it.id==id }?.save(remove) }
    fun refreshGroupAvatar(id: String) { groupAvatarEditor?.takeIf { it.id==id }?.let { editor -> editor.refresh();val groups=groupAvatarRepository;viewModelScope.launch { groups?.invalidate(editor.room) } } }
    internal fun groupAvatarAction(id: String,intent: String,action: GroupAvatarTaskAction) { groupAvatarEditor?.takeIf { it.id==id }?.action(intent,action) }

    fun activateAvatarEditor(id: String?) {
        if(cleared || avatarEditor?.id==id && id!=null) return
        closeAvatarEditor()
        val session=state.value.session as? SessionUi.SignedIn ?: return
        if(id==null) return
        mutableState.update { it.copy(avatarEditor=AvatarEditorState(id)) }
        if(session.demo) return
        val store=local ?: return;val resources=resourceActivity ?: return;val service=profileIntents ?: return
        fun valid()=!cleared && foreground && local===store && state.value.session==session && avatarEditor?.id==id
        val processor=PhotoPreparation()
        avatarEditor=AvatarEditorController(id,session.user,viewModelScope,
            refreshProfile={ if(valid()) refreshOwnProfile() else null },
            readPhoto={ processor.prepare(getApplication<Application>().contentResolver,it) },
            cropPhoto={ photo,crop -> processor.crop(photo,crop) },
            submit={ baseline,photo -> business {
                check(valid() && baseline.user==session.user)
                var asset: ResourceLocalAsset?=null
                try {
                    asset=photo?.let { resources.files.importPhoto(it,ResourceUsage.UserAvatar) }
                    currentCoroutineContext().ensureActive();check(valid())
                    val upload=asset?.let { ProfileAvatarUpload(UUID.randomUUID().toString().uppercase(),it.id,it.displayName,it.contentType,it.byteCount) }
                    val intent=service.enqueue(baseline,avatar=if(upload==null) ProfileAvatarPatch.Remove else ProfileAvatarPatch.Unchanged,upload=upload)
                    currentCoroutineContext().ensureActive();if(valid()) publishLocal();intent.id
                } finally { asset?.let { original -> withContext(NonCancellable) { resources.files.discardSelection(original.id);resources.files.cleanup() } } }
            } },
            resume={ intent -> business { check(valid());service.resumeOrReapply(intent);currentCoroutineContext().ensureActive();if(valid()) publishLocal() } },
            discard={ intent -> business { check(valid());service.discard(intent);currentCoroutineContext().ensureActive();if(valid()) publishLocal() } },
            publish={ value -> if(!cleared && local===store && state.value.session==session && avatarEditor?.id==id) mutableState.update { it.copy(avatarEditor=value) } },
            createCamera={ CameraCaptureFiles.create(getApplication<Application>()) })
        avatarEditor?.foreground(foreground)
    }
    private fun closeAvatarEditor() { if(avatarResourcePicker?.targetRoom==null) closeAvatarResourcePicker();avatarEditor?.close();avatarEditor=null;mutableState.update { it.copy(avatarEditor=null) } }
    fun hasChatComposer()=chatComposers!=null
    fun activateChatComposer(room: RoomId?,asset: String?=null) { chatComposers?.activate(room,asset) }
    fun retryDraftImage(selection: DraftImageSelection) { chatComposers?.retryImage(selection) }
    fun moveChatAttachment(id: String,asset: String,offset: Int) { chatComposers?.move(id,asset,offset) }
    fun editChatContent(id: String,text: String,rich: MessageRichContent) {
        val before = state.value.chatComposer?.text
        chatComposers?.editContent(id,text,rich)
        if (before != text) publishTypingEdit(id,text)
    }
    fun setChatMentions(id: String,input: String) {chatComposers?.mentions(id,input)}
    private var replyGeneration=0L
    fun replyChatDraft(id: String,message: MessageId?) {
        val generation=++replyGeneration
        val session=state.value.session as? SessionUi.SignedIn ?: return
        val draft=state.value.chatComposer?.takeIf {it.id==id && it.room !in state.value.snapshot.revokedRooms} ?: return
        val composer=chatComposers ?: return
        if(message==null) {composer.reply(id,null);return}
        viewModelScope.launch { business {
            try {
                val source=operationSource(session,draft.room,message) ?: error("原消息当前不可回复")
                if(generation==replyGeneration && chatComposers===composer && state.value.chatComposer?.id==id) composer.reply(id,source)
            } catch(e: CancellationException) {throw e}
            catch(e: Exception) {if(generation==replyGeneration && state.value.chatComposer?.id==id && state.value.session==session) mutableState.update {it.copy(error=message(e))}}
        } }
    }
    fun editChatDraft(id: String,text: String) {
        val before = state.value.chatComposer?.text
        chatComposers?.edit(id,text)
        if (before != text) publishTypingEdit(id,text)
    }
    private fun publishTypingEdit(id: String, text: String) {
        val draft = state.value.chatComposer ?: return
        if (draft.id == id && draft.room == activityRoom && !draft.sending && draft.text == text && foreground) {
            refreshConversationActivity()
            conversationActivity?.updateTyping(text)
        }
    }
    fun beginChatPhoto(id: String)=chatComposers?.beginPick(id)==true
    fun pickedChatPhoto(id: String,uri: android.net.Uri?) { chatComposers?.picked(id,uri) }
    fun pickedChatPhotos(id: String,uris: List<android.net.Uri>) { chatComposers?.pickedPhotos(id,uris) }
    fun beginChatDocument(id: String)=chatComposers?.beginDocument(id)==true
    fun pickedChatDocument(id: String,uri: android.net.Uri?) { chatComposers?.documentPicked(id,uri) }
    fun takeChatPicture(id: String,launch: (android.net.Uri)->Unit) { chatComposers?.takePicture(id,launch) }
    fun capturedChatPicture(id: String,success: Boolean) { chatComposers?.captured(id,success) }
    fun chatPhotoFailed(id: String) { chatComposers?.pickerFailed(id) }
    fun removeChatAttachment(id: String,asset: String) { chatComposers?.remove(id,asset) }
    fun sendChatDraft(id: String) { chatComposers?.send(id) }
    fun retryChatDraft(id: String) { chatComposers?.retry(id) }
    fun retryAttachmentSend(room: RoomId,id: String)=viewModelScope.launch { business {
        val store=local ?: return@business;val service=sendIntents ?: return@business
        val task=store.sendIntents().firstOrNull {it.intent.id==id && it.intent.room==room} ?: return@business
        if(!foreground || room in state.value.snapshot.revokedRooms) return@business
        try {
            if(task.canResumeConfirmation) store.resumeSend(room,task.intent.actor,task.intent.operation,System.currentTimeMillis()) else service.resumeOrReapply(id)
            publishLocal()
        } catch(error: CancellationException) { throw error } catch(error: Exception) { mutableState.update { it.copy(error=message(error)) } }
    } }
    fun discardAttachmentSend(room: RoomId,id: String)=viewModelScope.launch { business {
        val store=local ?: return@business;val service=sendIntents ?: return@business
        if(store.sendIntents().none { it.intent.id==id && it.intent.room==room }) return@business
        try { service.discard(id);publishLocal() } catch(error: CancellationException) { throw error } catch(error: Exception) { mutableState.update { it.copy(error=message(error)) } }
    } }
    fun activateChatImages(room: RoomId?) {
        if(cleared || room!=null && chatImages?.room==room) return
        closeChatImages()
        if(room==null) return
        val session=state.value.session as? SessionUi.SignedIn ?: return
        if(session.demo) return
        val store=local ?: return;val previews=messagePreviews ?: return
        fun valid()=!cleared && foreground && local===store && state.value.session==session && chatImages?.room==room
        chatImages=ChatImagesController(room,viewModelScope,store.resourceDirectoryChanges,
            generation={ business { check(valid());store.resourceReadGeneration() } },
            read={ request -> business {
                check(valid());previews.read(request.selection.key,MediaImagePreviewSize.Large,request.selection.location).also { currentCoroutineContext().ensureActive();check(valid()) }
            } },publish={ value -> if(!cleared && local===store && state.value.session==session && chatImages?.room==room) mutableState.update { it.copy(chatImages=value) } })
        chatImages?.foreground(foreground)
    }
    private fun closeChatImages() { chatImages?.close();chatImages=null;mutableState.update { it.copy(chatImages=null) } }
    fun visibleChatImages(room: RoomId,requests: PersistentList<ChatImageRequest>) { chatImages?.takeIf { it.room==room }?.visible(requests) }
    fun retryChatImage(request: ChatImageRequest) { chatImages?.takeIf { it.room==request.selection.location.room }?.retry(request) }
    fun activateMessageImage(selection: MessageImageSelection?) {
        if(cleared || selection!=null && messageImage?.selection==selection) return
        closeMessageImage()
        if(selection==null) return
        mutableState.update { it.copy(messageImage=MessageImageState(selection)) }
        val session=state.value.session as? SessionUi.SignedIn ?: return
        if(session.demo) return
        val store=local ?: return;val previews=messagePreviews ?: return;val originals=messageOriginals ?: return
        fun valid()=!cleared && foreground && local===store && state.value.session==session && messageImage?.selection==selection
        val processor=MessageImagePreparation()
        messageImage=MessageImageController(selection,viewModelScope,store.resourceDirectoryChanges,
            generation={ business { check(valid());store.resourceReadGeneration() } },
            read={ original -> business {
                check(valid())
                val result=if(original) requireNotNull(originals.withAuthorizedOriginal(selection.key,message=selection.location) { authorized,file ->
                    val photo=processor.prepare(file)
                    MessageImageFrame(authorized.evidence,photo.data,authorized.deadlineNanos,true)
                }) else previews.read(selection.key,MediaImagePreviewSize.Large,selection.location).let { MessageImageFrame(it.read,it.encoded,it.deadlineNanos,false) }
                currentCoroutineContext().ensureActive();check(valid());result
            } },publish={ value -> if(!cleared && local===store && state.value.session==session && messageImage?.selection==selection) mutableState.update { it.copy(messageImage=value) } })
        messageImage?.foreground(foreground)
    }
    private fun closeMessageImage() { messageImage?.close();messageImage=null;mutableState.update { it.copy(messageImage=null) } }
    fun retryMessageImage(selection: MessageImageSelection) { messageImage?.takeIf { it.selection==selection }?.retry() }
    fun loadOriginalImage(selection: MessageImageSelection) { messageImage?.takeIf { it.selection==selection }?.load(true) }
    fun activateMessagePlayback(selection: MessagePlaybackSelection?) {
        if(cleared || selection!=null && messagePlayback?.selection==selection) return
        closeMessagePlayback()
        if(selection==null) return
        mutableState.update {it.copy(messagePlayback=MessagePlaybackState(selection))}
        val session=state.value.session as? SessionUi.SignedIn ?: return
        if(session.demo) return
        val store=local ?: return;val originals=messageOriginals ?: return
        lateinit var controller:MessagePlaybackController
        fun valid()=!cleared && foreground && local===store && state.value.session==session && messagePlayback===controller
        controller=MessagePlaybackController(selection,viewModelScope,store.resourceDirectoryChanges,
            resolve={business {check(valid());store.selectMessageResource(selection.key,selection.location).also {check(valid())}}},
            borrow={expected,consume->business {
                check(valid());requireNotNull(originals.withAuthorizedOriginal(selection.key,message=selection.location) {authorized,file->
                    check(authorized.evidence==expected);consume(authorized,file)
                })
            }},createPlayer={createMessagePlayer(getApplication())},publish={value->
                if(!cleared && local===store && state.value.session==session && messagePlayback===controller) mutableState.update {it.copy(messagePlayback=value)}
            })
        messagePlayback=controller;controller.foreground(foreground)
    }
    private fun closeMessagePlayback() {
        val current=messagePlayback;messagePlayback=null;mutableState.update {it.copy(messagePlayback=null)}
        if(current!=null) {
            current.close();closingPlaybacks.add(current)
            viewModelScope.launch {current.awaitClosed();closingPlaybacks.remove(current)}
        }
    }
    internal fun playbackPlayer(selection: MessagePlaybackSelection,owner: String)=messagePlayback?.takeIf {it.selection==selection && it.id==owner}?.renderPlayer()
    fun togglePlayback(selection: MessagePlaybackSelection) {messagePlayback?.takeIf {it.selection==selection}?.toggle()}
    fun seekPlayback(selection: MessagePlaybackSelection,position: Long) {messagePlayback?.takeIf {it.selection==selection}?.seek(position)}
    fun retryPlayback(selection: MessagePlaybackSelection) {messagePlayback?.takeIf {it.selection==selection}?.retry()}
    fun activateMessageFile(selection: MessageFileSelection?) {
        if(cleared || selection!=null && messageFile?.selection==selection) return
        closeMessageFile()
        if(selection==null) return
        mutableState.update { it.copy(messageFile=MessageFileState(selection)) }
        val session=state.value.session as? SessionUi.SignedIn ?: return
        if(session.demo) return
        val store=local ?: return;val originals=messageOriginals ?: return;val temporary=temporaryFiles ?: return
        lateinit var controller:MessageFileController
        fun valid()=!cleared && foreground && local===store && state.value.session==session && messageFile===controller
        controller=MessageFileController(selection,viewModelScope,store.resourceDirectoryChanges,
            resolve={ business { check(valid());store.selectMessageResource(selection.key,selection.location).also { check(valid()) } } },
            save={ request,uri -> business {
                check(valid())
                requireNotNull(originals.withAuthorizedOriginal(selection.key,message=selection.location) { authorized,file ->
                    check(authorized.evidence==request.read)
                    DocumentExport.copy(getApplication<Application>().contentResolver,uri,file,request.read.descriptor,authorized.deadlineNanos) {
                        if(!valid() || !store.isMessageResourceCurrent(request.read)) throw MediaReadFailure(MediaReadFailureReason.SourceChanged)
                    }
                })
                currentCoroutineContext().ensureActive();check(valid())
            } },discard={ DocumentExport.discard(getApplication(),it) },publish={ value ->
                if(!cleared && local===store && state.value.session==session && messageFile===controller) mutableState.update { it.copy(messageFile=value) }
            },prepare={ request -> business {
                var lease:TemporaryResourceLease?=null
                try {
                    check(valid())
                    originals.withAuthorizedOriginal(selection.key,message=selection.location) { authorized,file ->
                        check(authorized.evidence==request.read);lease=temporary.prepare(authorized,file)
                    }
                    currentCoroutineContext().ensureActive();check(valid());requireNotNull(lease)
                } catch(error: Throwable) { lease?.release();throw error }
            } })
        messageFile=controller;controller.foreground(foreground)
    }
    private fun closeMessageFile() {
        val current=messageFile;messageFile=null;mutableState.update { it.copy(messageFile=null) }
        if(current!=null) {
            current.close();closingMessageFiles.add(current)
            viewModelScope.launch { current.awaitClosed();closingMessageFiles.remove(current) }
        }
    }
    fun beginFileSave(selection: MessageFileSelection): String?=messageFile?.takeIf { it.selection==selection }?.begin()
    fun fileSaveResult(selection: MessageFileSelection,id: String,uri: android.net.Uri?) {
        val current=messageFile?.takeIf { it.selection==selection && it.accepts(id) }
        if(current!=null) current.result(id,uri)
        else if(uri!=null) viewModelScope.launch(start=CoroutineStart.UNDISPATCHED) { DocumentExport.discard(getApplication(),uri) }
    }
    fun filePickerFailed(selection: MessageFileSelection,id: String) { messageFile?.takeIf { it.selection==selection }?.pickerFailed(id) }
    fun retryMessageFile(selection: MessageFileSelection) { messageFile?.takeIf { it.selection==selection }?.retry() }
    fun fileOpenFailed(selection: MessageFileSelection) { messageFile?.takeIf { it.selection==selection }?.openFailed() }
    fun presentMessageFile(selection: MessageFileSelection,mode: TemporaryFileMode) { messageFile?.takeIf { it.selection==selection }?.present(mode) }
    suspend fun claimFilePresentation(selection: MessageFileSelection,id: String)=messageFile?.takeIf { it.selection==selection }?.claimPresentation(id) ?: false
    fun filePresentationLaunched(selection: MessageFileSelection,id: String) { messageFile?.takeIf { it.selection==selection }?.presentationLaunched(id) }
    fun filePresentationReturned(selection: MessageFileSelection,id: String) { messageFile?.takeIf { it.selection==selection }?.presentationReturned(id) }
    fun filePresentationFailed(selection: MessageFileSelection,id: String) { messageFile?.takeIf { it.selection==selection }?.presentationFailed(id) }
    fun activateResourceBusiness(selection:ResourceBusinessSelection?) {
        if(cleared || resourceBusiness?.selection==selection && selection!=null) return
        resourceBusiness?.close();resourceBusiness=null;mutableState.update {it.copy(resourceBusiness=selection?.let(::ResourceBusinessState))}
        val session=state.value.session as? SessionUi.SignedIn ?: return
        val store=local ?: return
        if(selection==null || session.demo) return
        fun valid()=!cleared && foreground && local===store && state.value.session==session && resourceBusiness?.selection==selection
        resourceBusiness=ResourceBusinessController(selection,viewModelScope,store.resourceBusinessOwnerChanges,
            read={q->business {check(valid());store.resourceBusinessOwners(q).also {currentCoroutineContext().ensureActive();check(valid())}}},
            contains={owner->business {check(valid());store.resourceHasBusinessOwner(selection.transfer,owner).also {currentCoroutineContext().ensureActive();check(valid())}}},
            profile={business {check(valid());store.resourceProfileIntent(selection.transfer,requireNotNull(selection.profile)).also {currentCoroutineContext().ensureActive();check(valid())}}},
            resumeProfile={business {
                check(valid());val id=requireNotNull(selection.profile);check(store.resourceHasBusinessOwner(selection.transfer,ResourceBusinessOwner.Profile(id)))
                val next=requireNotNull(profileIntents).resumeOrReapply(id);currentCoroutineContext().ensureActive();check(valid())
                publishLocal();ResourceBusinessOwner.Profile(next.id).takeIf {store.resourceHasBusinessOwner(selection.transfer,it)}
            }},
            preview={business {check(valid());store.planResourceProfileDisposition(selection.transfer,requireNotNull(selection.profile)).also {currentCoroutineContext().ensureActive();check(valid())}}},
            dispose={plan->business {check(valid());store.commitResourceProfileDisposition(plan);currentCoroutineContext().ensureActive();if(valid()) publishLocal()}},
            publish={value->if(!cleared && local===store && state.value.session==session && resourceBusiness?.selection==selection) mutableState.update {it.copy(resourceBusiness=value)}})
        resourceBusiness?.foreground(foreground)
    }
    fun pageResourceBusiness(next:Boolean) {resourceBusiness?.page(next)}
    fun reloadResourceBusiness() {resourceBusiness?.reload()}
    fun openResourceBusiness(owner:ResourceBusinessOwner) {resourceBusiness?.open(owner)}
    fun consumeResourceBusinessOpen() {resourceBusiness?.opened()}
    fun resumeResourceProfile() {resourceBusiness?.resume()}
    fun reviewResourceProfile() {resourceBusiness?.review()}
    fun confirmResourceProfile() {resourceBusiness?.confirm()}
    fun dismissResourceProfile() {resourceBusiness?.dismiss()}
    fun activateResourceManagement(library:Boolean,key:ResourceKey?,downloads:Boolean=false,retentionRelease:Boolean=false,storage:Boolean=false,transfers:Boolean=false) {
        if(cleared) return
        resourceLibraryVisible=library
        transferTasksVisible=transfers
        downloadTasksVisible=downloads
        unavailableRetentionVisible=retentionRelease
        resourceStorageVisible=storage
        val session=state.value.session as? SessionUi.SignedIn ?: return
        val store=local
        val files=resourceActivity?.files
        if(!session.demo && store!=null && files!=null && library && resourceLibrary==null) {
            fun valid()=!cleared && foreground && local===store && resourceActivity?.files===files && state.value.session==session
            resourceLibrary=ResourceLibraryController(viewModelScope,store.resourceDirectoryChanges,
                directory={query->business {check(foreground && local===store && state.value.session==session);store.resourceDirectory(query)}},
                publish={value->if(!cleared && local===store && state.value.session==session) mutableState.update {it.copy(resourceLibrary=value)}},
                preview={keys->business {check(valid());files.planSelectedCacheCleanup(keys).also {currentCoroutineContext().ensureActive();check(valid())}}},
                commit={plan->business {check(valid());files.commitCacheCleanup(plan)}},
                retain={keys,value->business {check(valid());files.setResourcesRetained(keys,value)}})
        }
        resourceLibrary?.foreground(library && foreground)
        if(!session.demo && store!=null && transfers && transferTasks==null) {
            fun valid()=!cleared && foreground && local===store && state.value.session==session
            transferTasks=ResourceTransfersController(viewModelScope,store.resourceTransferChanges,
                observations=resourceActivity?.transferWaiting?.snapshots ?: kotlinx.coroutines.flow.MutableStateFlow(ResourceTransferObservations()),
                read={query->business {check(valid());store.resourceTransfers(query).also {currentCoroutineContext().ensureActive();check(valid())}}},
                control={id,action->business {check(valid());store.controlResourceTransfer(id,action)}},
                batch={ids,action->business {check(valid());store.retryResourceTransfers(ids,action)}},
                publish={value->if(!cleared && local===store && state.value.session==session) mutableState.update {it.copy(resourceTransfers=value)}},
                previewPreparation={id->business {check(valid());store.planResourcePreparationCancellation(id).also {currentCoroutineContext().ensureActive();check(valid())}}},
                cancelPreparation={plan->business {check(valid());store.cancelResourcePreparation(plan)}},
                previewUnbound={id->business {check(valid());store.planUnboundResourceCancellation(id).also {currentCoroutineContext().ensureActive();check(valid())}}},
                cancelUnbound={plan->business {check(valid());store.cancelUnboundResource(plan)}})
        }
        transferTasks?.foreground(transfers && foreground)
        if(!session.demo && store!=null && downloads && downloadTasks==null) {
            fun valid()=!cleared && foreground && local===store && state.value.session==session
            downloadTasks=ResourceDownloadsController(viewModelScope,store.resourceDownloadChanges,
                read={business {check(valid());store.resourceDownloads().also {currentCoroutineContext().ensureActive();check(valid())}}},
                control={id,value->business {check(valid());store.controlResourceDownload(id,value)}},
                publish={value->if(!cleared && local===store && state.value.session==session) mutableState.update {it.copy(resourceDownloads=value)}},
                readNetwork={business {check(valid());store.downloadNetworkPreferences().also {currentCoroutineContext().ensureActive();check(valid())}}},
                writeNetwork={value->business {check(valid());store.setDownloadNetworkPreferences(value)}})
        }
        downloadTasks?.foreground(downloads && foreground)
        if(!session.demo && store!=null && files!=null && retentionRelease && unavailableRetention==null) {
            fun valid()=!cleared && foreground && local===store && resourceActivity?.files===files && state.value.session==session
            unavailableRetention=UnavailableRetentionController(viewModelScope,
                preview={business {check(valid());files.planUnavailableRetentionRelease().also {currentCoroutineContext().ensureActive();check(valid())}}},
                commit={plan->business {check(valid());files.releaseUnavailableRetention(plan)}},
                publish={value->if(!cleared && local===store && state.value.session==session) mutableState.update {it.copy(unavailableRetention=value)}})
        }
        unavailableRetention?.foreground(retentionRelease && foreground)
        if(!session.demo && store!=null && files!=null && storage && resourceStorage==null) {
            fun valid()=!cleared && foreground && local===store && resourceActivity?.files===files && state.value.session==session
            resourceStorage=ResourceStorageController(viewModelScope,
                read={business {check(valid());files.storageSnapshot().also {currentCoroutineContext().ensureActive();check(valid())}}},
                write={bytes->business {check(valid());files.setCacheLimit(bytes)}},
                writeManaged={bytes->business {check(valid());files.setManagedLimit(bytes)}},
                preview={business {check(valid());files.planCacheCleanup().also {currentCoroutineContext().ensureActive();check(valid())}}},
                commit={plan->business {check(valid());files.commitCacheCleanup(plan)}},
                publish={value->if(!cleared && local===store && state.value.session==session) mutableState.update {it.copy(resourceStorage=value)}})
        }
        resourceStorage?.foreground(storage && foreground)
        if(resourceDetail?.key==key) return
        resourceDetail?.close();resourceDetail=null;mutableState.update {it.copy(resourceDetail=key?.let(::ResourceDetailState))}
        if(key==null || session.demo || store==null || files==null) return
        fun valid()=!cleared && foreground && local===store && state.value.session==session && resourceDetail?.key==key
        resourceDetail=ResourceDetailController(key,viewModelScope,store.resourceDirectoryChanges,
            details={value,before->business {check(valid());store.resourceDetails(value,before).also {currentCoroutineContext().ensureActive();check(valid())}}},
            retain={variant,value->business {check(valid());files.setResourceRetained(variant,value)}},
            publish={value->if(!cleared && local===store && state.value.session==session && resourceDetail?.key==key) mutableState.update {it.copy(resourceDetail=value)}},
            enqueue={value,source->business {check(valid());store.enqueueResourceDownload(value,source).id}})
        resourceDetail?.foreground(foreground)
    }
    private fun closeResourceManagement() {
        resourceBusiness?.close();resourceBusiness=null;mutableState.update {it.copy(resourceBusiness=null)}
        resourceLibraryVisible=false;resourceLibrary?.close();resourceLibrary=null;resourceDetail?.close();resourceDetail=null
        transferTasksVisible=false;transferTasks?.close();transferTasks=null
        downloadTasksVisible=false;downloadTasks?.close();downloadTasks=null
        unavailableRetentionVisible=false;unavailableRetention?.close();unavailableRetention=null
        resourceStorageVisible=false;resourceStorage?.close();resourceStorage=null
        mutableState.update {it.copy(resourceLibrary=ResourceLibraryState(),resourceDetail=null,resourceTransfers=ResourceTransfersState(),resourceDownloads=ResourceDownloadsState(),unavailableRetention=UnavailableRetentionState(),resourceStorage=ResourceStorageState())}
    }
    fun queryResourceLibrary(text:String,category:ResourceCategory,retained:Boolean) {resourceLibrary?.query(text,category,retained)}
    fun pageResourceLibrary(next:Boolean) {resourceLibrary?.page(next)}
    fun reloadResourceLibrary() {resourceLibrary?.reload()}
    fun toggleResourceSelection() {resourceLibrary?.toggleSelection()}
    fun selectResource(key:ResourceKey) {resourceLibrary?.select(key)}
    fun selectResourcePage() {resourceLibrary?.selectPage()}
    fun previewSelectedResourceCleanup() {resourceLibrary?.previewSelection()}
    fun confirmSelectedResourceCleanup() {resourceLibrary?.confirmSelection()}
    fun dismissSelectedResourceCleanup() {resourceLibrary?.dismissSelection()}
    fun retainSelectedResources(value:Boolean) {resourceLibrary?.retainSelection(value)}
    fun retainResource(key:ResourceKey,value:Boolean) {resourceDetail?.takeIf {it.key==key}?.setRetained(value)}
    fun pageResourceSources(key:ResourceKey,next:Boolean) {resourceDetail?.takeIf {it.key==key}?.page(next)}
    fun reloadResourceDetails(key:ResourceKey) {resourceDetail?.takeIf {it.key==key}?.reload()}
    fun downloadResource(key:ResourceKey) {resourceDetail?.takeIf {it.key==key}?.download()}
    fun startResourceBackground() {
        val session=state.value.session as? SessionUi.SignedIn ?: return
        if(cleared || !foreground || session.demo) return
        resourceBackground?.let {ResourceBackgroundSessions.start(getApplication(),it)}
    }
    fun stopResourceBackground() {resourceBackground?.stop()}
    fun queryTransfers(group:ResourceTransferGroup) {transferTasks?.query(group)}
    fun pageTransfers(next:Boolean) {transferTasks?.page(next)}
    fun reloadTransfers() {transferTasks?.reload()}
    fun controlTransfer(id:ResourceTransferId,action:ResourceTransferAction) {transferTasks?.act(id,action)}
    fun selectTransfers() {transferTasks?.selectMode()}
    fun selectTransfer(id:ResourceTransferId) {transferTasks?.select(id)}
    fun selectTransferPage() {transferTasks?.selectPage()}
    fun retryTransfers(action:ResourceTransferAction) {transferTasks?.retry(action)}
    fun confirmTransferCancellation() {transferTasks?.confirm()}
    fun dismissTransferCancellation() {transferTasks?.dismiss()}
    fun controlDownload(id:String,control:ResourceDownloadControl) {downloadTasks?.act(id,control)}
    fun reloadDownloads() {downloadTasks?.reload()}
    fun setDownloadNetwork(value:ResourceDownloadNetworkPreferences) {downloadTasks?.network(value)}
    fun previewUnavailableRetention() {unavailableRetention?.prepare()}
    fun releaseUnavailableRetention() {unavailableRetention?.confirm()}
    fun dismissUnavailableRetention() {unavailableRetention?.dismiss()}
    fun refreshResourceStorage() {resourceStorage?.refresh()}
    fun setResourceCacheLimit(bytes:Long) {resourceStorage?.cacheLimit(bytes)}
    fun setResourceManagedLimit(bytes:Long?) {resourceStorage?.managedLimit(bytes)}
    fun previewResourceCacheCleanup() {resourceStorage?.prepareCleanup()}
    fun confirmResourceCacheCleanup() {resourceStorage?.confirmCleanup()}
    fun dismissResourceCacheCleanup() {resourceStorage?.dismissCleanup()}

    fun activateConversationResources(id: String?,room: RoomId?) {
        if(cleared || id!=null && conversationResourcePicker?.id==id && conversationResourcePicker?.room==room) return
        closeConversationResources();if(id==null || room==null) return
        val session=state.value.session as? SessionUi.SignedIn ?: return
        mutableState.update {it.copy(conversationResources=ConversationResourcePickerState(id,room))}
        if(session.demo) return
        val store=local ?: return;val composers=chatComposers ?: return
        fun valid()=!cleared && foreground && local===store && state.value.session==session && conversationResourcePicker?.id==id && room !in state.value.snapshot.revokedRooms
        conversationResourcePicker=ConversationResourcePickerController(id,room,viewModelScope,store.resourceDirectoryChanges,
            directory={query->business {check(valid());store.resourceDirectory(query).also {currentCoroutineContext().ensureActive();check(valid())}}},
            select={key->business {check(valid());store.selectConversationResource(key).also {currentCoroutineContext().ensureActive();check(valid())}}},
            current={selection->business {check(valid());store.isConversationResourceCurrent(selection)}},
            add={selection->business {check(valid());val editor=requireNotNull(state.value.chatComposer?.takeIf {it.room==room});composers.addImported(editor.id,selection)}},
            publish={value->if(!cleared && local===store && state.value.session==session && conversationResourcePicker?.id==id) mutableState.update {it.copy(conversationResources=value)}})
        conversationResourcePicker?.foreground(foreground)
    }
    private fun closeConversationResources() {conversationResourcePicker?.close();conversationResourcePicker=null;mutableState.update {it.copy(conversationResources=null)}}
    fun searchConversationResources(id: String,text: String,category: ResourceCategory) {conversationResourcePicker?.takeIf {it.id==id}?.search(text,category)}
    fun pageConversationResources(id: String,next: Boolean) {conversationResourcePicker?.takeIf {it.id==id}?.page(next)}
    fun reloadConversationResources(id: String) {conversationResourcePicker?.takeIf {it.id==id}?.reload()}
    fun chooseConversationResource(id: String,key: ResourceKey) {conversationResourcePicker?.takeIf {it.id==id}?.choose(key)}
    fun confirmConversationResource(id: String) {conversationResourcePicker?.takeIf {it.id==id}?.confirm()}
    fun dismissConversationResource(id: String) {conversationResourcePicker?.takeIf {it.id==id}?.dismiss()}
    fun activateAvatarResourcePicker(id: String?,room: RoomId?=null) {
        if(cleared || id!=null && avatarResourcePicker?.id==id && avatarResourcePicker?.targetRoom==room) return
        closeAvatarResourcePicker()
        val session=state.value.session as? SessionUi.SignedIn ?: return
        if(id==null) return
        mutableState.update { it.copy(avatarResources=AvatarResourcePickerState(id,targetRoom=room)) }
        if(session.demo) return
        val store=local ?: return
        val service=AvatarResourceSelectionService(session.user,store)
        val device=deviceOwner?.takeIf { it.first==session.user }?.second ?: return
        val groups=groupAvatarIntents
        if(room!=null && groups==null) return
        val groupSelection=GroupAvatarResourceSelectionService(session.user,device,store)
        val previews=messagePreviews
        fun valid()=!cleared && foreground && local===store && state.value.session==session && avatarResourcePicker?.id==id && avatarResourcePicker?.targetRoom==room &&
            (if(room==null) avatarEditor?.id==id else groupAvatarEditor?.id==id && groupAvatarEditor?.room==room)
        avatarResourcePicker=AvatarResourcePickerController(id,session.user,viewModelScope,store.resourceDirectoryChanges,
            directory={ query -> business { check(valid());store.resourceDirectory(query).also { currentCoroutineContext().ensureActive();check(valid()) } } },
            select={ key -> business { check(valid());service.select(key).also { currentCoroutineContext().ensureActive();check(valid()) } } },
            current={ selected -> business { check(valid());service.isCurrent(selected).also { currentCoroutineContext().ensureActive();check(valid()) } } },
            refreshProfile={ if(valid()) refreshOwnProfile() else null },
            submit={ baseline,selection -> business {
                check(valid());val intent=service.submit(baseline,selection);currentCoroutineContext().ensureActive()
                if(valid()) { publishLocal();avatarEditor?.resourceSubmitted(intent.id) };intent.id
            } },publish={ value -> if(!cleared && local===store && state.value.session==session && avatarResourcePicker?.id==id) mutableState.update { it.copy(avatarResources=value) } },
            preview=previews?.let { cache -> { key -> business { check(valid());cache.read(key).also { currentCoroutineContext().ensureActive();check(valid()) } } } },
            previewGeneration={ business { check(valid());store.resourceReadGeneration() } },targetRoom=room,
            refreshGroup=room?.let { target -> { business { check(valid());requireNotNull(groups).refresh(target).also { currentCoroutineContext().ensureActive();check(valid()) } } } },
            submitGroup=room?.let { target -> { baseline,selection -> business {
                check(valid());val authority=requireNotNull(groups).refresh(target);currentCoroutineContext().ensureActive();check(valid())
                require(authority.presentation.state.revision==baseline.presentation.state.revision && authority.fence==baseline.fence)
                val intent=groupSelection.submit(authority,selection);currentCoroutineContext().ensureActive()
                if(valid()) { publishLocal();groupAvatarEditor?.resourceSubmitted(intent.id) };intent.id
            } } })
        avatarResourcePicker?.foreground(foreground)
    }
    private fun closeAvatarResourcePicker() { avatarResourcePicker?.close();avatarResourcePicker=null;mutableState.update { it.copy(avatarResources=null) } }
    fun visibleAvatarResources(id: String,keys: kotlinx.collections.immutable.PersistentList<ResourceKey>) { avatarResourcePicker?.takeIf { it.id==id }?.visible(keys) }
    fun searchAvatarResources(id: String,value: String) { avatarResourcePicker?.takeIf { it.id==id }?.search(value) }
    fun nextAvatarResources(id: String) { avatarResourcePicker?.takeIf { it.id==id }?.next() }
    fun previousAvatarResources(id: String) { avatarResourcePicker?.takeIf { it.id==id }?.previous() }
    fun reloadAvatarResources(id: String) { avatarResourcePicker?.takeIf { it.id==id }?.reload() }
    fun chooseAvatarResource(id: String,key: ResourceKey) { avatarResourcePicker?.takeIf { it.id==id }?.choose(key) }
    fun refreshAvatarResourceProfile(id: String) { avatarResourcePicker?.takeIf { it.id==id }?.refresh() }
    fun confirmAvatarResource(id: String) { avatarResourcePicker?.takeIf { it.id==id }?.confirm() }
    fun dismissAvatarResource(id: String) { avatarResourcePicker?.takeIf { it.id==id }?.dismiss() }
    fun beginAvatarPick(id: String)=avatarEditor?.takeIf { it.id==id }?.beginPick() ?: false
    fun avatarPicked(id: String,uri: android.net.Uri?) { avatarEditor?.takeIf { it.id==id }?.picked(uri) }
    fun avatarPickerFailed(id: String) { avatarEditor?.takeIf { it.id==id }?.pickerFailed() }
    fun takeAvatarPicture(id: String,launch: (android.net.Uri)->Unit) { avatarEditor?.takeIf { it.id==id }?.takePicture(launch) }
    fun avatarPictureTaken(id: String,success: Boolean) { avatarEditor?.takeIf { it.id==id }?.captured(success) }
    fun avatarCropOpened(id: String) { avatarEditor?.takeIf { it.id==id }?.cropOpened() }
    fun changeAvatarCrop(id: String,value: AvatarCrop) { avatarEditor?.takeIf { it.id==id }?.crop(value) }
    fun clearAvatarPhoto(id: String) { avatarEditor?.takeIf { it.id==id }?.clearPhoto() }
    fun saveAvatar(id: String) { avatarEditor?.takeIf { it.id==id }?.save() }
    fun removeAvatar(id: String) { avatarEditor?.takeIf { it.id==id }?.remove() }
    fun refreshAvatarProfile(id: String) { avatarEditor?.takeIf { it.id==id }?.refresh() }
    fun resumeAvatarIntent(id: String,intent: String) { avatarEditor?.takeIf { it.id==id }?.resume(intent) }
    fun discardAvatarIntent(id: String,intent: String) { avatarEditor?.takeIf { it.id==id }?.discard(intent) }

    suspend fun refreshOwnProfile(): ProfileView? = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business null
        val service = ownProfile ?: return@business null
        if(session.demo || !foreground) return@business null
        try {
            val value = service.refresh()
            if(ownProfile !== service || state.value.session != session || !foreground) return@business null
            publishLocal();value
        } catch(e: CancellationException) { throw e } catch(e: Exception) { mutableState.update { it.copy(error = message(e)) };null }
    }
    suspend fun saveOwnProfile(baseline: ProfileView,name: String): Boolean = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business false
        val service = ownProfile ?: return@business false
        if(session.demo || session.user != baseline.user || !foreground) return@business false
        try { service.save(baseline,OwnProfilePatch(OwnProfilePatch.normalizedName(name)));publishLocal();true }
        catch(e: CancellationException) { throw e } catch(e: Exception) { mutableState.update { it.copy(error = message(e)) };false }
    }
    suspend fun retryOwnProfile(id: String) = business {
        try { ownProfile?.retry(id);publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun reapplyOwnProfile(id: String): Boolean = business {
        try { (ownProfile ?: return@business false).reapply(id);publishLocal();true } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) };false }
    }
    suspend fun discardOwnProfile(id: String) = business {
        try { ownProfile?.discardDraft(id);publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun refreshName(target: NameTarget): NameSnapshot? = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business null
        val service = names ?: return@business null
        if(session.demo || !foreground) return@business null
        try {
            val result = service.refresh(target)
            if(names !== service || state.value.session != session || !foreground) return@business null
            publishLocal();result
        } catch(e: CancellationException) { throw e } catch(e: Exception) { mutableState.update { it.copy(error = message(e)) };null }
    }
    suspend fun saveName(baseline: NameSnapshot,name: String?): Boolean = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business false
        val service = names ?: return@business false
        if(session.demo || session.user != baseline.actor || !foreground || (baseline.target as? NameTarget.Group)?.room in state.value.snapshot.revokedRooms) return@business false
        try { service.save(baseline,name);publishLocal();true }
        catch(e: CancellationException) { throw e } catch(e: Exception) { mutableState.update { it.copy(error = message(e)) };false }
    }
    suspend fun retryName(id: String) = business {
        try { names?.retry(id);publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun discardName(id: String) = business {
        try { names?.discard(id);publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun retryPersonal(id: String) = business {
        try { personalPreferences?.retry(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun discardPersonal(id: String) = business {
        try { personalPreferences?.discard(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun refreshPreferences() = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        if(session.demo || state.value.preferenceLoading) return@business
        mutableState.update { it.copy(preferenceLoading = true, error = null) }
        try {
            for(kind in PreferenceKind.entries) { requireNotNull(accountPreferences).baseline(kind); publishLocal() }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
        finally { mutableState.update { it.copy(preferenceLoading = false) } }
    }
    suspend fun changePreference(patch: PreferencePatch) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        val tightening = !session.demo && patch.kind == PreferenceKind.LiveActivity && (patch.first == false || patch.second == false)
        if(tightening) { privacyWrites++;refreshConversationActivity() }
        try {
            if(session.demo) mutableState.update { current -> current.copy(demoPreferences = current.demoPreferences.map { if(it.kind == patch.kind) patch.apply(it) else it }.toPersistentList(), error = null) }
            else { requireNotNull(accountPreferences).enqueue(patch); publishLocal() }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
        finally { if(tightening) { privacyWrites--;refreshConversationActivity() } }
    }
    suspend fun reconfirmPreference(id: String) = business {
        try { accountPreferences?.reconfirm(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun retryPreference(id: String) = business {
        try { accountPreferences?.retry(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun discardPreference(id: String) = business {
        try { accountPreferences?.discard(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun preparePin(room: RoomId, message: MessageId) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        try {
            loadMembers(room)
            val generation = memberGeneration
            val baseline = if(session.demo) PinBaseline(room, message, state.value.snapshot.pins.any { it.room == room && it.message == message },
                state.value.snapshot.pins.filter { it.room == room }.maxOfOrNull { it.sequence } ?: 0) else requireNotNull(capabilityClient).pinBaseline(room, message)
            if(generation != memberGeneration || !foreground) return@business
            prepareCapability(room, GroupAction.Pin(message, !baseline.pinned, baseline.sequence))
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun prepareAnnouncement(room: RoomId, body: String, revision: Long) {
        prepareCapability(room, GroupAction.Announcement(body, revision))
    }
    fun dismissCapabilityPrompt() { mutableState.update { it.copy(capabilityPrompt = null) } }
    private suspend fun validateCapability(directory: MembersState, session: SessionUi.SignedIn, action: GroupAction) {
        check(!directory.stale && !directory.loading && directory.room !in state.value.snapshot.revokedRooms) { "请先刷新群成员与权限" }
        fun target(user: UserId) = user != session.user && directory.items.any { it.user == user && it.role != MemberRole.Owner }
        when(action) {
            is GroupAction.Role -> check(directory.allows(GroupPermission.ChangeRoles) && action.revision == directory.revision && action.role != MemberRole.Owner && target(action.target)) { "当前无法调整该成员角色" }
            is GroupAction.Permissions -> check(directory.allows(GroupPermission.ChangeRoles) && action.revision == directory.policies?.revision && action.role != MemberRole.Owner) { "权限基线已变化，请刷新后重试" }
            is GroupAction.Transfer -> check(directory.actorRole == MemberRole.Owner && action.revision == directory.revision && target(action.target)) { "当前无法转让群主" }
            is GroupAction.Dissolve -> check(directory.actorRole == MemberRole.Owner && action.revision == directory.revision) { "当前无法解散群聊" }
            is GroupAction.Announcement -> check((action.body.isEmpty() || action.body.isNotBlank()) && action.body.toByteArray().size <= 4096 && directory.allows(GroupPermission.Announce) && action.revision == (state.value.snapshot.announcements.firstOrNull { it.room == directory.room }?.revision ?: 0L)) { "公告已变化，请刷新后重新确认" }
            is GroupAction.Pin -> check(directory.allows(GroupPermission.Pin) && operationSource(session,directory.room,action.message)!=null) { "当前无法操作此消息" }
        }
    }
    suspend fun prepareCapability(room: RoomId, action: GroupAction, draft: String? = null) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        try {
            val directory = requireNotNull(state.value.members); check(directory.room == room && foreground)
            validateCapability(directory, session, action)
            check(state.value.members==directory && state.value.session==session && foreground) { "成员或页面已变化，请重新确认" }
            val confirmation = if(session.demo) null else requireNotNull(capabilities).confirmation(room, action)
            mutableState.update { it.copy(capabilityPrompt = CapabilityPrompt(room, action, confirmation, System.nanoTime() + 30_000_000_000, draft), error = null) }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun reconfirmCapability(work: GroupCapabilityWork) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        if(work.intent.actor != session.user) return@business
        val generation = memberGeneration
        val directory = state.value.members ?: return@business
        val revision = directory.revision ?: return@business
        val action = when(val action = work.intent.action) {
            is GroupAction.Role -> action.copy(revision = revision)
            is GroupAction.Permissions -> action.copy(revision = directory.policies?.revision ?: return@business)
            is GroupAction.Transfer -> action.copy(revision = revision)
            is GroupAction.Dissolve -> action.copy(revision = revision)
            is GroupAction.Announcement -> action.copy(revision = state.value.snapshot.announcements.firstOrNull { it.room == work.intent.room }?.revision ?: 0L)
            is GroupAction.Pin -> {
                if(session.demo) action else try { action.copy(revision = requireNotNull(capabilityClient).pinBaseline(work.intent.room, action.message).sequence) }
                catch(e: CancellationException) { throw e } catch(e: Exception) { mutableState.update { it.copy(error = message(e)) }; return@business }
            }
        }
        if(generation != memberGeneration || !foreground) return@business
        prepareCapability(work.intent.room, action, work.intent.operation)
    }
    suspend fun confirmCapability() = business {
        val prompt = state.value.capabilityPrompt ?: return@business
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        dismissCapabilityPrompt()
        try {
            val directory = requireNotNull(state.value.members)
            check(foreground && directory.room == prompt.room && prompt.deadlineNanos - System.nanoTime() > 0) { "确认已过期，请刷新后重试" }
            validateCapability(directory, session, prompt.action)
            check(state.value.members==directory && state.value.session==session && foreground) { "成员或页面已变化，请重新确认" }
            if(session.demo) {
                val next = when(val action = prompt.action) {
                    is GroupAction.Role -> directory.copy(items = directory.items.map { if(it.user == action.target) it.copy(role = action.role) else it }.toPersistentList(), revision = action.revision + 1,
                        policies = directory.policies?.copy(membershipRevision = action.revision + 1))
                    is GroupAction.Permissions -> directory.copy(policies = requireNotNull(directory.policies).let { if(action.role == MemberRole.Admin) it.copy(revision = action.revision + 1, admin = action.permissions) else it.copy(revision = action.revision + 1, member = action.permissions) })
                    is GroupAction.Transfer -> directory.copy(actorRole = MemberRole.Member, revision = action.revision + 1,
                        items = directory.items.map { if(it.user == session.user) it.copy(role = MemberRole.Member) else if(it.user == action.target) it.copy(role = MemberRole.Owner) else it }.toPersistentList(),
                        policies = directory.policies?.copy(membershipRevision = action.revision + 1))
                    is GroupAction.Dissolve -> directory.copy(items = persistentListOf(), actorRole = null, stale = true, error = "群聊已解散")
                    is GroupAction.Announcement, is GroupAction.Pin -> directory
                }
                demoMembers[prompt.room] = next
                mutableState.update { current ->
                    val snapshot = current.snapshot
                    val updated = when(val action = prompt.action) {
                        is GroupAction.Dissolve -> snapshot.copy(conversations = snapshot.conversations.filter { it.id != prompt.room }.toPersistentList(), messages = snapshot.messages.filter { it.roomId != prompt.room }.toPersistentList(),
                            announcements = snapshot.announcements.filter { it.room != prompt.room }.toPersistentList(), pins = snapshot.pins.filter { it.room != prompt.room }.toPersistentList(), revokedRooms = snapshot.revokedRooms.add(prompt.room))
                        is GroupAction.Announcement -> snapshot.copy(announcements = snapshot.announcements.filter { it.room != prompt.room }.toPersistentList().add(GroupAnnouncement(prompt.room, action.body, action.revision + 1, System.currentTimeMillis())))
                        is GroupAction.Pin -> snapshot.copy(pins = snapshot.pins.filter { it.room != prompt.room || it.message != action.message }.toPersistentList().let { if(action.pinned) it.add(GroupPin(prompt.room, action.message, action.revision + 1)) else it })
                        else -> snapshot
                    }
                    current.copy(members = next, snapshot = updated)
                }
            } else {
                val service = requireNotNull(capabilities); val confirmation = requireNotNull(prompt.confirmation)
                if(prompt.draft == null) service.enqueue(confirmation) else service.reconfirm(prompt.draft, confirmation)
                publishLocal(); mutableState.update { it.copy(members = it.members?.copy(stale = true)) }
            }
        } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun retryCapability(id: String) = business {
        try { capabilities?.retry(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun discardCapability(id: String) = business {
        try { capabilities?.discard(id); publishLocal() } catch(e: CancellationException) { throw e }
        catch(e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun createGroup(title: String, members: PersistentList<UserId>): Boolean = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business false
        try {
            if (session.demo) {
                val normalized = GroupCreationCommand.normalizedTitle(title)
                require(normalized.isNotEmpty() && normalized.toByteArray().size <= 120) { "群名称需要 1 至 120 个 UTF-8 字节" }
                val room = RoomId(UUID.randomUUID().toString())
                mutableState.update { it.copy(snapshot = it.snapshot.copy(conversations = it.snapshot.conversations.add(
                    Conversation(room, normalized, "群聊已创建", kind = RoomKind.Group))), error = null) }
            } else {
                val service = groupCreation ?: return@business false
                withContext(Dispatchers.Default) { service.prepare(title, members) }
                publishLocal()
            }
            mutableState.update { it.copy(error = null) }; true
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) }; false }
    }
    suspend fun retryGroup(id: String) = business {
        try { groupCreation?.retry(id); publishLocal() }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun cancelGroup(id: String) = business {
        try { groupCreation?.cancel(id); publishLocal() }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    private fun publishSnapshot(snapshot: ClientSnapshot) {
        chatComposers?.refreshSendingCapability()
        sendHistoryPages.toList().forEach {if(it.room in snapshot.revokedRooms) it.close() else it.refresh()}
        favoritePages.toList().forEach {it.refresh()}
        sourcePages.toList().forEach {if(it.room in snapshot.revokedRooms) it.close() else it.refresh()}
        timelinePages.toList().forEach { if (it.room in snapshot.revokedRooms) it.close() else it.refresh() }
        if(state.value.snapshot.groupAvatarGeneration!=snapshot.groupAvatarGeneration) {
            closeGroupAvatarPages();groupAvatarEditor?.invalidate();avatarResourcePicker?.invalidateGroupAuthority()
        }
        if(state.value.snapshot.presentationGeneration != snapshot.presentationGeneration) profilePages.toList().forEach { it.observeGeneration(snapshot.presentationGeneration) }
        var refreshRoom: RoomId? = null
        mutableState.update { current ->
            val actor = (current.session as? SessionUi.SignedIn)?.user
            val observed = actor?.let { current.members?.observeAccess(snapshot,it) } ?: current.members
            val accessChanged = observed != current.members
            if(accessChanged && current.members?.loading == false && current.members.stale == false) refreshRoom = current.members.room
            val changed = accessChanged || current.members?.room in snapshot.revokedRooms || snapshot.administrationOperations.any { work -> work.intent.room == current.members?.room &&
                (work.terminal || work.status == AdministrationStatus.DraftPaused) && current.snapshot.administrationOperations.firstOrNull { it.intent.key == work.intent.key }?.status != work.status } || snapshot.membershipOperations.any { work -> work.intent.room == current.members?.room &&
                (work.terminal || work.status == MembershipStatus.DraftPaused) && current.snapshot.membershipOperations.firstOrNull { it.intent.operation == work.intent.operation }?.status != work.status } || snapshot.capabilityOperations.any { work -> work.intent.room == current.members?.room &&
                (work.terminal || work.status == GroupCapabilityStatus.DraftPaused) && current.snapshot.capabilityOperations.firstOrNull { it.intent.operation == work.intent.operation }?.status != work.status }
            val withdrawal = current.withdrawalPrompt?.takeIf { prompt -> prompt.room !in snapshot.revokedRooms && ((current.session as? SessionUi.SignedIn)?.demo != true || snapshot.messages.any { it.id == prompt.message && it.roomId == prompt.room && !it.withdrawn && it.sender == prompt.actor && it.revision == prompt.revision }) }
            val moderation = current.moderationPrompt?.takeIf { prompt -> prompt.room !in snapshot.revokedRooms && ((current.session as? SessionUi.SignedIn)?.demo != true || snapshot.messages.any { it.roomId == prompt.room && it.id == prompt.message && !it.withdrawn && it.revision == prompt.messageRevision }) }
            current.copy(snapshot = snapshot, moderationPrompt = if(changed) null else moderation, withdrawalPrompt = withdrawal, members = if (changed) observed?.copy(stale = true) else observed,
                memberPrompt = if (changed) null else current.memberPrompt, capabilityPrompt = if (changed) null else current.capabilityPrompt, administrationPrompt = if(changed) null else current.administrationPrompt)
        }
        refreshMessagePrompts()
        refreshRoom?.let { room -> viewModelScope.launch {
            if(foreground && state.value.members?.room == room && state.value.members?.stale == true) loadMembers(room)
        } }
    }
    private var promptValidation: Job?=null
    private fun refreshMessagePrompts() {
        promptValidation?.cancel();promptValidation=null
        val session=state.value.session as? SessionUi.SignedIn ?: return
        if(session.demo || !foreground) return
        val withdrawal=state.value.withdrawalPrompt
        val moderation=state.value.moderationPrompt
        if(withdrawal==null && moderation==null) return
        promptValidation=viewModelScope.launch { business {
            try {
                val withdrawalSource=withdrawal?.let {operationSource(session,it.room,it.message)}
                val moderationSource=moderation?.let {operationSource(session,it.room,it.message)}
                mutableState.update {current -> current.copy(
                    withdrawalPrompt=if(current.withdrawalPrompt==withdrawal && (withdrawalSource?.sender!=withdrawal?.actor || withdrawalSource?.revision!=withdrawal?.revision)) null else current.withdrawalPrompt,
                    moderationPrompt=if(current.moderationPrompt==moderation && moderationSource?.revision!=moderation?.messageRevision) null else current.moderationPrompt)
                }
            } catch(e: CancellationException) {throw e}
            catch(_: Exception) {
                // A failed validation cannot keep a confirmation authorized by an older local version.
                if(state.value.session==session) mutableState.update {it.copy(
                    withdrawalPrompt=it.withdrawalPrompt.takeUnless {value->value==withdrawal},
                    moderationPrompt=it.moderationPrompt.takeUnless {value->value==moderation})}
            }
        } }
    }
    private suspend fun publishLocal() { local?.observedAppSnapshot()?.let { observed ->
        publishSnapshot(observed.snapshot); observed.conversationCommit?.didPublishSnapshot()
    } }
    fun dismissSocialPrompt() { socialGeneration++; mutableState.update { it.copy(socialPrompt = null) } }
    suspend fun changeSocial(target: UserId, action: SocialAction) = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        val generation = socialGeneration
        val clickedAt = System.currentTimeMillis(); val clickedNanos = System.nanoTime()
        mutableState.update { it.copy(error = null) }
        try {
            if (session.demo) {
                if (action in setOf(SocialAction.Block, SocialAction.Unblock, SocialAction.Remove)) {
                    mutableState.update { it.copy(socialPrompt = SocialPrompt(target, action,
                        it.snapshot.relationships.firstOrNull { r -> r.target == target }?.state ?: RelationshipState.None,
                        it.snapshot.blockedUsers.any { b -> b.target == target }, System.nanoTime() + 30_000_000_000)) }
                } else applyDemoSocial(target, action, session.user)
                return@business
            }
            val service = social ?: return@business
            val proposal = service.propose(target, action)
            publishLocal()
            val confirmation = service.prepareConfirmation(proposal.id)
            if (generation != socialGeneration || !foreground) return@business
            if (action in setOf(SocialAction.Request, SocialAction.Accept, SocialAction.Reject)) {
                service.confirm(confirmation, clickedAt, clickedNanos); publishLocal(); service.flush(); publishLocal()
            } else mutableState.update { it.copy(socialPrompt = SocialPrompt(target, action, confirmation.baseline.relationship,
                confirmation.baseline.blocked, confirmation.deadlineNanos, confirmation)) }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun prepareSocialProposal(id: String) = business {
        val generation = socialGeneration
        try {
            val confirmation = social?.prepareConfirmation(id) ?: return@business
            if (generation == socialGeneration && foreground) mutableState.update { it.copy(error = null,
                socialPrompt = SocialPrompt(confirmation.proposal.target, confirmation.proposal.action, confirmation.baseline.relationship,
                    confirmation.baseline.blocked, confirmation.deadlineNanos, confirmation)) }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun confirmSocial() = business {
        val prompt = state.value.socialPrompt ?: return@business
        val session = state.value.session as? SessionUi.SignedIn ?: return@business
        dismissSocialPrompt()
        try {
            check(prompt.deadlineNanos - System.nanoTime() > 0) { "确认已过期，请重新读取后确认" }
            if (session.demo) applyDemoSocial(prompt.target, prompt.action, session.user)
            else {
                social?.confirm(requireNotNull(prompt.confirmation)); publishLocal()
                social?.flush(); publishLocal()
            }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun discardSocial(id: String) = business {
        try { social?.discard(id); publishLocal() }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    suspend fun retrySocial(id: String) = business {
        try { social?.retry(id); social?.flush(); publishLocal() }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) } }
    }
    private fun applyDemoSocial(target: UserId, action: SocialAction, actor: UserId) {
        mutableState.update { current ->
            val snapshot = current.snapshot
            var relationships = snapshot.relationships.filter { it.target != target }.toPersistentList()
            var contacts = snapshot.contacts
            var blocks = snapshot.blockedUsers
            if (action.kind == "relationship") {
                when (action) {
                    SocialAction.Request -> relationships = relationships.add(Relationship(target, RelationshipState.Pending, actor, System.currentTimeMillis()))
                    SocialAction.Accept -> {
                        relationships = relationships.add(Relationship(target, RelationshipState.Accepted, null, System.currentTimeMillis()))
                        if (contacts.none { it.id == target }) contacts = contacts.add(Contact(target, "新朋友 ${target.value}", target.value))
                    }
                    else -> contacts = contacts.filter { it.id != target }.toPersistentList()
                }
            } else {
                relationships = snapshot.relationships
                blocks = blocks.filter { it.target != target }.toPersistentList()
                if (action == SocialAction.Block) blocks = blocks.add(UserBlock(target, System.currentTimeMillis()))
            }
            current.copy(snapshot = snapshot.copy(contacts = contacts, relationships = relationships, blockedUsers = blocks), error = null)
        }
    }
    suspend fun send(room: RoomId, text: String): Boolean = business {
        val session = state.value.session as? SessionUi.SignedIn ?: return@business false
        if (text.isBlank()) return@business false
        if (session.demo) {
            val message = Message(MessageId(UUID.randomUUID().toString()), room, session.user, text, System.currentTimeMillis())
            mutableState.update { it.copy(snapshot = it.snapshot.copy(messages = it.snapshot.messages.add(message),
                conversations = it.snapshot.conversations.map { c -> if (c.id == room) c.copy(preview = text, updatedAt = message.createdAt) else c }.toPersistentList())) }
            return@business true
        }
        try {
            val store = local ?: return@business false
            val policy=store.conversationSendingPolicy(room,session.user)
            check(policy.allowsNewContent) {requireNotNull(policy.restriction)}
            store.enqueue(MessageCommand.text(session.user, room, text, System.currentTimeMillis() + ClientSubmissionWindow.COMMAND_MILLISECONDS))
            val observed=store.observedAppSnapshot()
            publishSnapshot(observed.snapshot); observed.conversationCommit?.didPublishSnapshot()
            true // Editor clears only after durable acceptance by the local outbox.
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { mutableState.update { it.copy(error = message(e)) }; false }
    }
    fun demo() {
        if (cleared || !BuildConfig.DEBUG || operation?.isActive == true || state.value.cleanupPending || state.value.session != SessionUi.SignedOut) return
        invitationInbox.clear()
        mutableState.value = AppState(session = SessionUi.SignedIn(UserId("demo-me"), true), snapshot = demoSnapshot(), connection = "离线演示")
    }
    fun clearError() { mutableState.update { it.copy(error = null) } }
    fun generateRecoveryCode(): String = PasswordLifecycleClient.generateRecoveryCode()
    suspend fun performPassword(action: PasswordAction, account: String, current: String?, next: String?, code: String?, server: String? = null) = business {
        val expectedAuth = auth; val expectedOwner = deviceOwner
        val session = state.value.session
        check(!state.value.securityBusy && (session == SessionUi.SignedOut || session is SessionUi.SignedIn) && !state.value.cleanupPending)
        mutableState.update { it.copy(securityBusy = true) }
        try {
            if((session as? SessionUi.SignedIn)?.demo == true) {
                delay(300) // Isolated preview, never reaches a real account endpoint.
            } else {
                PasswordLifecycleClient(dependencies.account(server ?: endpoint)).perform(action, account,
                    DeviceId(UUID.randomUUID().toString().uppercase()), current, next, code)
            }
            currentCoroutineContext().ensureActive()
            if(action != PasswordAction.RecoveryCode && session is SessionUi.SignedIn &&
                expectedAuth === auth && expectedOwner == deviceOwner && state.value.session == session) {
                beginSignOut("密码已更新，请使用新密码登录，并重新设置恢复码。")
            }
        } finally {
            if(expectedAuth === auth && expectedOwner == deviceOwner) mutableState.update { it.copy(securityBusy = false) }
        }
    }
    fun openDevices(): DeviceManagement? {
        deviceManagement?.close()
        val session = state.value.session as? SessionUi.SignedIn ?: return null
        val demo = session.demo
        val client = if(demo) DeviceSessionClient(demoDevices, demoDevices.current) else deviceClient ?: return null
        val actor = if(demo) demoDevices.actor else deviceOwner?.first ?: return null
        val current = if(demo) demoDevices.current else deviceOwner?.second ?: return null
        val journal = if(demo) DeviceRevocationJournal(demoDevices, actor, current) else deviceJournal ?: return null
        return DeviceManagement(client, DeviceRevocationService(actor, current, client, journal)).also { deviceManagement = it }
    }
    fun openInvitations(room: RoomId?): InvitationManagement? {
        invitationManagement?.close()
        val service = invitations ?: return null
        return InvitationManagement(room, requireNotNull(invitationClient), requireNotNull(invitationDirectory), service, requireNotNull(local)).also { invitationManagement = it }
    }
    fun signOut() = beginSignOut()
    private fun beginSignOut(notice: String? = null) {
        if (cleared || operation?.isActive == true) return
        retiringLocalAccount = true
        backgroundSync?.interrupt()
        val damagedCredentials = (state.value.session as? SessionUi.CredentialsUnavailable)?.reason?.let { it != CredentialStoreFailure.Reason.Unavailable } == true
        val exitNotice = notice ?: if (damagedCredentials) "已退出本机登录并保留本机数据。无法确认原服务器设备会话已撤销，请从其他登录设备检查。" else null
        invitationInbox.clear()
        chatComposers?.activate(null);closeChatImages();closeMessageImage();closeMessageFile();closeMessagePlayback();closeAvatarEditor();closeGroupAvatarEditor();closeConversationResources();closeResourceManagement()
        val demo = (state.value.session as? SessionUi.SignedIn)?.demo == true
        invitationManagement?.close(); invitationManagement = null
        deviceManagement?.close(); deviceManagement = null; deviceClient = null; deviceJournal = null; deviceOwner = null; demoDevices = DemoDevices()
        stopSearchWorker();closeSearchPages();closeSendHistoryPages();closeFavoritePages();closeSourcePages();closeTimelinePages();closeSummaryPages();closeConversationActivity();connection?.close()
        mutableState.value = AppState(session = SessionUi.Loading)
        operation = viewModelScope.launch {
            var preparationError: Exception? = null
            try { if (!demo) auth.prepareLocalExit() }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { preparationError = e }
            try {
                drainBusinessJobs()
                closeLocalAccount(clearLocalDisplay = true)
                closeProfilePages();profiles = null;directory = null; directRooms = null; social = null; groupCreation = null; membership = null; capabilities = null; administration = null; messageModeration = null; messageModerationClient = null; accountPreferences = null; personalPreferences = null; names = null; ownProfile = null; sendIntents = null; profileIntents = null; groupAvatarIntents = null; readService = null; readClient = null; mutations = null; reactions = null; forwards = null; capabilityClient = null; demoMembers.clear(); clearMembers(); socialGeneration++
                invitations = null; invitationClient = null; invitationDirectory = null
                mutableState.value = AppState(session = SessionUi.Loading)
                preparationError?.let { throw it }
                if (!demo) auth.logout(::drainLocalExit)
                if (!demo) { credentialRecoveryReady = true; startCredentialRecovery() }
                mutableState.value = AppState(session = SessionUi.SignedOut, notice = exitNotice)
            }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { mutableState.value = AppState(session = SessionUi.SignedOut, error = message(e), cleanupPending = true, notice = notice) }
        }
    }
    private suspend fun drainLocalExit(account: LocalExitAccount?) {
        nativeExitCleanup.drain(account)
        localBootstrapper.clearLocalProfileDisplaysForExit(account, exitMarker)
    }
    private suspend fun drainBusinessJobs() = withContext(NonCancellable) {
        val pending=businessJobs.toList();pending.forEach { it.cancel() };pending.forEach { it.join() }
    }
    private suspend fun closeLocalAccount(clearLocalDisplay: Boolean = false) = withContext(NonCancellable) {
        retiringLocalAccount = true
        backgroundSync?.interrupt()
        stopAuthenticationObservation()
        activeAuthenticationIdentity = null
        sendAdmission.close()
        stopSearchWorker();closeSearchPages();closeSendHistoryPages();closeFavoritePages();closeSourcePages();closeTimelinePages();closeSummaryPages();closeConversationActivity(); activityRoom = null
        val composers=chatComposers;chatComposers=null;composers?.close()
        closeChatImages();closeMessageImage();closeMessageFile();closeMessagePlayback();closeGroupAvatarEditor();closeGroupAvatarPages();closeConversationResources();closeResourceManagement()
        val groups=groupAvatarRepository;groupAvatarRepository=null;groups?.close();resourceCapabilities=null;groupAvatarDisplayBudget=null
        closingMessageFiles.toList().forEach { it.awaitClosed() };closingMessageFiles.clear()
        closingPlaybacks.toList().forEach {it.awaitClosed()};closingPlaybacks.clear()
        val temporary=temporaryFiles;temporaryFiles=null;temporary?.close()
        val originals=messageOriginals;messageOriginals=null;originals?.close()
        val previews=messagePreviews;messagePreviews=null;previews?.close()
        closeProfilePages();val cache=avatarCache;avatarCache=null;cache?.close()
        val running=runtime;runtime=null;running?.cancelAndJoin()
        val background = backgroundSync
        background?.close(); if (backgroundSync === background) backgroundSync = null
        closingActivityScenes.toList().forEach { it.awaitClosed() }; closingActivityScenes.clear()
        val subscriptions = roomSubscriptionIntents; roomSubscriptionIntents = null; visibleRoomSubscription = null
        subscriptions?.awaitClosed()
        resourceBackgroundObservation?.cancelAndJoin();resourceBackgroundObservation=null
        resourceBackground?.let {ResourceBackgroundSessions.remove(it)};resourceBackground=null
        // Keep the owner reachable if draining durable system work fails; a later cleanup must
        // retry before the account database or its files can be released.
        val resources=resourceActivity;resources?.close();resourceActivity=null
        closingRelationshipPages.toList().forEach {it.awaitClosed()};closingRelationshipPages.clear()
        closingSearchPages.toList().forEach {it.awaitClosed()};closingSearchPages.clear()
        closingSearchWorkers.toList().forEach {it.join()};closingSearchWorkers.clear()
        closingSendHistoryPages.toList().forEach {it.awaitClosed()};closingSendHistoryPages.clear()
        closingFavoritePages.toList().forEach {it.awaitClosed()};closingFavoritePages.clear()
        closingSourcePages.toList().forEach {it.awaitClosed()};closingSourcePages.clear()
        closingTimelinePages.toList().forEach { it.awaitClosed() };closingTimelinePages.clear()
        val network=accountNetwork;network?.closeAndDrain();accountNetwork=null
        val store=local
        // All page/runtime writers have been cancelled/drained before the final text-cache purge.
        // Ordinary owner recreation and temporary credential unavailability retain these facts.
        if (clearLocalDisplay) store?.clearLocalProfileDisplays()
        withContext(Dispatchers.IO) { store?.close() };if(local===store) local=null
    }
    override fun onCleared() {
        invitationInbox.clear()
        cleared=true;foreground=false;visibilityRevision++
        backgroundSync?.interrupt()
        stopAuthenticationObservation()
        chatComposers?.activate(null);closeChatImages();closeMessageImage();closeMessageFile();closeMessagePlayback();closeAvatarEditor();closeGroupAvatarEditor();closeConversationResources();closeResourceManagement()
        stopSearchWorker();closeSearchPages();closeSendHistoryPages();closeFavoritePages();closeSourcePages();closeTimelinePages();closeSummaryPages();closeProfilePages();closeGroupAvatarPages();invitationManagement?.close();deviceManagement?.close();connection?.close()
        val authentication=operation;authentication?.cancel()
        credentialRevocationTask?.cancel(); registrationCancellationTask?.cancel(); credentialRecoveryObservation?.cancel()
        val work=businessJobs.toList();work.forEach { it.cancel() };runtime?.cancel()
        // ViewModel's own scope is already cancelled. Finish actual I/O before releasing files or SQLite.
        val cleanup=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        cleanup.launch {
            try { authentication?.join();stopCredentialRecovery();work.forEach { it.join() };closeLocalAccount();shutdownComplete.complete(Unit) }
            catch(error: Throwable) {shutdownComplete.completeExceptionally(error);throw error}
            finally { cleanup.cancel() }
        }
        super.onCleared()
    }
    private fun message(error: Exception): String = when (error) {
        is CredentialRecoveryFailure -> "设备清理记录暂时无法处理，现有记录已保留，请重试设备清理。"
        is CredentialStoreFailure -> "本机登录凭据暂时无法使用，现有记录已保留。"
        is ClientFailure.Http -> when (error.status) { 401, 403 -> "身份验证失败，请检查账号或重新登录"; 404 -> "没有找到这个公开账号"; 409 -> "操作冲突，请检查账号是否已存在"; 429 -> "操作频繁，请稍后重试"; else -> "服务暂不可用（${error.status}）" }
        is javax.net.ssl.SSLException -> "无法验证服务器证书，请检查可信 CA 配置"
        is java.io.IOException -> "无法连接服务器，请检查网络和服务地址"
        is IllegalArgumentException, is IllegalStateException -> error.message ?: "输入或本机状态无效"
        else -> "暂时无法完成，请稍后重试"
    }
}

private fun demoSnapshot(): ClientSnapshot {
    val rooms = persistentListOf(
        Conversation(RoomId("design"), "设计讨论组", "林：新版界面很清爽，明天一起看看？", 3, pinned = true, kind = RoomKind.Group),
        Conversation(RoomId("lin"), "林", "周末一起去看展吧 ☀️", 1),
        Conversation(RoomId("android"), "Android 开发组", "导航与消息体验，正在一点点完善。", kind = RoomKind.Group),
        Conversation(RoomId("chen"), "陈一", "收到，谢谢！", muted = true))
    return ClientSnapshot(rooms, persistentListOf(Contact(UserId("lin"), "林", "lin"), Contact(UserId("chen"), "陈一", "chenyi")),
        persistentListOf(Message(MessageId("sample-1"), RoomId("design"), UserId("lin"), "把想法放在一起，让沟通简单一点。", 0),
            Message(MessageId("sample-2"), RoomId("design"), UserId("demo-me"), "消息、联系人和我的，都可以从这里开始。", 1),
            Message(MessageId("sample-3"), RoomId("design"), UserId("lin"), "新版界面很清爽，明天一起看看？", 2)),
        relationships = persistentListOf(Relationship(UserId("lin"), RelationshipState.Accepted, null, 1),
            Relationship(UserId("chen"), RelationshipState.Accepted, null, 1),
            Relationship(UserId("zhou"), RelationshipState.Pending, UserId("zhou"), 2)))
}

private fun demoPreferenceDefaults(): PersistentList<PreferenceValue> = PreferenceKind.entries.map {
    PreferenceValue(it, true, if(it in setOf(PreferenceKind.ReadReceipts, PreferenceKind.LiveActivity)) true else null)
}.toPersistentList()
