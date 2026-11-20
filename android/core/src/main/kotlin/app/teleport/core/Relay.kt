package app.teleport.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.net.HttpURLConnection
import java.net.URI

class RelayException(val status: Int, message: String) : Exception(message)

/** 410 from the relay: the peer's push token is dead. */
class PeerGoneException : Exception("peer push token is no longer valid")

/** Blocking HTTP client (call from Dispatchers.IO). HttpURLConnection keeps core dependency-free. */
class RelayClient(private val baseUrl: String, private val relayKey: String) {

    private fun call(method: String, path: String, body: ByteArray? = null, contentType: String? = null): ByteArray {
        val conn = URI(baseUrl.trimEnd('/') + path).toURL().openConnection() as HttpURLConnection
        try {
            conn.requestMethod = method
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.setRequestProperty("Authorization", "Bearer $relayKey")
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", contentType)
                conn.setFixedLengthStreamingMode(body.size)
                conn.outputStream.use { it.write(body) }
            }
            val status = conn.responseCode
            val stream = if (status in 200..299) conn.inputStream else conn.errorStream
            val bytes = stream?.use { it.readBytes() } ?: ByteArray(0)
            if (status == 410) throw PeerGoneException()
            if (status !in 200..299) throw RelayException(status, String(bytes))
            return bytes
        } finally {
            conn.disconnect()
        }
    }

    fun send(env: Envelope, to: Peer) {
        // Macs are reached through their relay mailbox (phase 2); phones by push.
        val fcm = to.fcm?.takeIf { it.isNotEmpty() } ?: throw RelayException(0, "${to.name} has no push address yet")
        val body = buildJsonObject {
            put("to", buildJsonObject {
                put("platform", to.platform)
                put("fcm", fcm)
                if (to.platform == "ios" && to.la != null) put("la", to.la)
            })
            put("env", Json.parseToJsonElement(env.toJson()))
        }
        call("POST", "/v1/send", body.toString().toByteArray(), "application/json")
    }

    fun putBlob(ciphertext: ByteArray): String {
        val res = call("PUT", "/v1/blob", ciphertext, "application/octet-stream")
        return Json.parseToJsonElement(String(res)).jsonObject["id"]!!.jsonPrimitive.content
    }

    fun getBlob(id: String): ByteArray = call("GET", "/v1/blob/$id")

    fun deleteBlob(id: String) {
        call("DELETE", "/v1/blob/$id")
    }
}
