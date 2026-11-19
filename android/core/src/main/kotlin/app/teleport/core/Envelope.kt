package app.teleport.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Teleport wire protocol v1. See protocol/SPEC.md. */
@Serializable
data class Envelope(
    val v: Int,
    val id: String,
    val ts: Long,
    val k: String,
    val from: String,
    val epk: String,
    val n: String,
    val ct: String,
    val sig: String,
) {
    val header: ByteArray get() = "teleport/v1|$id|$ts|$k|$from".toByteArray(Charsets.UTF_8)

    fun toJson(): String = TeleportJson.encodeToString(serializer(), this)

    companion object {
        const val MAX_BYTES = 3000
        val KINDS = setOf(KIND_TEXT, KIND_BLOB, KIND_PEER)
        fun parse(json: String): Envelope = TeleportJson.decodeFromString(serializer(), json)
    }
}

const val KIND_TEXT = "text"
const val KIND_BLOB = "blob"
const val KIND_PEER = "peer"

val TeleportJson = Json { ignoreUnknownKeys = false; explicitNulls = false; encodeDefaults = true }

class OpenException(val code: String) : Exception(code)

/** Plaintext of a `blob` envelope. */
@Serializable
data class BlobPointer(val id: String, val mime: String, val size: Long, val key: String, val n: String)

/** Plaintext of a `peer` envelope. */
@Serializable
data class PeerUpdate(val fcm: String, val la: String? = null, val name: String? = null)

object TeleportCrypto {
    private val INFO = "teleport/v1/aes-256-gcm".toByteArray()
    val BLOB_AAD = "teleport/v1/blob".toByteArray()

    fun fingerprint(pub: ByteArray): String = Primitives.sha256(pub).copyOf(8).b64u()

    fun deriveKey(sharedSecret: ByteArray, epk: ByteArray, recipientKa: ByteArray): ByteArray =
        Primitives.hkdfSha256(sharedSecret, epk + recipientKa, INFO, 32)

    /** `id`, `ts`, `ephemeral` and `nonce` are only passed explicitly by tests. */
    fun seal(
        kind: String,
        plaintext: ByteArray,
        signer: SigningKey,
        recipientKa: ByteArray,
        id: ByteArray = randomBytes(16),
        ts: Long = System.currentTimeMillis() / 1000,
        ephemeral: AgreementKey? = null,
        nonce: ByteArray = randomBytes(12),
    ): Envelope {
        require(kind in Envelope.KINDS)
        val eph = ephemeral ?: P256.generate().let { JcaAgreementKey(it.private, P256.raw(it.public as java.security.interfaces.ECPublicKey)) }
        val epk = eph.publicKey
        val key = deriveKey(eph.sharedSecret(recipientKa), epk, recipientKa)
        val unsigned = Envelope(1, id.b64u(), ts, kind, fingerprint(signer.publicKey), epk.b64u(), nonce.b64u(), "", "")
        val ct = Primitives.aesGcm(true, key, nonce, plaintext, unsigned.header)
        val sig = signer.sign(unsigned.header + epk + nonce + ct)
        return unsigned.copy(ct = ct.b64u(), sig = sig.b64u())
    }

    /** Verify signature → freshness → decrypt. Replay checks are the caller's job. */
    fun open(env: Envelope, ownKa: AgreementKey, senderKs: ByteArray, now: Long = System.currentTimeMillis() / 1000): ByteArray {
        if (env.v != 1) throw OpenException("version")
        if (env.k !in Envelope.KINDS) throw OpenException("kind")
        if (env.from != fingerprint(senderKs)) throw OpenException("peer")
        val (epk, n, ct, sig) = try {
            listOf(env.epk.unb64u(), env.n.unb64u(), env.ct.unb64u(), env.sig.unb64u())
        } catch (e: IllegalArgumentException) {
            throw OpenException("encoding")
        }
        if (!Primitives.verify(senderKs, env.header + epk + n + ct, sig)) throw OpenException("signature")
        if (env.ts < now - 86_400 || env.ts > now + 300) throw OpenException("stale")
        val key = deriveKey(ownKa.sharedSecret(epk), epk, ownKa.publicKey)
        return try {
            Primitives.aesGcm(false, key, n, ct, env.header)
        } catch (e: java.security.GeneralSecurityException) {
            throw OpenException("decrypt")
        }
    }

    class SealedBlob(val ciphertext: ByteArray, val key: ByteArray, val nonce: ByteArray)

    fun sealBlob(bytes: ByteArray): SealedBlob {
        val key = randomBytes(32)
        val nonce = randomBytes(12)
        return SealedBlob(Primitives.aesGcm(true, key, nonce, bytes, BLOB_AAD), key, nonce)
    }

    fun openBlob(ciphertext: ByteArray, key: ByteArray, nonce: ByteArray): ByteArray =
        try {
            Primitives.aesGcm(false, key, nonce, ciphertext, BLOB_AAD)
        } catch (e: java.security.GeneralSecurityException) {
            throw OpenException("decrypt")
        }
}
