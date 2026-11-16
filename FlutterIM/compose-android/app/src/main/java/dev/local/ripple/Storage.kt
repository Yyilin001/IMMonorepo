package dev.local.ripple

import android.content.SharedPreferences
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import kotlinx.collections.immutable.toPersistentMap
import org.json.JSONArray
import org.json.JSONObject

internal class Storage(private val disk: SharedPreferences) {
    fun preferences(): Preferences = Preferences(
        size = FontSize.entries.find { it.name == disk.getString("size", null) } ?: FontSize.Standard,
        background = Backdrop.entries.find { it.name == disk.getString("background", null) } ?: Backdrop.Light,
        animate = disk.getBoolean("animate", true), haptics = disk.getBoolean("haptics", true),
        badge = disk.getBoolean("badge", true), preview = disk.getBoolean("preview", true)
    )

    fun save(p: Preferences) = disk.edit().putString("size", p.size.name).putString("background", p.background.name)
        .putBoolean("animate", p.animate).putBoolean("haptics", p.haptics)
        .putBoolean("badge", p.badge).putBoolean("preview", p.preview).apply()

    fun notes() = disk.all.mapNotNull { (key, raw) ->
        val id = key.takeIf { it.startsWith("note.") }?.substringAfter('.')?.toIntOrNull()
        if (id == null || id !in 0 until ConversationCount || raw !is String) return@mapNotNull null
        runCatching {
            val obj = JSONObject(raw)
            id to Note(obj.optString("remark"), strings(obj.optJSONArray("tags")), obj.optString("phone"),
                obj.optString("description"), obj.optBoolean("deleted"))
        }.getOrNull()
    }.toMap().toPersistentMap()

    fun save(id: Int, n: Note) {
        val value = JSONObject().put("remark", n.remark).put("tags", JSONArray(n.tags)).put("phone", n.phone)
            .put("description", n.description).put("deleted", n.deleted)
        disk.edit().putString("note.$id", value.toString()).apply()
    }

    fun recent(key: String) = strings(runCatching { JSONArray(disk.getString("recent.$key", "[]")) }.getOrNull())
    fun saveRecent(key: String, value: PersistentList<String>) =
        disk.edit().putString("recent.$key", JSONArray(value).toString()).apply()

    private fun strings(array: JSONArray?) =
        (0 until (array?.length() ?: 0)).mapNotNull { array?.opt(it) as? String }.toPersistentList()
}
