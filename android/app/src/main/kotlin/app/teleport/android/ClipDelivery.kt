package app.teleport.android

import android.Manifest
import android.app.Notification
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import app.teleport.core.BlobPointer
import app.teleport.core.Clip
import app.teleport.core.TeleportJson
import java.io.File

/** Puts a received clip on the clipboard and tells the user, with a Save button for images. */
object ClipDelivery {
    const val ACTION_SAVE = "app.teleport.android.SAVE_IMAGE"
    const val EXTRA_FILE = "file"
    const val EXTRA_MIME = "mime"
    const val NOTIFICATION_ID = 1

    fun deliver(context: Context, clip: Clip, id: String, from: String) {
        when (clip) {
            is Clip.Text -> {
                setClipboard(context, ClipData.newPlainText("Teleport", clip.text))
                notify(context, base(context, "Copied from $from", clip.text.take(200)))
            }
            is Clip.Bytes -> {
                val file = cacheFile(context, id, clip)
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.clips", file)
                setClipboard(context, ClipData.newUri(context.contentResolver, "Teleport", uri))
                val save = PendingIntent.getBroadcast(
                    context, id.hashCode(),
                    Intent(context, SaveImageReceiver::class.java)
                        .setAction(ACTION_SAVE)
                        .putExtra(EXTRA_FILE, file.absolutePath)
                        .putExtra(EXTRA_MIME, clip.mime),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
                val builder = base(context, "Image copied from $from", "Paste it anywhere, or save it to Photos")
                    .addAction(Notification.Action.Builder(null, "Save", save).build())
                thumbnail(file)?.let { builder.setLargeIcon(it).setStyle(Notification.BigPictureStyle().bigPicture(it)) }
                notify(context, builder)
            }
        }
    }

    /** The download was blocked (usually background data off on mobile data): finish it when the app opens. */
    fun notifyPending(context: Context, pointer: BlobPointer, id: String, from: String) {
        PendingBlobs.add(context, id, PendingBlob(pointer, from))
        notify(
            context,
            base(context, "Image from $from — tap to download", "Teleport couldn't download it in the background. Allow background data for Teleport to skip this step."),
        )
    }

    fun notifyError(context: Context, message: String) = notify(context, base(context, "Teleport", message))

    fun cancel(context: Context) = NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)

    fun base(context: Context, title: String, body: String): Notification.Builder {
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(context, TeleportApp.CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_teleport)
            .setColor(0xFF4F46E5.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setTimeoutAfter(30 * 60_000)
    }

    fun notify(context: Context, builder: Notification.Builder) {
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, builder.build())
    }

    private fun setClipboard(context: Context, data: ClipData) {
        Handler(Looper.getMainLooper()).post {
            context.getSystemService(ClipboardManager::class.java).setPrimaryClip(data)
        }
    }

    private fun cacheFile(context: Context, id: String, clip: Clip.Bytes): File {
        val ext = when (clip.mime) { "image/png" -> "png"; "image/gif" -> "gif"; else -> "jpg" }
        val dir = File(context.cacheDir, "clips").apply { mkdirs() }
        // Keep a day of received images so Save still works on older notifications.
        dir.listFiles()?.filter { it.lastModified() < System.currentTimeMillis() - 86_400_000 }?.forEach { it.delete() }
        return File(dir, "$id.$ext").apply { writeBytes(clip.data) }
    }

    /** Downsampled preview (notifications reject very large bitmaps). */
    private fun thumbnail(file: File): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= 1024 || bounds.outHeight / (sample * 2) >= 1024) sample *= 2
        return BitmapFactory.decodeFile(file.absolutePath, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}

@kotlinx.serialization.Serializable
data class PendingBlob(val pointer: BlobPointer, val from: String)

/** Blobs whose download failed, finished next time the app is opened. */
object PendingBlobs {
    private fun prefs(context: Context) = context.getSharedPreferences("teleport_pending", Context.MODE_PRIVATE)

    fun add(context: Context, id: String, p: PendingBlob) =
        prefs(context).edit().putString(id, TeleportJson.encodeToString(PendingBlob.serializer(), p)).apply()

    fun remove(context: Context, id: String) = prefs(context).edit().remove(id).apply()

    fun all(context: Context): Map<String, PendingBlob> =
        prefs(context).all.mapNotNull { (id, v) ->
            (v as? String)?.let { runCatching { id to TeleportJson.decodeFromString(PendingBlob.serializer(), it) }.getOrNull() }
        }.toMap()
}
