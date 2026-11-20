package app.teleport.android

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import app.teleport.core.PairRequest

/** Allow / Deny on a "<name> wants to pair" notification. Works without opening the app. */
class PairActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        val app = context.applicationContext
        val teleport = TeleportApp.of(app).teleport
        if (intent.action == ACTION_DENY) {
            teleport.deny(id)
            ClipDelivery.cancel(app)
            TeleportApp.of(app).changed()
            return
        }
        val pending = goAsync()
        Thread {
            val message = try {
                val peer = teleport.allow(id, app.deviceName)
                PeerShortcut.publish(app, peer)
                "Paired with ${peer.name}"
            } catch (e: Exception) {
                Log.w("Teleport", "allow failed: ${e.message}")
                "Couldn't finish pairing: ${e.message}"
            }
            ClipDelivery.notify(app, ClipDelivery.base(app, "Teleport", message).setTimeoutAfter(15_000))
            TeleportApp.of(app).changed()
            pending.finish()
        }.start()
    }

    companion object {
        const val ACTION_ALLOW = "app.teleport.android.PAIR_ALLOW"
        const val ACTION_DENY = "app.teleport.android.PAIR_DENY"
        const val EXTRA_ID = "id"

        fun notifyRequest(context: Context, request: PairRequest) {
            fun action(action: String, code: Int) = PendingIntent.getBroadcast(
                context, request.id.hashCode() + code,
                Intent(context, PairActionReceiver::class.java).setAction(action).putExtra(EXTRA_ID, request.id),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val builder = ClipDelivery.base(
                context, "${request.name} wants to pair",
                "Allow it to send to and receive from this phone. Expires in 10 minutes.",
            )
                .addAction(android.app.Notification.Action.Builder(null, "Allow", action(ACTION_ALLOW, 1)).build())
                .addAction(android.app.Notification.Action.Builder(null, "Deny", action(ACTION_DENY, 2)).build())
                .setTimeoutAfter(10 * 60_000)
            ClipDelivery.notify(context, builder)
        }
    }
}
