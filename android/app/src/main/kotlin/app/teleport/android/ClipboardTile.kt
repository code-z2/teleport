package app.teleport.android

import android.app.PendingIntent
import android.content.ClipboardManager
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import app.teleport.core.Clip
import app.teleport.core.Teleport

/**
 * "Teleport" in Quick Settings (pull down twice, edit, drag it in): sends what you copied
 * without going through a share sheet. Android only lets the focused app read the
 * clipboard, so the tile opens [ClipboardSendActivity], an invisible screen that reads it,
 * then sends (asking which device if there are several) and closes.
 */
class ClipboardTile : TileService() {
    override fun onStartListening() {
        qsTile?.apply {
            state = Tile.STATE_INACTIVE
            label = "Teleport"
            subtitle = "Send clipboard"
            updateTile()
        }
    }

    override fun onClick() {
        val intent = Intent(this, ClipboardSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val launch = {
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        }
        if (isLocked) unlockAndRun(launch) else launch()
    }
}

/** Reads the clipboard once it has focus (the only time Android allows it), then sends. */
class ClipboardSendActivity : ShareActivity() {
    private var handled = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // Skip ShareActivity's intent handling: the clip comes from the clipboard.
        callSuperOnCreate(savedInstanceState)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || handled) return
        handled = true
        val clip = readClipboard()
        if (clip == null) {
            toast("Nothing copied to teleport")
            finish()
            return
        }
        deliver(clip)
    }

    private fun readClipboard(): Clip? {
        val item = getSystemService(ClipboardManager::class.java)?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0) ?: return null
        item.uri?.let { uri ->
            val type = contentResolver.getType(uri)
            if (type?.startsWith("image/") == true) {
                val bytes = runCatching { contentResolver.openInputStream(uri)?.use { it.readNBytes(Teleport.MAX_BLOB_BYTES - 16 + 1) } }.getOrNull()
                if (bytes != null && bytes.size <= Teleport.MAX_BLOB_BYTES - 16) return Clip.Bytes(bytes, type)
                if (bytes != null) { toast("Too large (max 10 MB)"); return null }
            }
        }
        val text = item.coerceToText(this)?.toString()
        return text?.takeIf { it.isNotEmpty() }?.let { Clip.Text(it) }
    }
}
