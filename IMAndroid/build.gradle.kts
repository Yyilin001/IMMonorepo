plugins {
    id("com.android.application") version "8.13.2" apply false
    id("com.android.library") version "8.13.2" apply false
    kotlin("android") version "2.2.21" apply false
    kotlin("jvm") version "2.2.21" apply false
    kotlin("plugin.serialization") version "2.2.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
    id("com.google.protobuf") version "0.9.5" apply false
}

val verifyProtocolVersion by tasks.registering {
    val versionFile = file("../Protocol/im_realtime/v2/protocol_version.txt")
    val codec = file("clientkit/src/main/kotlin/com/xmtx/im/client/FrameCodec.kt")
    inputs.files(versionFile, codec)
    doLast {
        val expected = versionFile.readText().trim().toInt()
        val actual = Regex("const val VERSION = (\\d+)").find(codec.readText())!!.groupValues[1].toInt()
        check(expected == actual) { "协议已更新为 V$expected；先对齐 Android SDK，再修改协商版本。" }
    }
}
