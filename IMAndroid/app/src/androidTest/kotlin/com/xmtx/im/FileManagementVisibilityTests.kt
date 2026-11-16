package com.xmtx.im

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import com.xmtx.im.sharedsdk.*
import kotlinx.collections.immutable.persistentListOf
import org.junit.Rule
import org.junit.Test

class FileManagementVisibilityTests {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun accountChatAndAttachmentExposeOnlyMessageActions() {
        val attachment = SharedAttachment("file", "说明.txt", "text/plain", 30L, "file")
        val message = SharedMessage(id = "message", senderID = "peer", text = "请查收", sequence = 1,
            withdrawn = false, hasMedia = true, attachments = persistentListOf(attachment), revision = 1,
            canMutate = false, readByPeer = false, replyToID = null, replyPreview = null, forwardedFromID = null)
        val chat = SharedChat("room", persistentListOf(message), persistentListOf(), hasOlder = false,
            isLatest = true, hasMorePending = false, pendingPage = 0, focusMessageID = null)
        val resource = SharedResourceView(draft = null, importID = null, selected = attachment, roomID = chat.roomID,
            messageID = message.id, image = null, expiresAtElapsed = Long.MAX_VALUE, readID = null, chunk = null,
            transfers = persistentListOf(), failure = null)
        val snapshot = SharedSnapshot(state = SharedSessionState.Ready, userID = "user", allowsStrangerMessages = null,
            appliedSequence = 1, acknowledgedSequence = 1, connections = 0,
            conversations = persistentListOf(SharedConversation(chat.roomID, "测试会话", message.text)),
            failure = null, hasMoreConversations = false, isFirstConversationPage = true, chat = chat,
            directory = null, resource = resource, messaging = null)
        val model = compose.runOnUiThread { ViewModelProvider(compose.activity)[SharedAppViewModel::class.java] }
        compose.setContent { SharedSignedIn(SharedAppState(snapshot = snapshot), model) }

        compose.onNode(hasText("我的") and hasClickAction()).performClick()
        compose.onNodeWithTag("shared_own_avatar").assertExists()
        compose.onNodeWithTag("shared_all_transfers").assertDoesNotExist()

        compose.onNode(hasText("消息") and hasClickAction()).performClick()
        compose.onNodeWithTag("shared_room_room").performClick()
        compose.onNodeWithTag("shared_attach_file").assertExists()
        compose.onNodeWithTag("shared_chat_transfers").assertDoesNotExist()
        val file = hasTestTag("shared_attachment_file")
        compose.onNodeWithTag("shared_messages").performScrollToNode(file)
        compose.onNode(file).performClick()
        compose.onNodeWithTag("shared_resource_download").assertIsEnabled()
        compose.onNodeWithTag("shared_resource_save").assertIsEnabled()
        compose.onNodeWithTag("shared_resource_transfers").assertDoesNotExist()
    }
}
