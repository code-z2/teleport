package app.teleport.android

import android.Manifest
import android.app.Notification
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import app.teleport.core.Clip
import app.teleport.core.Received
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import java.io.File

/**
 * High-priority FCM data message → verify + decrypt → clipboard.
 * Android allows background clipboard *writes* (only reads are restricted), so the clip
 * lands immediately. We always post a notification too: FCM deprioritizes apps whose
 * high-priority messages never produce anything user-visible.
 */
class MessagingService : FirebaseMessagingService() {

    override fun onMessageReceived(message: RemoteMessage) {
        val env = message.data["env"] ?: return
        val app = TeleportApp.of(this)
        try {
            when (val r = app.teleport.receive(env)) {
                is Received.ClipReceived -> {
                    val clipData = toClipData(r.clip, r.id)
                    Handler(Looper.getMainLooper()).post {
                        getSystemService(ClipboardManager::class.java).setPrimaryClip(clipData)
                    }
                    notify("Copied from ${app.teleport.store.peer?.name ?: "your phone"}", preview(r.clip))
                }
                is Received.PeerUpdated -> Log.i(TAG, "peer tokens updated")
            }
        } catch (e: Exception) {
            Log.w(TAG, "rejected envelope: ${e.message}")
            notify("Teleport", "Couldn't verify a clip (${e.message})")
        }
    }

    override fun onNewToken(token: String) {
        val app = TeleportApp.of(this)
        val changed = app.teleport.store.ownFcmToken != token
        app.teleport.store.ownFcmToken = token
        if (changed) runCatching { app.teleport.announceToken(deviceName) }
            .onFailure { Log.w(TAG, "token announce failed: ${it.message}") }
    }

    private fun toClipData(clip: Clip, id: String): ClipData = when (clip) {
        is Clip.Text -> ClipData.newPlainText("Teleport", clip.text)
        is Clip.Bytes -> {
            val ext = when (clip.mime) { "image/png" -> "png"; "image/gif" -> "gif"; else -> "jpg" }
            val dir = File(cacheDir, "clips").apply { mkdirs() }
            dir.listFiles()?.filter { it.lastModified() < System.currentTimeMillis() - 3_600_000 }?.forEach { it.delete() }
            val file = File(dir, "$id.$ext").apply { writeBytes(clip.data) }
            val uri = FileProvider.getUriForFile(this, "$packageName.clips", file)
            ClipData.newUri(contentResolver, "Teleport", uri)
        }
    }

    private fun preview(clip: Clip) = when (clip) {
        is Clip.Text -> clip.text.take(200)
        is Clip.Bytes -> "Image (${clip.data.size / 1024} KB)"
    }

    private fun notify(title: String, body: String) {
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val n = Notification.Builder(this, TeleportApp.CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_upload)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setTimeoutAfter(5 * 60_000)
            .build()
        NotificationManagerCompat.from(this).notify(1, n)
    }

    companion object {
        private const val TAG = "Teleport"
    }
}
