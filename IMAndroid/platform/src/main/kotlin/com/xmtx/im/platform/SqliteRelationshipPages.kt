package com.xmtx.im.platform

import android.database.sqlite.SQLiteDatabase
import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import java.util.UUID

/** Durable invalidation with bounded tokenization. Index rows never grant presentation permission. */
internal class SqliteRelationshipPages(private val db:SQLiteDatabase,private val actor:UserId,
    private val displays:SqliteLocalProfileDisplays) {
    private val owner=UUID.randomUUID().toString()
    private val format="nfkc-root-grapheme-v1/${android.icu.util.VersionInfo.ICU_VERSION}"
    init {if(!db.isReadOnly) {
        db.execSQL("CREATE INDEX IF NOT EXISTS contacts_page_order ON contacts(state,time DESC,id ASC)")
        db.execSQL("CREATE TABLE IF NOT EXISTS contact_search_meta(id INTEGER PRIMARY KEY CHECK(id=1),format TEXT NOT NULL)")
        db.execSQL("CREATE TABLE IF NOT EXISTS contact_search_jobs(user TEXT PRIMARY KEY)")
        db.execSQL("CREATE TABLE IF NOT EXISTS contact_search_documents(user TEXT UNIQUE NOT NULL)")
        db.execSQL("CREATE VIRTUAL TABLE IF NOT EXISTS contact_search_fts USING fts4(name,handle,tokenize=simple)")
        val old=db.rawQuery("SELECT format FROM contact_search_meta WHERE id=1",null).use {if(it.moveToFirst()) it.getString(0) else null}
        if(old!=format) {
            db.execSQL("DELETE FROM contact_search_fts");db.execSQL("DELETE FROM contact_search_documents")
            db.execSQL("INSERT OR IGNORE INTO contact_search_jobs SELECT DISTINCT user FROM local_profile_displays")
            db.execSQL("INSERT OR REPLACE INTO contact_search_meta VALUES(1,?)",arrayOf(format))
        }
        for(event in listOf("INSERT","UPDATE","DELETE")) {
            val ref=if(event=="DELETE") "OLD" else "NEW"
            db.execSQL("""CREATE TRIGGER IF NOT EXISTS contact_search_${event.lowercase()} AFTER $event ON local_profile_displays BEGIN
                INSERT OR REPLACE INTO contact_search_jobs VALUES($ref.user);
                ${if(event=="UPDATE") "INSERT OR REPLACE INTO contact_search_jobs VALUES(OLD.user);" else ""}
            END""")
        }
    }}
    fun process(limit:Int):Boolean {
        require(limit in 1..128);check(!db.isReadOnly)
        val users=db.rawQuery("SELECT user FROM contact_search_jobs ORDER BY rowid LIMIT ?",arrayOf(limit.toString())).use {r->
            buildList {while(r.moveToNext()) add(UserId(r.getString(0)))}.toPersistentList()
        }
        val values=displays.load(users.map {ProfileKey(it,ProfileContext.Relationship)}.toPersistentList())
        for(user in users) {
            db.execSQL("DELETE FROM contact_search_fts WHERE docid IN (SELECT rowid FROM contact_search_documents WHERE user=?)",arrayOf(user.value))
            db.execSQL("DELETE FROM contact_search_documents WHERE user=?",arrayOf(user.value))
            val value=values.value(ProfileKey(user,ProfileContext.Relationship))
            if(value!=null) {
                db.execSQL("INSERT INTO contact_search_documents VALUES(?)",arrayOf(user.value))
                db.execSQL("INSERT INTO contact_search_fts(docid,name,handle) VALUES((SELECT rowid FROM contact_search_documents WHERE user=?),?,?)",
                    arrayOf(user.value,ContactSearchText.tokens(value.identity.displayName),ContactSearchText.tokens(value.identity.handle.value)))
            }
            db.execSQL("DELETE FROM contact_search_jobs WHERE user=?",arrayOf(user.value))
        }
        return ready()
    }
    private fun ready()=db.rawQuery("SELECT 1 FROM contact_search_jobs LIMIT 1",null).use {!it.moveToFirst()}
    private data class Selection(val base:String,val arguments:List<String>,val query:String)
    private fun selection(viewer:UserId,request:RelationshipPageRequest):Selection {
        require(viewer==actor)
        val query=request.query.trim {android.icu.lang.UCharacter.isUWhiteSpace(it.code)}
        if(query.toByteArray(Charsets.UTF_8).size>100) throw RelationshipPageFailure.InvalidQuery()
        val args=mutableListOf<String>();val clauses=mutableListOf<String>()
        when(request.scope) {
            RelationshipPageScope.Accepted->{clauses+="c.state='accepted'"}
            RelationshipPageScope.Incoming->{clauses+="c.state='pending' AND c.requester<>?";args+=actor.value}
            RelationshipPageScope.Outgoing->{clauses+="c.state='pending' AND c.requester=?";args+=actor.value}
        }
        var join=""
        if(query.isNotEmpty()) {
            val compatible=db.rawQuery("SELECT format FROM contact_search_meta WHERE id=1",null).use {it.moveToFirst() && it.getString(0)==format}
            check(compatible) {"Contact index needs writable reconstruction"}
            if(!ready()) throw RelationshipPageFailure.Building()
            val tokens=ContactSearchText.tokens(query);if(tokens.isEmpty()) throw RelationshipPageFailure.InvalidQuery()
            join="JOIN contact_search_documents d ON d.user=c.id JOIN contact_search_fts ON contact_search_fts.docid=d.rowid"
            clauses+="contact_search_fts MATCH ?";args+="\"$tokens\""
        }
        return Selection("SELECT c.id,c.state,c.requester,c.time FROM contacts c $join WHERE ${clauses.joinToString(" AND ")}",args,query)
    }
    private fun rows(sql:String,args:List<String>):List<Relationship> = db.rawQuery(sql,args.toTypedArray()).use {r->
        buildList {while(r.moveToNext()) {
            require(r.getType(3)==android.database.Cursor.FIELD_TYPE_INTEGER && r.getLong(3)>=0)
            add(Relationship(UserId(r.getString(0)),RelationshipState.fromWire(r.getString(1)),if(r.isNull(2)) null else UserId(r.getString(2)),r.getLong(3)))
        }}
    }
    private fun continuation(value:Relationship,request:RelationshipPageRequest,query:String)=RelationshipCursor(value.target,value.updatedAt,owner,request.scope,query)
    fun page(viewer:UserId,request:RelationshipPageRequest):RelationshipPage {
        val selection=selection(viewer,request);val cursor=request.cursor
        if(cursor!=null && (cursor.owner!=owner || cursor.scope!=request.scope || cursor.query!=selection.query)) throw RelationshipPageFailure.InvalidContinuation()
        val condition=if(cursor==null) "" else " AND (c.time<? OR (c.time=? AND c.id>?))"
        val args=selection.arguments+(cursor?.let {listOf(it.updatedAt.toString(),it.updatedAt.toString(),it.target.value)} ?: emptyList())+(request.limit+1).toString()
        val found=rows(selection.base+condition+" ORDER BY c.time DESC,c.id ASC LIMIT ?",args)
        val page=found.take(request.limit).toPersistentList()
        return RelationshipPage(page,if(found.size>request.limit) continuation(page.last(),request,selection.query) else null)
    }
    fun window(viewer:UserId,request:RelationshipPageRequest,anchor:RelationshipAnchor,precedingCount:Int):RelationshipWindow {
        require(request.cursor==null && precedingCount in 0 until request.limit)
        val selection=selection(viewer,request)
        val current=rows(selection.base+" AND c.id=? LIMIT 1",selection.arguments+anchor.target.value).singleOrNull()
        val position=current?.let {RelationshipAnchor(it.target,it.updatedAt)} ?: anchor
        val time=position.updatedAt.toString();val id=position.target.value;val bound=(request.limit+1).toString()
        fun candidates(earlier:Boolean):List<Relationship> {
            val compare=if(earlier) ">" else "<";val tie=if(earlier) "<" else ">="
            val order=if(earlier) "time ASC,id DESC" else "time DESC,id ASC"
            val first="SELECT * FROM (${selection.base} AND c.time$compare? ORDER BY $order LIMIT ?)"
            val second="SELECT * FROM (${selection.base} AND c.time=? AND c.id$tie? ORDER BY $order LIMIT ?)"
            return rows("SELECT * FROM ($first UNION ALL $second) ORDER BY $order LIMIT ?",
                selection.arguments+listOf(time,bound)+selection.arguments+listOf(time,id,bound,bound))
        }
        val earlier=candidates(true);val later=candidates(false)
        var before=minOf(precedingCount,earlier.size)
        val after=minOf(request.limit-before,later.size)
        before=minOf(request.limit-after,earlier.size)
        val values=(earlier.take(before).asReversed()+later.take(after)).toPersistentList()
        val next=if(later.size>after) continuation(values.last(),request,selection.query) else null
        val resolved=(later.firstOrNull() ?: earlier.firstOrNull())?.let {RelationshipAnchor(it.target,it.updatedAt)}
        return RelationshipWindow(RelationshipPage(values,next),resolved,earlier.size>before)
    }
}
