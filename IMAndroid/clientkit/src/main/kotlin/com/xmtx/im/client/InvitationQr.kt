package com.xmtx.im.client

import com.google.zxing.*
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList

/** Immutable modules including a four-module quiet zone. No mutable image or encoder buffer escapes. */
class InvitationQr private constructor(val rows: PersistentList<String>) {
    val size: Int get() = rows.size
    override fun toString() = "InvitationQr(<redacted>)"
    companion object {
        fun create(secret: InvitationSecret): InvitationQr {
            val bits = QRCodeWriter().encode(invitationURL(secret), BarcodeFormat.QR_CODE, 0, 0,
                mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 4))
            return InvitationQr((0 until bits.height).map { y ->
                buildString { for (x in 0 until bits.width) append(if (bits[x,y]) '1' else '0') }
            }.toPersistentList())
        }
    }
}

/** Caller owns the frame; it is neither retained nor persisted. QR detection handles all four rotations. */
fun decodeInvitationQr(width: Int, height: Int, luminance: ByteArray): InvitationSecret? {
    if (width !in 1..2048 || height !in 1..2048 || width.toLong()*height != luminance.size.toLong()) return null
    val source = PlanarYUVLuminanceSource(luminance,width,height,0,0,width,height,false)
    for (candidate in listOf(source,source.invert())) {
        val text = try { QRCodeReader().decode(BinaryBitmap(HybridBinarizer(candidate))).text }
        catch (_: ReaderException) { continue }
        return invitationDeepLink(text)
    }
    return null
}
