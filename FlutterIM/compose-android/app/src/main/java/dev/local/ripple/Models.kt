package dev.local.ripple

import androidx.compose.runtime.Immutable
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.persistentListOf

const val ConversationCount = 10_000
val sampleTexts = persistentListOf(
    "刚更新了设计稿，来看看这个版本 👀", "收到，我这边已经准备好了。", "这个想法不错，我们可以继续细化一下。",
    "下午三点，一起同步一下进展？", "新版本体验很流畅，辛苦大家！", "文件已经整理好了，稍后一起过一遍。",
    "今天的任务已完成 ✅", "周末去哪里走走？我发现了一家不错的咖啡店 ☕", "没问题，就按这个方案推进。",
    "消息已送达，所有数据都在本地运行。", "我补充了几个细节，欢迎反馈。", "保持专注，也记得休息一下 🌿"
)
private val names = persistentListOf("产品设计小组", "林知夏", "Flutter 技术交流", "陈一舟", "周末出逃计划", "许清禾", "项目协作空间", "陆星野")

fun isGroup(id: Int) = id % 4 == 0 || id == 2
fun numberId(id: Int) = id.toString().padStart(5, '0')
fun originalName(id: Int) = names.getOrNull(id) ?: "${if (isGroup(id)) "协作小组" else "本地好友"} ${numberId(id)}"
fun handle(id: Int) = "${if (isGroup(id)) "group" else "ripple"}_${numberId(id)}"
fun memberCount(id: Int) = 12 + id % 80
fun memberAt(id: Int, index: Int) = ((id * 17 + index - 1) % (ConversationCount / 2)) * 2 + 1
fun senderAt(id: Int, seq: Int) = if (isGroup(id)) memberAt(id, 1 + seq % (memberCount(id) - 1)) else id
fun seedCount(id: Int) = when (id) { 1 -> 8; 2 -> 12_000; 7 -> 0; else -> 360 + id % 10 * 30 }

@Immutable data class Conversation(
    val id: Int, val name: String, val preview: String, val time: Long, val unread: Int,
    val pinned: Boolean, val muted: Boolean = false, val order: Long = 0
)
@Immutable data class Message(
    val seq: Int, val sender: Int?, val text: String, val time: Long,
    val image: Boolean = false, val file: String? = null, val ratio: Float = 1.33f
) {
    val preview get() = if (image) "[图片]" else text
}
@Immutable data class Note(
    val remark: String = "", val tags: PersistentList<String> = persistentListOf(),
    val phone: String = "", val description: String = "", val deleted: Boolean = false
)
@Immutable data class MyProfile(val name: String = "涟漪用户", val region: String = "", val bio: String = "很高兴认识你。")
enum class Backdrop(val label: String) { Light("浅白"), Mint("薄荷"), Warm("暖杏") }
enum class FontSize(val label: String, val sp: Int) { Small("小", 14), Standard("标准", 16), Large("大", 18), Extra("特大", 20) }
@Immutable data class Preferences(
    val size: FontSize = FontSize.Standard, val background: Backdrop = Backdrop.Light,
    val animate: Boolean = true, val haptics: Boolean = true, val badge: Boolean = true, val preview: Boolean = true
)
enum class Network(val label: String) {
    Normal("正常 · 100ms 响应"), Slow("慢速 · 1.5s 响应"), Offline("历史服务离线"), Overlap("重复与乱序回包")
}
@Immutable data class Runtime(
    val running: Boolean = true, val rate: Int = 0, val uniform: Boolean = false,
    val network: Network = Network.Normal, val failNext: Boolean = false
)
@Immutable data class Stats(
    val received: Long = 0, val sent: Long = 0, val cached: Int = 0, val evicted: Long = 0,
    val perSecond: Int = 0, val processMs: Double = 0.0, val publishMs: Double = 0.0,
    val frameP95: Float = 0f, val slowFrames: Int = 0, val frameCount: Int = 0,
    val samples: PersistentList<Int> = persistentListOf()
)
@Immutable data class Window(
    val messages: PersistentList<Message> = persistentListOf(), val loading: Boolean = false,
    val error: String = "", val failedNewer: Boolean = false, val more: Boolean = true, val gap: Boolean = false, val newer: Boolean = false,
    val lastLive: Message? = null, val reading: Boolean = false, val pending: Int = 0, val anchor: Int = 0, val offset: Int = 0
)
