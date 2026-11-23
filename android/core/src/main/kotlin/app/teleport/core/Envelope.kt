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
        val KINDS = setOf(KIND_TEXT, KIND_BLOB, KIND_PEER, KIND_PAIR, KIND_PAIR_OK, KIND_PAIR_NO)
        fun parse(json: String): Envelope = TeleportJson.decodeFromString(serializer(), json)
    }
}

const val KIND_TEXT = "text"
const val KIND_BLOB = "blob"
const val KIND_PEER = "peer"
const val KIND_PAIR = "pair"
const val KIND_PAIR_OK = "pair-ok"
const val KIND_PAIR_NO = "pair-no"

val TeleportJson = Json { ignoreUnknownKeys = false; explicitNulls = false; encodeDefaults = true }

/** For cards from other devices: newer versions may add fields. */
val lenientJson = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

class OpenException(val code: String) : Exception(code)

/** Plaintext of a `blob` envelope. */
@Serializable
data class BlobPointer(
    val id: String, val mime: String, val size: Long, val key: String, val n: String,
    /** Plaintext chunk size of a chunked (large) blob; null for the single-box format. */
    val c: Long? = null,
    /** The original file name, for files. */
    val name: String? = null,
) {
    val isChunked: Boolean get() = c != null
}

/**
 * Large blobs (SPEC.md "Large blobs"): AES-GCM per chunk, with the chunk index and a
 * final-chunk marker authenticated, so the stream can't be reordered or cut short.
 */
object ChunkedBlob {
    const val CHUNK = 4 * 1024 * 1024
    const val MAX_SIZE = 250L * 1024 * 1024
    /** Multipart part size: R2 needs equal parts (≥ 5 MiB) except the last. */
    const val PART = 16 * 1024 * 1024

    fun count(size: Long, chunk: Long = CHUNK.toLong()): Int = maxOf(1L, (size + chunk - 1) / chunk).toInt()

    private fun nonce(n: ByteArray, i: Int): ByteArray {
        val out = n.copyOf()
        val buf = java.nio.ByteBuffer.wrap(out)
        buf.putLong(4, buf.getLong(4) xor i.toLong())
        return out
    }

    private fun aad(i: Int, last: Boolean): ByteArray =
        TeleportCrypto.BLOB_AAD + java.nio.ByteBuffer.allocate(9).putLong(i.toLong()).put(if (last) 1 else 0).array()

    fun seal(chunk: ByteArray, index: Int, last: Boolean, key: ByteArray, n: ByteArray): ByteArray =
        Primitives.aesGcm(true, key, nonce(n, index), chunk, aad(index, last))

    fun open(sealed: ByteArray, index: Int, last: Boolean, key: ByteArray, n: ByteArray): ByteArray = try {
        Primitives.aesGcm(false, key, nonce(n, index), sealed, aad(index, last))
    } catch (e: java.security.GeneralSecurityException) {
        throw OpenException("decrypt")
    }

    /** Whole-buffer helpers (tests, small inputs). */
    fun seal(bytes: ByteArray, key: ByteArray, n: ByteArray, chunk: Int = CHUNK): ByteArray {
        val total = count(bytes.size.toLong(), chunk.toLong())
        val out = java.io.ByteArrayOutputStream()
        for (i in 0 until total) {
            val lo = i * chunk
            out.write(seal(bytes.copyOfRange(lo, minOf(lo + chunk, bytes.size)), i, i == total - 1, key, n))
        }
        return out.toByteArray()
    }

    fun open(ct: ByteArray, size: Long, key: ByteArray, n: ByteArray, chunk: Int = CHUNK): ByteArray {
        val total = count(size, chunk.toLong())
        if (ct.size.toLong() != size + 16L * total) throw OpenException("decrypt")
        val out = java.io.ByteArrayOutputStream()
        var offset = 0
        for (i in 0 until total) {
            val plain = if (i == total - 1) (size - i.toLong() * chunk).toInt() else chunk
            out.write(open(ct.copyOfRange(offset, offset + plain + 16), i, i == total - 1, key, n))
            offset += plain + 16
        }
        return out.toByteArray()
    }
}

/** Plaintext of a `peer` envelope: renamed or new push address. Missing fields keep their old values. */
@Serializable
data class PeerUpdate(val name: String? = null, val fcm: String? = null, val la: String? = null, val mailbox: String? = null)

/** Plaintext of a `pair` envelope. The card is a string so the proof covers exact bytes. */
@Serializable
data class PairBody(val card: String, val proof: String)

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

    // ---------- pairing v2 (SPEC.md "v2 additions") ----------

    fun pairProof(secret: ByteArray, cardJson: String): ByteArray =
        javax.crypto.Mac.getInstance("HmacSHA256").run {
            init(javax.crypto.spec.SecretKeySpec(secret, "HmacSHA256"))
            doFinal(cardJson.toByteArray(Charsets.UTF_8))
        }

    fun pairPlaintext(cardJson: String, proof: ByteArray): ByteArray =
        TeleportJson.encodeToString(PairBody.serializer(), PairBody(cardJson, proof.b64u())).toByteArray(Charsets.UTF_8)

    class OpenedPair(val card: PairingCard, val json: String)

    /**
     * Opens a `pair` envelope from a device that isn't paired yet: decrypt, then check the
     * signature against the key in the card it carries, then the proof against our QR secret.
     */
    fun openPair(env: Envelope, ownKa: AgreementKey, secret: ByteArray, now: Long = System.currentTimeMillis() / 1000): OpenedPair {
        if (env.v != 1) throw OpenException("version")
        if (env.k != KIND_PAIR) throw OpenException("kind")
        val (epk, n, ct, sig) = try {
            listOf(env.epk.unb64u(), env.n.unb64u(), env.ct.unb64u(), env.sig.unb64u())
        } catch (e: IllegalArgumentException) {
            throw OpenException("encoding")
        }
        val pt = try {
            Primitives.aesGcm(false, deriveKey(ownKa.sharedSecret(epk), epk, ownKa.publicKey), n, ct, env.header)
        } catch (e: java.security.GeneralSecurityException) {
            throw OpenException("decrypt")
        }
        val (body, card) = try {
            val body = TeleportJson.decodeFromString(PairBody.serializer(), String(pt, Charsets.UTF_8))
            body to lenientJson.decodeFromString(PairingCard.serializer(), body.card)
        } catch (e: Exception) {
            throw OpenException("encoding")
        }
        val ks = try { card.ks.unb64u().also { require(it.size == 65) } } catch (e: Exception) { throw OpenException("encoding") }
        if (env.from != fingerprint(ks)) throw OpenException("peer")
        if (!Primitives.verify(ks, env.header + epk + n + ct, sig)) throw OpenException("signature")
        if (env.ts < now - 86_400 || env.ts > now + 300) throw OpenException("stale")
        val proof = try { body.proof.unb64u() } catch (e: Exception) { throw OpenException("encoding") }
        if (!java.security.MessageDigest.isEqual(pairProof(secret, body.card), proof)) throw OpenException("proof")
        return OpenedPair(card, body.card)
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
