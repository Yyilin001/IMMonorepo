package com.xmtx.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.*
import java.util.UUID

/** Non-secret local ownership marker. It grants neither remote authentication nor display leases. */
data class LocalInstallationBinding(val value: String) {
    init { require(uuidId(value) == value) }
    companion object { fun create() = LocalInstallationBinding(UUID.randomUUID().toString().uppercase()) }
}

class LocalStoreFailure(val reason: Reason) : Exception("Local storage: ${reason.name}") {
    enum class Reason { BindingUnavailable, BindingMalformed, BindingInvalidated, BindingMismatch, StoreUnavailable }
}

interface InstallationBindingStore {
    suspend fun load(): LocalInstallationBinding?
    suspend fun save(binding: LocalInstallationBinding)
    suspend fun delete()
}

/** Non-secret evidence for one damaged record; never a credential or database ownership grant. */
data class InstallationBindingDamage(val reason: LocalStoreFailure.Reason, val revision: String) {
    init {
        require(reason == LocalStoreFailure.Reason.BindingMalformed || reason == LocalStoreFailure.Reason.BindingInvalidated)
        require(revision.matches(Regex("[0-9a-f]{64}")))
    }
}

/** Optional platform capability. Recheck the exact damage before replacing only this binding key. */
interface InstallationBindingRepairing : InstallationBindingStore {
    suspend fun inspectDamage(): InstallationBindingDamage?
    suspend fun replaceDamagedBinding(expected: InstallationBindingDamage, replacement: LocalInstallationBinding)
}

/** Separate encrypted record from the rotating account credential journal. */
class SecretInstallationBindingStore(private val secret: SecretStore) : InstallationBindingStore {
    override suspend fun load(): LocalInstallationBinding? {
        val record = access { secret.read() } ?: return null
        try {
            require(record.length <= 256)
            val value = Json.parseToJsonElement(record).jsonObject
            require(value.keys == setOf("format", "binding"))
            val format = value.getValue("format").jsonPrimitive
            val binding = value.getValue("binding").jsonPrimitive
            require(!format.isString && format.intOrNull == 1 && binding.isString)
            return LocalInstallationBinding(binding.content)
        } catch (_: Exception) { throw LocalStoreFailure(LocalStoreFailure.Reason.BindingMalformed) }
    }
    override suspend fun save(binding: LocalInstallationBinding) = access {
        secret.write(buildJsonObject { put("format", 1); put("binding", binding.value) }.toString())
    }
    override suspend fun delete() = access { secret.delete() }

    private suspend fun <T> access(body: suspend () -> T): T = try { body() }
    catch (error: CancellationException) { throw error }
    catch (error: LocalStoreFailure) { throw error }
    catch (_: Exception) { throw LocalStoreFailure(LocalStoreFailure.Reason.BindingUnavailable) }
}
