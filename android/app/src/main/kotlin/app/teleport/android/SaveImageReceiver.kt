package app.teleport.android

import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Environment
import android.provider.MediaStore
import android.widget.Toast
import java.io.File

/** "Save" on an image notification: copies the received image into Pictures/Teleport. */
class SaveImageReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ClipDelivery.ACTION_SAVE) return
        val file = intent.getStringExtra(ClipDelivery.EXTRA_FILE)?.let(::File) ?: return
        val mime = intent.getStringExtra(ClipDelivery.EXTRA_MIME) ?: "image/jpeg"
        val app = context.applicationContext
        val pending = goAsync()
        Thread {
            val message = try {
                if (!file.exists()) error("Image expired — ask for it again")
                save(app, file, mime)
                "Saved to Photos"
            } catch (e: Exception) {
                "Couldn't save: ${e.message}"
            }
            ClipDelivery.notify(app, ClipDelivery.base(app, "Teleport", message).setTimeoutAfter(10_000))
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                Toast.makeText(app, message, Toast.LENGTH_SHORT).show()
                pending.finish()
            }
        }.start()
    }

    /** MediaStore insert: no storage permission needed on Android 10+. */
    private fun save(context: Context, file: File, mime: String) {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "Teleport_${System.currentTimeMillis()}.${file.extension}")
            put(MediaStore.Images.Media.MIME_TYPE, mime)
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Teleport")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: error("no media store")
        resolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
        resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
    }
}
