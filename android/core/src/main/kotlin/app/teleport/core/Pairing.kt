package app.teleport.core

import kotlinx.serialization.Serializable

/**
 * QR payload: `teleport2:<b64u(JSON)>`. See SPEC.md "v2 additions".
 * `ps` (the one-time pairing secret) is only ever in the QR code, never sent over the network.
 */
@Serializable
data class PairingCard(
    val v: Int = 2,
    val name: String,
    val platform: String, // "ios" | "android" | "mac"
    val ka: String,
    val ks: String,
    val fcm: String? = null,
    val la: String? = null,
    val mailbox: String? = null,
    val ps: String? = null,
) {
    /** The card as sent inside `pair` / `pair-ok`: no secret. */
    fun json(): String = TeleportJson.encodeToString(serializer(), copy(ps = null))

    /** The QR payload, including the secret. */
    fun encoded(): String = PREFIX + TeleportJson.encodeToString(serializer(), this).toByteArray().b64u()

    companion object {
        const val PREFIX = "teleport2:"
        val PLATFORMS = setOf("ios", "android", "mac")

        fun decode(s: String): PairingCard {
            if (!s.startsWith(PREFIX)) throw OpenException("encoding")
            val card = try {
                lenientJson.decodeFromString(serializer(), String(s.removePrefix(PREFIX).unb64u()))
            } catch (e: Exception) {
                throw OpenException("encoding")
            }
            if (card.v != 2 || card.platform !in PLATFORMS ||
                card.ka.unb64u().size != 65 || card.ks.unb64u().size != 65
            ) throw OpenException("encoding")
            return card
        }
    }
}

/** A paired device. Public keys and push addresses only — nothing secret. */
@Serializable
data class Peer(
    val name: String,
    val platform: String,
    val ka: String,
    val ks: String,
    val fcm: String? = null,
    val la: String? = null,
    val mailbox: String? = null,
    val pairedAt: Long = System.currentTimeMillis(),
) {
    val kaBytes: ByteArray get() = ka.unb64u()
    val ksBytes: ByteArray get() = ks.unb64u()

    /** `fp(ks)`: the device's identity, and the `from` of every envelope it sends. */
    val id: String get() = TeleportCrypto.fingerprint(ksBytes)

    companion object {
        fun from(card: PairingCard) =
            Peer(card.name, card.platform, card.ka, card.ks, card.fcm, card.la, card.mailbox)
    }
}

/** A device that scanned our QR code and is waiting for the user to tap Allow. */
@Serializable
data class PairRequest(
    val id: String,
    val cardJson: String,
    val name: String,
    val platform: String,
    val expires: Long,
)
