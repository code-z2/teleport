package app.teleport.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Log
import app.teleport.core.JcaAgreementKey
import app.teleport.core.JcaSigningKey
import app.teleport.core.P256
import app.teleport.core.Peer
import app.teleport.core.RelayClient
import app.teleport.core.Teleport
import app.teleport.core.TeleportJson
import app.teleport.core.TeleportStore
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

class TeleportApp : Application() {
    val teleport: Teleport by lazy {
        Teleport(
            agreement = KeystoreKeys.agreement(),
            signing = KeystoreKeys.signing(),
            store = PrefsStore(this),
            relay = RelayClient(BuildConfig.RELAY_URL, BuildConfig.RELAY_KEY),
        )
    }

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Received clips", NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    companion object {
        const val CHANNEL = "clips"
        fun of(context: Context) = context.applicationContext as TeleportApp
    }
}

/**
 * Two non-exportable P-256 keys in Android Keystore — StrongBox when the device has it,
 * otherwise the TEE. Core's JCA wrappers pick the AndroidKeyStore provider automatically.
 */
object KeystoreKeys {
    private const val KA = "teleport.ka"
    private const val KS = "teleport.ks"
    private val keyStore by lazy { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } }

    /** Whether the most recently created/loaded key is StrongBox-backed (for display). */
    var strongBox: Boolean? = null
        private set

    fun agreement() = load(KA, KeyProperties.PURPOSE_AGREE_KEY).let { (priv, pub) -> JcaAgreementKey(priv, pub) }

    fun signing() = load(KS, KeyProperties.PURPOSE_SIGN).let { (priv, pub) -> JcaSigningKey(priv, pub) }

    private fun load(alias: String, purpose: Int): Pair<PrivateKey, ByteArray> {
        if (!keyStore.containsAlias(alias)) generate(alias, purpose)
        val entry = keyStore.getEntry(alias, null) as KeyStore.PrivateKeyEntry
        return entry.privateKey to P256.raw(entry.certificate.publicKey as ECPublicKey)
    }

    private fun generate(alias: String, purpose: Int) {
        fun spec(strongBox: Boolean) = KeyGenParameterSpec.Builder(alias, purpose)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .apply { if (purpose == KeyProperties.PURPOSE_SIGN) setDigests(KeyProperties.DIGEST_SHA256) }
            .setIsStrongBoxBacked(strongBox)
            .build()

        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        try {
            gen.initialize(spec(strongBox = true))
            gen.generateKeyPair()
            strongBox = true
        } catch (e: StrongBoxUnavailableException) {
            Log.w("Teleport", "StrongBox unavailable for $alias, using TEE")
            gen.initialize(spec(strongBox = false))
            gen.generateKeyPair()
            strongBox = false
        } catch (e: java.security.ProviderException) {
            // Some StrongBox implementations don't support AGREE_KEY.
            Log.w("Teleport", "StrongBox rejected $alias (${e.message}), using TEE")
            gen.initialize(spec(strongBox = false))
            gen.generateKeyPair()
            strongBox = false
        }
    }
}

/** Public keys and tokens only — nothing here is secret. */
class PrefsStore(context: Context) : TeleportStore {
    private val prefs = context.getSharedPreferences("teleport", Context.MODE_PRIVATE)

    override var peer: Peer?
        get() = prefs.getString("peer", null)?.let { TeleportJson.decodeFromString(Peer.serializer(), it) }
        set(value) = prefs.edit().putString("peer", value?.let { TeleportJson.encodeToString(Peer.serializer(), it) }).apply()

    override var ownFcmToken: String?
        get() = prefs.getString("fcm", null)
        set(value) = prefs.edit().putString("fcm", value).apply()

    @Synchronized
    override fun markSeen(id: String): Boolean {
        val now = System.currentTimeMillis() / 1000
        val seen = (prefs.getStringSet("seen", emptySet()) ?: emptySet())
            .mapNotNull { it.split(':').takeIf { p -> p.size == 2 }?.let { p -> p[0] to p[1].toLong() } }
            .filter { it.second > now - 86_400 }
        if (seen.any { it.first == id }) return false
        prefs.edit().putStringSet("seen", (seen.map { "${it.first}:${it.second}" } + "$id:$now").toSet()).commit()
        return true
    }
}

val deviceName: String get() = Build.MODEL
