package com.xmtx.im.client

import kotlinx.serialization.json.*
import java.text.Normalizer
import java.util.Locale

@JvmInline value class PublicHandle private constructor(val value: String) {
    companion object {
        operator fun invoke(input: String): PublicHandle {
            val canonical = input.removePrefix("@").lowercase(Locale.ROOT)
            require(canonical.matches(Regex("[a-z0-9_]{3,32}"))) { "公开标识需为 3–32 位字母、数字或下划线" }
            return PublicHandle(canonical)
        }
    }
}
enum class AccountKind { Regular, System, CustomerSupport }
@kotlinx.serialization.Serializable(with = PublicIdentitySerializer::class)
data class PublicIdentity(val user: UserId, val handle: PublicHandle, val displayName: String, val kind: AccountKind) {
    init {
        require(displayName.isNotEmpty() && displayName.toByteArray(Charsets.UTF_8).size <= 80)
        require(displayName.codePoints().allMatch { !Character.isISOControl(it) && Character.getType(it) != Character.FORMAT.toInt() &&
            (!(Character.isWhitespace(it) || Character.isSpaceChar(it)) || it == 32) })
    }
}
/** Memory-only permission for one active lookup page. Never store it in saved state or a contact repository. */
data class IdentityLookup(val identity: PublicIdentity, val deadlineNanos: Long) {
    fun valid(nowNanos: Long = System.nanoTime()) = deadlineNanos - nowNanos > 0
}
class PublicIdentityDirectory(private val transport: AuthenticatedTransport, private val account: UserId,
    private val device: DeviceId, private val nanoTime: () -> Long = System::nanoTime) {
    suspend fun resolve(input: String): IdentityLookup {
        val started = nanoTime()
        val handle = PublicHandle(input)
        val response = transport.request("/v2/public-identities/resolve", query = "handle" to handle.value, maximumBytes = 8_192)
        if (response.status != 200) throw response.failure()
        val body = response.body
        if (UserId(body.identifier("actorUserID")) != account || DeviceId(body.identifier("deviceID")) != device) throw ClientFailure.Protocol()
        val value = body.objectValue("identity")
        val rawHandle = value.identifier("handle")
        if (rawHandle != handle.value) throw ClientFailure.Protocol()
        val name = Normalizer.normalize(value.string("displayName"), Normalizer.Form.NFC).trim { it.isWhitespace() }
        val kind = when (value.string("accountKind")) { "regular" -> AccountKind.Regular; "system" -> AccountKind.System; "customer_support" -> AccountKind.CustomerSupport; else -> throw ClientFailure.Protocol() }
        val identity = PublicIdentity(UserId(value.identifier("userID")), handle, name, kind)
        val observed = body.number("observedAtUnixMilliseconds")
        val until = body.number("validUntilUnixMilliseconds")
        val serverNow = body.number("serverNowUnixMilliseconds")
        val lifetime = try { Math.subtractExact(until, observed) } catch (_: ArithmeticException) { throw ClientFailure.Protocol() }
        if (lifetime !in 1..60_000 || observed > serverNow || serverNow >= until) throw ClientFailure.Protocol()
        val remaining = (until - serverNow) * 1_000_000
        val received = nanoTime()
        val elapsed = received - started
        if (elapsed < 0 || elapsed >= remaining) throw ClientFailure.Protocol()
        return IdentityLookup(identity, received + remaining - elapsed)
    }
}

internal fun JsonObject.objectValue(key: String): JsonObject = get(key) as? JsonObject ?: throw ClientFailure.Protocol()
internal fun JsonObject.identifier(key: String): String = objectValue(key).string("rawValue")
internal fun wireId(value: String) = buildJsonObject { put("rawValue", value) }
internal fun uuidId(value: String): String {
    val canonical = canonicalId(value)
    require(canonical.matches(Regex("[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")))
    return canonical
}
