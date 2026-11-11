package com.xmtx.im.client

import kotlin.test.*

class InvitationQrTests {
    private val secret = InvitationSecret("Abc_123-".repeat(5)+"Abc")
    private fun pixels(code: InvitationQr, scale: Int = 5): ByteArray {
        val side=code.size*scale
        return ByteArray(side*side) { i -> if(code.rows[i/side/scale][i%side/scale]=='1') 0 else -1 }
    }
    @Test fun generatedMediumCorrectionCodeRoundTripsAtAllRotationsAndInverted() {
        val code=InvitationQr.create(secret);val side=code.size*5
        var data=pixels(code)
        repeat(4) {
            assertEquals(secret,decodeInvitationQr(side,side,data))
            assertEquals(secret,decodeInvitationQr(side,side,ByteArray(data.size) { (255-data[it].toUByte().toInt()).toByte() }))
            data=ByteArray(data.size) { i -> data[(side-1-i%side)*side+i/side] }
        }
        assertEquals("InvitationQr(<redacted>)",code.toString())
    }
    @Test fun immutableModulesHaveQuietZoneAndDoNotChangeWhenCopied() {
        val code=InvitationQr.create(secret);val original=code.rows
        assertTrue(code.rows.all { it.length==code.size })
        assertTrue(code.rows.take(4).all { it.all { cell -> cell=='0' } })
        assertTrue(code.rows.takeLast(4).all { it.all { cell -> cell=='0' } })
        assertTrue(code.rows.all { it.take(4)=="0000" && it.takeLast(4)=="0000" })
        code.rows.set(0,"1".repeat(code.size))
        assertSame(original,code.rows)
    }
    @Test fun boundsBlankAndUnrelatedQrPayloadAreRejected() {
        assertNull(decodeInvitationQr(2049,1,ByteArray(2049)))
        assertNull(decodeInvitationQr(1,1,byteArrayOf()))
        assertNull(decodeInvitationQr(0,0,byteArrayOf()))
        assertNull(decodeInvitationQr(200,200,ByteArray(40000) { -1 }))
        val bits=com.google.zxing.qrcode.QRCodeWriter().encode("https://example.com",com.google.zxing.BarcodeFormat.QR_CODE,200,200)
        assertNull(decodeInvitationQr(200,200,ByteArray(40000) { if(bits[it%200,it/200]) 0 else -1 }))
    }
}
