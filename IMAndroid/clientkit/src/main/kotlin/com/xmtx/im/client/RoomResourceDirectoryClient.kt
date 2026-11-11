package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.serialization.SerializationException

enum class ResourceDirectoryFailureReason { AuthorizationUnavailable,NotVisible,InvalidCursor,Unavailable,InvalidResponse }
class ResourceDirectoryFailure(val reason: ResourceDirectoryFailureReason,val status: Int?=null,val retryAfter: String?=null): Exception("Resource directory $reason")
fun interface RoomResourceDirectoryReading {
    suspend fun query(room: RoomId,query: RoomResourceQuery): RoomResourcePage
}
/** Authorized metadata only. A listed resource still requires independent authorization to read or import. */
class RoomResourceDirectoryClient(private val api: AuthenticatedTransport): RoomResourceDirectoryReading {
    override suspend fun query(room: RoomId,query: RoomResourceQuery): RoomResourcePage=withTimeout(15000) {
        val response=try { api.requestWithoutReplay("/v2/rooms/${uuidId(room.value)}/resources/query",query.payload(),512*1024) }
        catch(_: ClientFailure.Protocol) { throw ResourceDirectoryFailure(ResourceDirectoryFailureReason.InvalidResponse) }
        catch(_: SerializationException) { throw ResourceDirectoryFailure(ResourceDirectoryFailureReason.InvalidResponse) }
        currentCoroutineContext().ensureActive()
        if(response.status!=200) throw ResourceDirectoryFailure(when(response.status) {
            401->ResourceDirectoryFailureReason.AuthorizationUnavailable
            403,404->ResourceDirectoryFailureReason.NotVisible
            400->ResourceDirectoryFailureReason.InvalidCursor
            429,in 500..599->ResourceDirectoryFailureReason.Unavailable
            else->ResourceDirectoryFailureReason.InvalidResponse
        },response.status,response.retryAfter)
        try { RoomResourcePage.decode(response.body).also { it.boundTo(room,query) } }
        catch(error: CancellationException) { throw error }
        catch(_: Exception) { throw ResourceDirectoryFailure(ResourceDirectoryFailureReason.InvalidResponse) }
    }
}
