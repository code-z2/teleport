package app.teleport.android

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.core.content.IntentCompat
import app.teleport.core.Clip
import app.teleport.core.NotPairedException
import app.teleport.core.PeerGoneException
import app.teleport.core.Teleport
import app.teleport.core.TooLargeException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Transparent ACTION_SEND target: read → encrypt → relay → toast → finish. */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = TeleportApp.of(this)
        val clip = try {
            extract(intent)
        } catch (e: TooLargeException) {
            null.also { toast("Too large (max 10 MB)") }
        }
        if (clip == null) {
            finish(); return
        }
        toast("Teleporting…")
        // Application-scoped so finishing the activity doesn't cancel the upload.
        appScope.launch {
            val message = try {
                app.teleport.send(clip)
                app.teleport.store.peer?.let { PeerShortcut.publish(app, it) }
                "Sent ✓"
            } catch (e: NotPairedException) {
                "Open Teleport to pair first"
            } catch (e: PeerGoneException) {
                "Other phone's token expired — re-pair"
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

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    companion object {
        val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}
