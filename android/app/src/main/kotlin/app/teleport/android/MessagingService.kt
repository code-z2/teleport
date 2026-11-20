package app.teleport.android

import android.util.Log
import app.teleport.core.OpenException
import app.teleport.core.Received
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import java.io.IOException

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
        val received = try {
            app.teleport.receive(env)
        } catch (e: OpenException) {
            Log.w(TAG, "rejected envelope: ${e.code}")
            return ClipDelivery.notifyError(
                this,
                if (e.code == "proof") "Pairing code expired or already used. Show a new code and scan again."
                else "Couldn't verify a clip (${e.code}). Re-pair if this keeps happening.",
            )
        } catch (e: Exception) {
            Log.w(TAG, "receive failed: ${e.message}")
            return ClipDelivery.notifyError(this, "Couldn't read a clip: ${e.message}")
        }

        app.changed()  // lets an open main screen refresh
        when (received) {
            is Received.ClipReceived -> ClipDelivery.deliver(this, received.clip, received.id, received.from.name)
            is Received.BlobPending -> {
                // Images and long text are downloaded from the relay. Background network can
                // be blocked (background data off on mobile data, Data Saver): retry once,
                // then hand off to the app, which downloads when opened.
                for (attempt in 1..2) {
                    try {
                        return ClipDelivery.deliver(this, app.teleport.fetchBlob(received.pointer), received.id, received.from.name)
                    } catch (e: IOException) {
                        Log.w(TAG, "blob download attempt $attempt failed: ${e.message}")
                        if (attempt == 1) Thread.sleep(2_000)
                    } catch (e: Exception) {
                        Log.w(TAG, "blob failed: ${e.message}")
                        return ClipDelivery.notifyError(this, "Couldn't download a clip: ${e.message}")
                    }
                }
                ClipDelivery.notifyPending(this, received.pointer, received.id, received.from.name)
            }
            is Received.PeerUpdated -> PeerShortcut.publish(this, received.peer)  // picks up renames
            is Received.PairRequested -> PairActionReceiver.notifyRequest(this, received.request)
            is Received.Paired -> {
                PeerShortcut.publish(this, received.peer)
                ClipDelivery.notify(this, ClipDelivery.base(this, "Paired with ${received.peer.name}", "You can now teleport between the two."))
            }
        }
    }

    override fun onNewToken(token: String) {
        val app = TeleportApp.of(this)
        val changed = app.teleport.store.ownFcmToken != token
        app.teleport.store.ownFcmToken = token
        if (changed) runCatching { app.teleport.announce(deviceName) }
            .onFailure { Log.w(TAG, "token announce failed: ${it.message}") }
    }

    companion object {
        private const val TAG = "Teleport"
    }
}
