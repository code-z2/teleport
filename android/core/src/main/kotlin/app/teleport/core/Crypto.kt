package app.teleport.core

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// ---------- encoding ----------

fun ByteArray.b64u(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(this)

fun String.unb64u(): ByteArray {
    require(all { it.isLetterOrDigit() || it == '-' || it == '_' }) { "not base64url" }
    return Base64.getUrlDecoder().decode(this)
}

private val random = SecureRandom()

fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

// ---------- P-256 helpers ----------

object P256 {
    val params: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").run {
            init(ECGenParameterSpec("secp256r1"))
            getParameterSpec(ECParameterSpec::class.java)
        }
    }

    /** 65-byte uncompressed SEC1 point → JCA public key. */
    fun publicKey(raw: ByteArray): ECPublicKey {
        require(raw.size == 65 && raw[0] == 0x04.toByte()) { "expected 65-byte uncompressed P-256 point" }
        val point = ECPoint(BigInteger(1, raw.copyOfRange(1, 33)), BigInteger(1, raw.copyOfRange(33, 65)))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, params)) as ECPublicKey
    }

    fun raw(pub: ECPublicKey): ByteArray =
        byteArrayOf(0x04) + pub.w.affineX.toFixed32() + pub.w.affineY.toFixed32()

    fun privateKey(d: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, d), params))

    fun generate(): java.security.KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    private fun BigInteger.toFixed32(): ByteArray {
        val b = toByteArray()
        return when {
            b.size == 32 -> b
            b.size > 32 -> b.copyOfRange(b.size - 32, b.size) // strip sign byte
            else -> ByteArray(32 - b.size) + b
        }
    }

    // ECDSA: JCA (and Android Keystore) produce DER; the protocol uses raw r‖s.
    fun derToRaw(der: ByteArray): ByteArray {
        var i = 2
        if (der[1].toInt() and 0x80 != 0) i += der[1].toInt() and 0x7f
        fun readInt(): BigInteger {
            check(der[i] == 0x02.toByte()); val len = der[i + 1].toInt(); val v = der.copyOfRange(i + 2, i + 2 + len)
            i += 2 + len; return BigInteger(1, v)
        }
        return readInt().toFixed32() + readInt().toFixed32()
    }

    fun rawToDer(raw: ByteArray): ByteArray {
        require(raw.size == 64)
        fun enc(x: ByteArray): ByteArray {
            val v = BigInteger(1, x).toByteArray() // minimal two's-complement, positive
            return byteArrayOf(0x02, v.size.toByte()) + v
        }
        val body = enc(raw.copyOfRange(0, 32)) + enc(raw.copyOfRange(32, 64))
        return byteArrayOf(0x30, body.size.toByte()) + body
    }
}

// ---------- keys ----------

interface AgreementKey {
    /** 65-byte uncompressed point. */
    val publicKey: ByteArray
    /** Raw ECDH secret (x coordinate, 32 bytes). */
    fun sharedSecret(peer: ByteArray): ByteArray
}

interface SigningKey {
    val publicKey: ByteArray
    /** ECDSA P-256/SHA-256, raw r‖s (64 bytes). */
    fun sign(data: ByteArray): ByteArray
}

/**
 * Works for software keys *and* Android Keystore keys: JCA picks the
 * AndroidKeyStore provider automatically when [privateKey] lives there.
 */
class JcaAgreementKey(private val privateKey: PrivateKey, override val publicKey: ByteArray) : AgreementKey {
    override fun sharedSecret(peer: ByteArray): ByteArray =
        KeyAgreement.getInstance("ECDH").run {
            init(privateKey)
            doPhase(P256.publicKey(peer), true)
            generateSecret()
        }
}

class JcaSigningKey(private val privateKey: PrivateKey, override val publicKey: ByteArray) : SigningKey {
    override fun sign(data: ByteArray): ByteArray =
        P256.derToRaw(Signature.getInstance("SHA256withECDSA").run { initSign(privateKey); update(data); sign() })
}

// ---------- primitives ----------

object Primitives {
    fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)

    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        var t = ByteArray(0)
        val out = java.io.ByteArrayOutputStream()
        var counter = 1
        while (out.size() < length) {
            mac.update(t); mac.update(info); mac.update(counter.toByte())
            t = mac.doFinal(); out.write(t); counter++
        }
        return out.toByteArray().copyOf(length)
    }

    fun aesGcm(encrypt: Boolean, key: ByteArray, nonce: ByteArray, data: ByteArray, aad: ByteArray): ByteArray =
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            updateAAD(aad)
            doFinal(data)
        }

    fun verify(publicKey: ByteArray, data: ByteArray, rawSig: ByteArray): Boolean = runCatching {
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(P256.publicKey(publicKey)); update(data); verify(P256.rawToDer(rawSig))
        }
    }.getOrDefault(false)
}
