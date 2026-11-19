package app.teleport.core

import kotlinx.serialization.Serializable

/** QR payload: `teleport1:<b64u(JSON)>`. */
@Serializable
data class PairingCard(
    val v: Int = 1,
    val name: String,
    val platform: String, // "ios" | "android"
    val ka: String,
    val ks: String,
    val fcm: String,
    val la: String? = null,
) {
    fun encoded(): String = PREFIX + TeleportJson.encodeToString(serializer(), this).toByteArray().b64u()

    companion object {
        const val PREFIX = "teleport1:"

        fun decode(s: String): PairingCard {
            if (!s.startsWith(PREFIX)) throw OpenException("encoding")
            val card = try {
                TeleportJson.decodeFromString(serializer(), String(s.removePrefix(PREFIX).unb64u()))
            } catch (e: Exception) {
                throw OpenException("encoding")
            }
            if (card.v != 1 || card.platform !in setOf("ios", "android") ||
                card.ka.unb64u().size != 65 || card.ks.unb64u().size != 65
            ) throw OpenException("encoding")
            return card
        }
    }
}

/** The one paired device. Public keys/tokens only — nothing secret. */
@Serializable
data class Peer(
    val name: String,
    val platform: String,
    val ka: String,
    val ks: String,
    val fcm: String,
    val la: String? = null,
) {
    val kaBytes: ByteArray get() = ka.unb64u()
    val ksBytes: ByteArray get() = ks.unb64u()

    companion object {
        fun from(card: PairingCard) = Peer(card.name, card.platform, card.ka, card.ks, card.fcm, card.la)
    }
}
