package app.teleport.android

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.core.content.IntentCompat
import app.teleport.core.Clip
import app.teleport.core.Peer
import app.teleport.core.PeerGoneException
import app.teleport.core.Teleport
import app.teleport.core.TooLargeException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Transparent ACTION_SEND target: read → encrypt → relay → toast → finish. */
open class ShareActivity : Activity() {
    /** For subclasses that get their clip elsewhere (the Quick Settings tile). */
    protected fun callSuperOnCreate(savedInstanceState: Bundle?) = super.onCreate(savedInstanceState)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val clip = try {
            extract(intent)
        } catch (e: TooLargeException) {
            null.also { toast("Too large (max 10 MB)") }
        }
        if (clip == null) {
            finish(); return
        }
        // Direct Share targets carry the device's fingerprint as the shortcut id.
        deliver(clip, intent.getStringExtra(Intent.EXTRA_SHORTCUT_ID))
    }

    /** Sends to [chosenId] if given, the only device if there's one, otherwise asks which. */
    protected fun deliver(clip: Clip, chosenId: String? = null) {
        val teleport = TeleportApp.of(this).teleport
        val peers = teleport.sortedPeers()
        val chosen = chosenId?.let { teleport.store.peers[it] }
        when {
            chosen != null -> send(clip, chosen)
            peers.isEmpty() -> { toast("Open Teleport to pair first"); finish() }
            peers.size == 1 -> send(clip, peers[0])
            else -> AlertDialog.Builder(this, android.R.style.Theme_Material_Light_Dialog_Alert)
                .setTitle("Teleport to…")
                .setItems(peers.map { it.name }.toTypedArray()) { _, i -> send(clip, peers[i]) }
                .setOnCancelListener { finish() }
                .show()
        }
    }

    private fun send(clip: Clip, peer: Peer) {
        val app = TeleportApp.of(this)
        toast("Teleporting to ${peer.name}…")
        // Application-scoped so finishing the activity doesn't cancel the upload.
        appScope.launch {
            val message = try {
                app.teleport.send(clip, peer)
                PeerShortcut.publish(app, peer)
                "Sent to ${peer.name} ✓"
            } catch (e: app.teleport.core.OfflineException) {
                "${peer.name} is offline"
            } catch (e: PeerGoneException) {
                "${peer.name}'s push address expired — open Teleport there or re-pair"
            } catch (e: Exception) {
                "Send failed: ${e.message}"
            }
            withContext(Dispatchers.Main) { Toast.makeText(app, message, Toast.LENGTH_SHORT).show() }
        }
        finish()
    }

    private fun extract(intent: Intent): Clip? {
        if (intent.action != Intent.ACTION_SEND) return null
        val type = intent.type ?: return null
        if (type.startsWith("image/")) {
            val uri = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java) ?: return null
            val bytes = contentResolver.openInputStream(uri)?.use { input ->
                val limit = Teleport.MAX_BLOB_BYTES - 16
                val data = input.readNBytes(limit + 1)
                if (data.size > limit) throw TooLargeException()
                data
            } ?: return null
            return Clip.Bytes(bytes, contentResolver.getType(uri) ?: type)
        }
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: return null
        return Clip.Text(text)
    }

    protected fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    companion object {
        val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}
