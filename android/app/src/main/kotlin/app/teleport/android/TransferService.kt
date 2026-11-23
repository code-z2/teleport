package app.teleport.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.IBinder
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.text.format.Formatter
import app.teleport.core.BlobPointer
import app.teleport.core.ChunkedBlob
import app.teleport.core.OfflineException
import app.teleport.core.TeleportJson
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * Large files (up to 250 MB) in both directions, as a foreground service so Android doesn't
 * stop a transfer that takes minutes. Progress shows in a notification; one transfer at a
 * time per intent, several can run side by side.
 *
 * - Upload: from a share (the URI's read grant comes with the intent).
 * - Download: a chunked blob announced by push, saved to Download/Teleport.
 */
class TransferService : Service() {
    companion object {
        private const val ACTION_UPLOAD = "app.teleport.UPLOAD"
        private const val ACTION_DOWNLOAD = "app.teleport.DOWNLOAD"
        private const val ACTION_CLIP = "app.teleport.CLIP"
        private const val CHANNEL = "transfers"
        private val ids = AtomicInteger(2000)
        private val running = AtomicInteger(0)

        fun upload(context: Context, uri: Uri, peerId: String, mime: String) {
            val intent = Intent(context, TransferService::class.java)
                .setAction(ACTION_UPLOAD)
                .setDataAndType(uri, mime)
                .putExtra("peer", peerId)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            context.startForegroundService(intent)
        }

        /**
         * A clip (text or a small image) from the share sheet or Quick Settings tile. Sent here,
         * not from the share screen: Android freezes a backgrounded app within seconds, which
         * aborted uploads mid-way ("software caused connection abort"). The clip goes via a
         * private cache file, since intents can't carry megabytes.
         */
        fun sendClip(context: Context, clip: app.teleport.core.Clip, peerId: String) {
            val dir = File(context.cacheDir, "outgoing").apply { mkdirs() }
            val file = File(dir, java.util.UUID.randomUUID().toString())
            val (kind, mime) = when (clip) {
                is app.teleport.core.Clip.Text -> { file.writeText(clip.text); "text" to "text/plain" }
                is app.teleport.core.Clip.Bytes -> { file.writeBytes(clip.data); "bytes" to clip.mime }
            }
            val intent = Intent(context, TransferService::class.java)
                .setAction(ACTION_CLIP)
                .putExtra("file", file.path).putExtra("kind", kind).putExtra("mime", mime).putExtra("peer", peerId)
            context.startForegroundService(intent)
        }

        fun download(context: Context, pointer: BlobPointer, from: String) {
            val intent = Intent(context, TransferService::class.java)
                .setAction(ACTION_DOWNLOAD)
                .putExtra("pointer", TeleportJson.encodeToString(BlobPointer.serializer(), pointer))
                .putExtra("from", from)
            context.startForegroundService(intent)
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        channel()
        val id = ids.incrementAndGet()
        startForeground(id, progress("Teleport", "Starting…", 0, 0), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        running.incrementAndGet()
        scope.launch {
            try {
                when (intent?.action) {
                    ACTION_CLIP -> runClip(intent, id)
                    ACTION_UPLOAD -> runUpload(intent, id)
                    ACTION_DOWNLOAD -> runDownload(intent, id)
                }
            } finally {
                if (running.decrementAndGet() == 0) stopForeground(STOP_FOREGROUND_DETACH).also { stopSelf() }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.coroutineContext[kotlinx.coroutines.Job]?.cancel()
    }

    private fun runUpload(intent: Intent, id: Int) {
        val teleport = TeleportApp.of(this).teleport
        val uri = intent.data ?: return
        val peer = intent.getStringExtra("peer")?.let { teleport.store.peers[it] } ?: return
        val (name, size) = describe(uri)
        val mime = intent.type ?: contentResolver.getType(uri) ?: "application/octet-stream"
        val title = "Sending $name to ${peer.name}"
        val message = try {
            contentResolver.openInputStream(uri)!!.use { input ->
                teleport.sendFile(input, size, mime, name, peer) { sent, total -> update(id, title, sent, total) }
            }
            PeerShortcut.publish(this, peer)
            "Sent $name to ${peer.name}"
        } catch (e: OfflineException) {
            "${peer.name} is offline"
        } catch (e: Exception) {
            "Couldn't send $name: ${e.message}"
        }
        done(id, message, null)
    }

    private fun runClip(intent: Intent, id: Int) {
        val teleport = TeleportApp.of(this).teleport
        val file = File(intent.getStringExtra("file") ?: return)
        try {
            val peer = intent.getStringExtra("peer")?.let { teleport.store.peers[it] } ?: return
            val clip = if (intent.getStringExtra("kind") == "text") app.teleport.core.Clip.Text(file.readText())
            else app.teleport.core.Clip.Bytes(file.readBytes(), intent.getStringExtra("mime") ?: "image/jpeg")
            getSystemService(NotificationManager::class.java).notify(id, progress("Sending to ${peer.name}", "Encrypting and sending…", 0, 0))
            val message = try {
                teleport.send(clip, peer)
                PeerShortcut.publish(this, peer)
                "Sent to ${peer.name} ✓"
            } catch (e: OfflineException) {
                "${peer.name} is offline"
            } catch (e: app.teleport.core.PeerGoneException) {
                "${peer.name}'s push address expired. Open Teleport there or re-pair."
            } catch (e: Exception) {
                "Send failed: ${e.message}"
            }
            getSystemService(NotificationManager::class.java).cancel(id)
            android.os.Handler(mainLooper).post { android.widget.Toast.makeText(this, message, android.widget.Toast.LENGTH_SHORT).show() }
            if (!message.endsWith("✓")) done(id, message, null)
        } finally {
            file.delete()
        }
    }

    private fun runDownload(intent: Intent, id: Int) {
        val teleport = TeleportApp.of(this).teleport
        val p = intent.getStringExtra("pointer")?.let { TeleportJson.decodeFromString(BlobPointer.serializer(), it) } ?: return
        val from = intent.getStringExtra("from") ?: "a device"
        val name = (p.name ?: "File from $from").replace('/', '-')
        val title = "Receiving $name from $from"
        val item = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, p.mime)
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/Teleport")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }) ?: return done(id, "Couldn't save $name", null)
        try {
            contentResolver.openOutputStream(item)!!.use { out ->
                teleport.downloadFile(p, out, File.createTempFile("teleport", ".blob", cacheDir)) { got, total -> update(id, title, got, total) }
            }
            contentResolver.update(item, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            val open = Intent(Intent.ACTION_VIEW).setDataAndType(item, p.mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            done(id, "$name from $from saved to Download/Teleport", open)
        } catch (e: Exception) {
            contentResolver.delete(item, null, null)
            done(id, "Couldn't receive $name: ${e.message}", null)
        }
    }

    // ---------- notifications ----------

    private fun channel() {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "File transfers", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Progress of large files being sent or received"
            },
        )
    }

    private fun progress(title: String, text: String, done: Long, total: Long): Notification =
        Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_teleport)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .apply { if (total > 0) setProgress(1000, (1000 * done / total).toInt(), false) else setProgress(0, 0, true) }
            .build()

    private var lastUpdate = 0L

    private fun update(id: Int, title: String, done: Long, total: Long) {
        val now = System.currentTimeMillis()
        if (now - lastUpdate < 500 && done < total) return  // notifications are rate-limited
        lastUpdate = now
        val text = "${Formatter.formatShortFileSize(this, done)} of ${Formatter.formatShortFileSize(this, total)}"
        getSystemService(NotificationManager::class.java).notify(id, progress(title, text, done, total))
    }

    /** Replaces the progress notification with the result (tap opens the file if there is one). */
    private fun done(id: Int, message: String, open: Intent?) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.cancel(id)
        val builder = ClipDelivery.base(this, "Teleport", message)
        if (open != null) {
            builder.setContentIntent(PendingIntent.getActivity(this, id, Intent.createChooser(open, message), PendingIntent.FLAG_IMMUTABLE))
                .setAutoCancel(true)
        }
        nm.notify(id + 10_000, builder.build())
    }

    private fun describe(uri: Uri): Pair<String, Long> {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                return (c.getString(0)?.replace('/', '-') ?: "file") to (if (c.isNull(1)) 0L else c.getLong(1))
            }
        }
        return (uri.lastPathSegment ?: "file") to 0L
    }
}

/** True if a shared item should go as a file (not a clip): non-images, and images over the clip limit. */
fun isLargeOrFile(mime: String, size: Long): Boolean =
    !mime.startsWith("image/") || size + 16 > app.teleport.core.Teleport.MAX_BLOB_BYTES

/** Files over 250 MB can't be sent. */
fun tooLargeToSend(size: Long) = size > ChunkedBlob.MAX_SIZE
