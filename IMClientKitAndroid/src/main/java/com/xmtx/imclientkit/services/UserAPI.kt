package com.xmtx.imclientkit.services

import com.xmtx.imclientkit.features.contacts.ContactCreateRequestBody
import com.xmtx.imclientkit.features.contacts.ContactRequestAcceptRequestBody
import com.xmtx.imclientkit.features.contacts.ContactRequestBox
import com.xmtx.imclientkit.features.contacts.ContactRequestCreateRequestBody
import com.xmtx.imclientkit.features.contacts.ContactUpdateRequestBody
import com.xmtx.imclientkit.networking.HTTPQueryItem
import com.xmtx.imclientkit.networking.HTTPRequestSpec
import com.xmtx.imclientkit.networking.JsonConfiguration
import io.ktor.http.HttpMethod
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class UserAPI(
    private val json: Json = JsonConfiguration.default,
) {
    fun me(): HTTPRequestSpec = HTTPRequestSpec(path = "api/me")

    fun contacts(): HTTPRequestSpec = HTTPRequestSpec(path = "api/contacts")

    fun addContact(email: String, remark: String? = null): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/contacts",
            method = HttpMethod.Post,
            body = json.encodeToString(ContactCreateRequestBody(email = email, remark = remark)),
        )

    fun updateContact(contactUserID: String, remark: String?): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/contacts/$contactUserID",
            method = HttpMethod.Patch,
            body = json.encodeToString(ContactUpdateRequestBody(remark = remark)),
        )

    fun deleteContact(contactUserID: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/contacts/$contactUserID",
            method = HttpMethod.Delete,
        )

    fun contactRequests(box: ContactRequestBox = ContactRequestBox.All): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/contact-requests",
            queryItems = listOf(HTTPQueryItem("box", box.rawValue)),
        )

    fun sendContactRequest(
        email: String,
        message: String? = null,
        remark: String? = null,
    ): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/contact-requests",
            method = HttpMethod.Post,
            body = json.encodeToString(
                ContactRequestCreateRequestBody(
                    email = email,
                    message = message,
                    remark = remark,
                ),
            ),
        )

    fun acceptContactRequest(requestID: String, remark: String? = null): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/contact-requests/$requestID/accept",
            method = HttpMethod.Post,
            body = json.encodeToString(ContactRequestAcceptRequestBody(remark = remark)),
        )

    fun declineContactRequest(requestID: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/contact-requests/$requestID/decline",
            method = HttpMethod.Post,
        )

    fun cancelContactRequest(requestID: String): HTTPRequestSpec =
        HTTPRequestSpec(
            path = "api/contact-requests/$requestID/cancel",
            method = HttpMethod.Post,
        )
}
