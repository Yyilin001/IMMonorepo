package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import kotlin.test.*

class MediaMessageTests {
    private val actor=UserId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val room=RoomId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
    private val operation="CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private val media=persistentListOf("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD","EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")
    @Test fun `Swift attachment order Unicode and operation fingerprints match exactly`() {
        javaClass.getResourceAsStream("/media-message-swift.txt")!!.bufferedReader().useLines { lines->lines.forEach { line->
            val value=Json.parseToJsonElement(line.substringAfter('\t')).jsonObject
            val ids=value.getValue("media").jsonPrimitive.content.split(',').toPersistentList()
            val text=value.getValue("text").jsonPrimitive.content
            val command=MessageCommand.withMedia(actor,room,text,ids,1800000000000,operation)
            assertEquals(ids,command.mediaIdsList);assertEquals(text,command.text)
            assertEquals(value.getValue("domain").jsonPrimitive.content,command.domainFingerprint.toByteArray().joinToString("") { "%02x".format(it) })
            assertEquals(value.getValue("fingerprint").jsonPrimitive.content,command.fingerprint.toByteArray().joinToString("") { "%02x".format(it) })
        } }
    }
    @Test fun `media commands freeze normalized identities without sorting or weakening limits`() {
        val first=MessageCommand.withMedia(actor,room,"",media,1,operation)
        val normalized=MessageCommand.withMedia(actor,room,"",media.map { it.lowercase() }.toPersistentList(),1,operation)
        assertEquals(first,normalized)
        assertNotEquals(first.domainFingerprint,MessageCommand.withMedia(actor,room,"",media.reversed().toPersistentList(),1,operation).domainFingerprint)
        assertNotEquals(first.fingerprint,MessageCommand.withMedia(actor,room,"",media,2,operation).fingerprint)
        assertFails { MessageCommand.withMedia(actor,room,"",persistentListOf(),1) }
        assertFails { MessageCommand.withMedia(actor,room,"",persistentListOf(media.first(),media.first().lowercase()),1) }
        assertFails { MessageCommand.withMedia(actor,room,"",List(11) { java.util.UUID.randomUUID().toString() }.toPersistentList(),1) }
        assertFails { MessageCommand.withMedia(actor,room,"界".repeat(10923),media,1) }
        assertFails { MessageCommand.withMedia(actor,room,"",persistentListOf("../private"),1) }
        assertFails { MessageCommand.withMedia(actor,room,"",media,0) }
        assertFails { MessageCommand.text(actor,room," ",1) }
    }
}
