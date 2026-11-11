package com.xmtx.im

import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import org.junit.Rule
import org.junit.Test

class MessageMediaUiTests {
    @get:Rule val compose=createComposeRule()
    private val id="AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val descriptor=ResourceDescriptor(ResourceKey(ResourceHome.Room(room),id),1,"说明文件.pdf","application/pdf",1024,ResourceChecksum("a".repeat(64)),ResourceState.Ready)
    private val media=MessageMedia(persistentListOf(id),persistentListOf(MessageMediaPresentation(id,MessageMediaKind.File,"application/pdf",1024,descriptor)))
    private fun message()=Message(MessageId(id),room,UserId(id),"附件说明",1000,media=media)
    @Test fun metadataRendersWithoutInventingDownloadActionsAndDisappearsOnRemoval() {
        var message by mutableStateOf(message())
        compose.setContent { MaterialTheme { Surface(Modifier.widthIn(max=320.dp)) { MessageBubbleContent(message) } } }
        compose.onNodeWithText("附件说明").assertIsDisplayed()
        compose.onNodeWithText("说明文件.pdf",substring=true).assertIsDisplayed().assertHasNoClickAction()
        compose.onNodeWithText("文件 ·",substring=true).assertIsDisplayed()
        compose.runOnIdle { message=message.copy(withdrawn=true,text="消息已撤回") }
        compose.onNodeWithText("说明文件.pdf",substring=true).assertDoesNotExist();compose.onNodeWithText("消息已撤回").assertIsDisplayed()
    }
    @Test fun localIdsWaitForAuthoritativeDetailsAndUnknownLegacyHasNoInventedFiles() {
        var message by mutableStateOf(message().copy(text="[附件]",media=MessageMedia(persistentListOf(id))))
        compose.setContent { MaterialTheme { MessageBubbleContent(message) } }
        compose.onNodeWithText("1 个附件 · 等待同步详情").assertIsDisplayed()
        compose.onNodeWithText("说明文件.pdf",substring=true).assertDoesNotExist()
        compose.runOnIdle { message=message.copy(media=null) }
        compose.onNodeWithText("1 个附件 · 等待同步详情").assertDoesNotExist();compose.onNodeWithText("[附件]").assertIsDisplayed()
    }
    @Test fun completeReplacementRecomposesAttachmentMetadata() {
        var message by mutableStateOf(message())
        compose.setContent { MaterialTheme { MessageBubbleContent(message) } }
        compose.runOnIdle {
            val updated=media.presentations!!.single().copy(descriptor=descriptor.copy(displayName="新附件.pdf",revision=2))
            message=message.copy(revision=2,media=media.copy(presentations=persistentListOf(updated)))
        }
        compose.onNodeWithText("说明文件.pdf",substring=true).assertDoesNotExist();compose.onNodeWithText("新附件.pdf",substring=true).assertIsDisplayed()
    }
}
