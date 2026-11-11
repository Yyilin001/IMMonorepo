package com.xmtx.im.platform

import android.graphics.Rect
import androidx.camera.core.ImageProxy
import com.xmtx.im.client.*
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy
import java.nio.ByteBuffer

class InvitationFrameTests {
    private val secret=InvitationSecret("A".repeat(43))
    private class Frame(val image: ImageProxy, val closes: () -> Int)
    private fun frame(truncated: Boolean=false, badStride: Boolean=false): Frame {
        val code=InvitationQr.create(secret);val scale=4;val side=code.size*scale
        val width=side+12;val height=side+10;val row=width*2+13;val offset=17
        val buffer=ByteBuffer.allocate(offset+row*height).apply { position(offset) }
        for(y in 0 until side) for(x in 0 until side) buffer.put(offset+(y+5)*row+(x+6)*2,if(code.rows[y/scale][x/scale]=='1') 0 else (-1).toByte())
        if(truncated) buffer.limit(offset+10)
        var closed=0
        val plane=Proxy.newProxyInstance(ImageProxy.PlaneProxy::class.java.classLoader,arrayOf(ImageProxy.PlaneProxy::class.java)) { _,method,_ ->
            when(method.name) { "getBuffer"->buffer;"getRowStride"->if(badStride) 0 else row;"getPixelStride"->2;else->error("Unexpected plane call") }
        } as ImageProxy.PlaneProxy
        val image=Proxy.newProxyInstance(ImageProxy::class.java.classLoader,arrayOf(ImageProxy::class.java)) { _,method,_ ->
            when(method.name) { "getWidth"->width;"getHeight"->height;"getCropRect"->Rect(6,5,6+side,5+side);"getPlanes"->arrayOf(plane);"close"->{closed++;null};else->error("Unexpected frame call") }
        } as ImageProxy
        return Frame(image) { closed }
    }
    @Test fun croppedPaddedInterleavedLumaDecodesAndAlwaysReleasesFrame() {
        val frame=frame();var result:InvitationSecret?=null
        InvitationFrameAnalyzer({true}) {result=it}.analyze(frame.image)
        assertEquals(secret,result);assertEquals(1,frame.closes())
    }
    @Test fun malformedAndStoppedFramesAreReleasedWithoutPublishing() {
        for(frame in listOf(frame(truncated=true),frame(badStride=true))) {
            InvitationFrameAnalyzer({true}) {fail("Malformed frame published")}.analyze(frame.image)
            assertEquals(1,frame.closes())
        }
        val stopped=frame()
        InvitationFrameAnalyzer({false}) {fail("Stopped frame published")}.analyze(stopped.image)
        assertEquals(1,stopped.closes())
    }
    @Test fun consumerFailureStillReleasesFrame() {
        val frame=frame()
        try {InvitationFrameAnalyzer({true}) {throw IllegalStateException("test")}.analyze(frame.image);fail("Expected consumer failure")}
        catch(_:IllegalStateException) {assertEquals(1,frame.closes())}
    }
}
