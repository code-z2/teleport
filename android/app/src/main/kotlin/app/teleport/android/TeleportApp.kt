package app.teleport.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.provider.Settings
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
import app.teleport.core.PairRequest
import app.teleport.core.b64u
import app.teleport.core.randomBytes
import app.teleport.core.unb64u
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
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

    /** Pinged when pushes change what the main screen shows (pairing requests, devices). */
    val changes = kotlinx.coroutines.flow.MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    fun changed() {
        changes.tryEmit(Unit)
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
class PrefsStore(private val context: Context) : TeleportStore {
    private val prefs = context.getSharedPreferences("teleport", Context.MODE_PRIVATE)

    init {
        // v1 stored a single "peer". v2 pairings are incompatible: drop it (re-pair once).
        if (prefs.contains("peer")) prefs.edit().remove("peer").apply()
    }

    private fun <T> readMap(key: String, serializer: KSerializer<T>): Map<String, T> =
        prefs.getString(key, null)?.let {
            runCatching { TeleportJson.decodeFromString(MapSerializer(String.serializer(), serializer), it) }.getOrNull()
        } ?: emptyMap()

    private fun <T> writeMap(key: String, serializer: KSerializer<T>, value: Map<String, T>) =
        prefs.edit().putString(key, TeleportJson.encodeToString(MapSerializer(String.serializer(), serializer), value)).commit()

    override var peers: Map<String, Peer>
        get() = readMap("peers", Peer.serializer())
        set(value) { writeMap("peers", Peer.serializer(), value) }

    override var pendingOutbound: Map<String, Peer>
        get() = readMap("pendingOutbound", Peer.serializer())
            .filterValues { it.pairedAt > System.currentTimeMillis() - 10 * 60_000 }
        set(value) { writeMap("pendingOutbound", Peer.serializer(), value) }

    override var pairRequests: Map<String, PairRequest>
        get() = readMap("pairRequests", PairRequest.serializer()).filterValues { it.expires > System.currentTimeMillis() }
        set(value) { writeMap("pairRequests", PairRequest.serializer(), value) }

    /** Our name as other devices see it. Defaults to the phone's name from Settings, then the model. */
    override var deviceName: String?
        get() = prefs.getString("deviceName", null)
            ?: Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            ?: Build.MODEL
        set(value) = prefs.edit().putString("deviceName", value).apply()

    override var ownFcmToken: String?
        get() = prefs.getString("fcm", null)
        set(value) = prefs.edit().putString("fcm", value).apply()

    override fun newPairingSecret(): ByteArray {
        val secret = randomBytes(16)
        prefs.edit()
            .putString("ps", secret.b64u())
            .putLong("psExpires", System.currentTimeMillis() + 10 * 60_000)
            .putBoolean("psUsed", false)
            .commit()
        return secret
    }

    override fun currentPairingSecret(): ByteArray? {
        if (prefs.getBoolean("psUsed", true) || prefs.getLong("psExpires", 0) < System.currentTimeMillis()) return null
        return prefs.getString("ps", null)?.unb64u()
    }

    override fun markPairingSecretUsed() {
        prefs.edit().putBoolean("psUsed", true).commit()
    }

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

/** This device's name as other devices see it. */
val Context.deviceName: String get() = TeleportApp.of(this).teleport.store.deviceName ?: Build.MODEL
