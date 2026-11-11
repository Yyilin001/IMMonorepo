package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*

/** TEMP objects live on the writer connection; every call occurs inside that connection's transaction.
 * Dirty bits roll back with the business writes. Nothing is added to the persistent account schema.
 */
internal class SqliteProjectionDiagnostics(private val db:SQLiteDatabase,val diagnostics:NetworkDiagnostics) {
    var pending:ConversationCommitMeasurement?=null
        private set
    fun takeConversationCommit():ConversationCommitMeasurement? = ConversationCommitMeasurement.earliest(pending,null).also {pending=null}
    private val dirty="im_projection_diagnostics"
    fun begin() {
        check(db.inTransaction())
        db.execSQL("CREATE TEMP TABLE IF NOT EXISTS $dirty(scope INTEGER PRIMARY KEY)")
        db.execSQL("CREATE TEMP TABLE IF NOT EXISTS im_projection_diagnostic_schema(version INTEGER)")
        val version=db.rawQuery("PRAGMA main.schema_version",null).use {it.moveToFirst();it.getLong(0)}
        val installed=db.rawQuery("SELECT version FROM temp.im_projection_diagnostic_schema",null).use {if(it.moveToFirst()) it.getLong(0) else null}
        if(installed!=version) {
            val tables=db.rawQuery("SELECT name,sql FROM main.sqlite_master WHERE type='table'",null).use {rows->buildList {
                while(rows.moveToNext()) if(!rows.getString(1).orEmpty().startsWith("CREATE VIRTUAL TABLE",ignoreCase=true)) add(rows.getString(0))
            }}
            for(table in tables) {
                val scopes=scopes(table);if(scopes.isEmpty()) continue
                // Identifiers originate in SQLite's schema, never in a network payload.
                fun quoted(value:String)="\""+value.replace("\"","\"\"")+"\""
                val inserts=scopes.joinToString(" ") {"INSERT INTO $dirty(scope) SELECT ${it.ordinal} WHERE NOT EXISTS (SELECT 1 FROM $dirty WHERE scope=${it.ordinal});"}
                for(event in listOf("INSERT","UPDATE","DELETE")) db.execSQL(
                    "CREATE TEMP TRIGGER IF NOT EXISTS ${quoted("im_diag_${table}_$event")} AFTER $event ON main.${quoted(table)} BEGIN $inserts END")
            }
            db.execSQL("DELETE FROM temp.im_projection_diagnostic_schema")
            db.execSQL("INSERT INTO temp.im_projection_diagnostic_schema VALUES (?)",arrayOf(version))
        }
        db.execSQL("DELETE FROM temp.$dirty")
    }
    fun changed():PersistentSet<ProjectionScope> = db.rawQuery("SELECT scope FROM temp.$dirty",null).use {rows->buildSet {
        while(rows.moveToNext()) add(ProjectionScope.entries[rows.getInt(0)])
    }.toPersistentSet()}
    fun committed(scopes:PersistentSet<ProjectionScope>,start:Long,end:Long) {
        if(scopes.isEmpty()) return
        diagnostics.record(ProjectionMetric(ProjectionMetric.Phase.Commit,(end-start).coerceAtLeast(0),scopes))
        if(ProjectionScope.Conversations in scopes) pending=ConversationCommitMeasurement.earliest(pending,ConversationCommitMeasurement(end,diagnostics))
    }
    companion object {
        private val all=ProjectionScope.entries.toPersistentSet()
        private fun set(vararg scopes:ProjectionScope)=scopes.toPersistentSet()
        /** Conservative all-scope fallback prevents future visible tables from disappearing silently. */
        fun scopes(table:String):PersistentSet<ProjectionScope> {
            if(table.startsWith("sqlite_") || table.startsWith("message_search_") || table.startsWith("contact_search_")) return persistentSetOf()
            if(table.startsWith("resource_")) return set(ProjectionScope.Resources)
            return when(table) {
                "cursor","records","sync_history","sync_reset","sync_rebuild","snapshot","snapshot_import","snapshot_items","pages",
                "projection_migrations","account_room_heads","room_observed_heads","room_cursors","directory_scan","directory_seen","directory_work",
                "reaction_versions","reaction_effects","group_metadata_effects","group_avatar_effects","nickname_effects","member_access_effects",
                "role_policy_effects","policy_schema","name_operations","name_confirmed","own_profile","own_profile_operations",
                "personal_operations","personal_confirmed","local_profile_displays","send_intent_attachments","send_intent_imports" -> persistentSetOf()
                "messages","outbox","local_direct_messages","send_intents","forward_operations","message_mutations","timeline_activities",
                "abandoned_text_sends","text_send_replacements","group_pins","favorite_sources" -> set(ProjectionScope.Conversations,ProjectionScope.ConversationTimeline)
                "reaction_operations","direct_read_projections","own_read_projections","read_intents","read_operations","read_confirmed","read_room_state" -> set(ProjectionScope.ConversationTimeline)
                "rooms","latest_visible","room_kinds","local_direct_room_identities","direct_account_kinds","direct_profile_bindings","direct_operations","group_creations" -> set(ProjectionScope.Conversations,ProjectionScope.ConversationDetails)
                "message_tombstones","message_moderation_operations","moderation_facts" -> set(ProjectionScope.Conversations,ProjectionScope.ConversationDetails)
                "group_avatar_intents" -> set(ProjectionScope.ConversationDetails,ProjectionScope.Resources)
                "profile_intents" -> set(ProjectionScope.Resources)
                "contacts","social_operations","social_proposals","user_blocks" -> set(ProjectionScope.Contacts,ProjectionScope.Conversations,ProjectionScope.ConversationDetails,ProjectionScope.Presentations)
                "preference_projections","preference_authority","preference_operations" -> set(ProjectionScope.Privacy,ProjectionScope.Presentations)
                "presentation_epoch","presentation_floors" -> set(ProjectionScope.Presentations)
                "group_avatar_epoch","group_avatar_epochs","memberships","member_access_observations" -> set(ProjectionScope.Conversations,ProjectionScope.ConversationDetails,ProjectionScope.Presentations)
                "conversation_state","personal_projections","group_announcements","policy_baselines","policy_denials","policy_profile_fences","policy_recovery",
                "role_policy_observations","direct_sending_capabilities","membership_operations","administration_operations","capability_operations","invitation_operations" -> set(ProjectionScope.Conversations,ProjectionScope.ConversationMetadata)
                "conversation_drafts","conversation_draft_submissions" -> set(ProjectionScope.Conversations,ProjectionScope.ConversationTimeline)
                else -> all
            }
        }
    }
}
