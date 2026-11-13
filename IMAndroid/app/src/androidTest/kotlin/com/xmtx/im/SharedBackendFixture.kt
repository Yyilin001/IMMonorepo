package com.xmtx.im

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Isolated backend setup only. No production business, local store or realtime implementation. */
internal class SharedBackendFixture(private val base: String) {
    class Account(val userID: String, val deviceID: String, internal val token: String) {
        override fun toString() = "FixtureAccount(<redacted>)"
    }
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .retryOnConnectionFailure(false).callTimeout(15, TimeUnit.SECONDS).build()
    private suspend fun post(path: String, body: JSONObject, account: Account? = null): JSONObject = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(base + path).post(body.toString().toRequestBody("application/json".toMediaType()))
            .header("Cache-Control", "no-store").apply {
                account?.let { header("Authorization", "Bearer " + it.token); header("X-IM-Device-ID", it.deviceID) }
            }.build()
        http.newCall(request).execute().use { response ->
            check(response.code == 200) { "Fixture HTTP status ${response.code}" }
            val source = response.body!!.source()
            check(!source.request(1_048_577)) { "Fixture response exceeds limit" }
            JSONObject(source.readUtf8())
        }
    }
    suspend fun register(name: String, password: String): Account {
        val device = UUID.randomUUID().toString().uppercase()
        val operation = UUID.randomUUID().toString().uppercase()
        val registration = post("/v2/account-auth/password/register", JSONObject().put("accountHandle", name)
            .put("publicHandle", name).put("displayName", name).put("password", password).put("deviceID", device))
        val proof = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val cancellation = JSONObject().put("deviceID", wire(device)).put("operationID", operation)
            .put("proof", "imv2-cancel-registration-v1." + Base64.getUrlEncoder().withoutPadding().encodeToString(proof))
            .put("issueBeforeMilliseconds", System.currentTimeMillis() + 600_000)
        val result = post("/v2/device-credentials", JSONObject().put("accountAssertion", registration.getString("accountAssertion"))
            .put("deviceID", device).put("operationID", operation).put("cancellation", cancellation))
        return Account(result.getString("userID"), result.getString("deviceID"), result.getString("accessToken"))
    }
    suspend fun direct(actor: Account, target: Account): String {
        val result = post("/v2/direct-room-operations/submit", JSONObject().put("actorUserID", wire(actor.userID))
            .put("targetUserID", wire(target.userID)).put("operationID", wire(UUID.randomUUID().toString().uppercase()))
            .put("firstSubmissionDeadlineMilliseconds", System.currentTimeMillis() + 60_000), actor)
        return result.getJSONObject("receipt").getJSONObject("_0").getJSONObject("outcome")
            .getJSONObject("opened").getJSONObject("roomID").getString("rawValue")
    }
    /** Real upload/processing/profile mutation used only to prepare the other user's avatar. */
    suspend fun avatar(account: Account, color: Int): String {
        val bitmap = android.graphics.Bitmap.createBitmap(128, 128, android.graphics.Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(color)
        val bytes = java.io.ByteArrayOutputStream().use { out -> bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out); out.toByteArray() }
        bitmap.recycle()
        val media = UUID.randomUUID().toString().uppercase()
        val checksum = java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        var session = post("/v2/resource-uploads", JSONObject().put("operationID", wire(UUID.randomUUID().toString().uppercase()))
            .put("mediaID", wire(media)).put("usage", JSONObject().put("userAvatar", JSONObject())).put("contentType", "image/png")
            .put("byteCount", bytes.size).put("checksum", JSONObject().put("algorithm", "sha256").put("value", checksum))
            .put("clientModes", org.json.JSONArray().put("http_put")).put("displayName", "fixture.png"), account)
        val plans = org.json.JSONArray(fixtureRequest("POST", "/v2/resource-uploads/targets", JSONObject().put("locator", session.getJSONObject("locator"))
            .put("generation", session.getLong("generation")).put("background", false).put("partNumbers", org.json.JSONArray()), account))
        check(plans.length() == 1)
        val plan = plans.getJSONObject(0)
        withContext(Dispatchers.IO) {
            val request = Request.Builder().url(plan.getString("url")).put(bytes.toRequestBody("image/png".toMediaType()))
            val headers = plan.getJSONArray("headers")
            for (index in 0 until headers.length()) { val header = headers.getJSONObject(index); request.header(header.getString("name"), header.getString("value")) }
            http.newCall(request.build()).execute().use { check(it.isSuccessful) { "Fixture byte upload status ${it.code}" } }
        }
        session = post("/v2/resource-uploads/finalize", JSONObject().put("locator", session.getJSONObject("locator")).put("generation", session.getLong("generation")).put("parts", session.getJSONArray("confirmedParts")), account)
        kotlinx.coroutines.withTimeout(30000) { while (session.getString("resourceState") != "ready") { kotlinx.coroutines.delay(200); session = post("/v2/resource-uploads/status", session.getJSONObject("locator"), account) } }
        val profile = JSONObject(fixtureRequest("GET", "/v2/profile/me", null, account))
        val result = JSONObject(fixtureRequest("PUT", "/v2/profile/me", JSONObject().put("operation_id", UUID.randomUUID().toString().uppercase())
            .put("expected_revision", profile.getLong("revision")).put("first_submission_deadline_ms", System.currentTimeMillis() + 60000)
            .put("patch", JSONObject().put("displayName", JSONObject().put("unchanged", JSONObject())).put("avatar", JSONObject().put("set", JSONObject().put("_0", JSONObject().put("mediaID", wire(media)))))), account))
        check(result.getJSONObject("receipt").getJSONObject("outcome").has("committed"))
        return media
    }
    private suspend fun fixtureRequest(method: String, path: String, body: JSONObject?, account: Account): String = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(base + path).method(method, body?.toString()?.toRequestBody("application/json".toMediaType()))
            .header("Authorization", "Bearer " + account.token).header("X-IM-Device-ID", account.deviceID).build()
        http.newCall(request).execute().use { response ->
            check(response.code == 200) { "Fixture HTTP status ${response.code} at $path" }
            val source = response.body!!.source(); check(!source.request(1_048_577)); source.readUtf8()
        }
    }
    private fun wire(value: String) = JSONObject().put("rawValue", value)
}
