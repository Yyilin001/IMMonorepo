package com.xmtx.im

import com.xmtx.im.client.FrameCodec
import com.xmtx.imclientkit.generated.im.realtime.v2.ClientHello
import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import kotlinx.serialization.json.Json
import kotlinx.serialization.serializer
import kotlin.reflect.typeOf

/** Executed in the installed, R8-optimized APK before fixture setup, outside measured blocks. */
internal fun verifyOptimizedRuntime() {
    val hello = ClientHello.newBuilder().setDeviceId("benchmark-installation")
        .addSupportedProtocolVersions(FrameCodec.VERSION)
        .addSupportedCapabilityProfiles("benchmark-profile").setSupportsMessageSendOperations(true)
    val envelope = Envelope.newBuilder().setProtocolVersion(FrameCodec.VERSION).setRequestId(17)
        .setClientHello(hello).build()
    val decoded = FrameCodec.read(FrameCodec.encode(envelope).inputStream())
    check(decoded == envelope && decoded.clientHello.deviceId == "benchmark-installation")
    // Exercise runtime serializer lookup as well as polymorphic route restoration after obfuscation.
    val route = Route.Chat("benchmark-room", "benchmark-message")
    val serializer = serializer(typeOf<Route.Chat>())
    check(Json.decodeFromString(serializer, Json.encodeToString(serializer, route)) == route)
    check(Json.decodeFromString(Route.serializer(), Json.encodeToString(Route.serializer(), route)) == route)
}
