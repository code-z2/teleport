package app.teleport.android

import android.Manifest
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import app.teleport.core.Clip
import app.teleport.core.Peer
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private var peer by mutableStateOf<Peer?>(null)
    private var card by mutableStateOf<String?>(null)
    private var status by mutableStateOf("")

    private val scan = registerForActivityResult(ScanContract()) { result ->
        val code = result.contents ?: return@registerForActivityResult
        status = runCatching { TeleportApp.of(this).teleport.pair(code) }
            .onSuccess { peer = it; PeerShortcut.publish(this, it) }
            .fold({ "Paired with ${it.name}" }, { "Not a Teleport code" })
    }

    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        val teleport = TeleportApp.of(this).teleport

        lifecycleScope.launch(Dispatchers.IO) {
            peer = teleport.store.peer
            peer?.let { PeerShortcut.publish(this@MainActivity, it) }
            // Show the last known token right away; refreshPushToken() (onResume) updates it.
            if (teleport.store.ownFcmToken != null) card = teleport.myCard(deviceName).encoded()
        }

        setContent {
            MaterialTheme {
                var text by remember { mutableStateOf("Hello from Android") }
                Column(
                    Modifier.fillMaxSize().padding(24.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text("Teleport", style = MaterialTheme.typography.headlineMedium)
                    Text("This phone", style = MaterialTheme.typography.titleMedium)
                    card?.let { Image(qr(it).asImageBitmap(), "Pairing code", Modifier.size(260.dp)) }
                        ?: Text("Waiting for push token…")
                    KeystoreKeys.strongBox?.let { Text(if (it) "Keys in StrongBox" else "Keys in TEE (no StrongBox)") }

                    Text("Paired device", style = MaterialTheme.typography.titleMedium)
                    Text(peer?.let { "${it.name} (${it.platform})" } ?: "Not paired")
                    Button(onClick = {
                        scan.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setBeepEnabled(false))
                    }) { Text(if (peer == null) "Scan other phone" else "Re-pair") }

                    if (peer != null) {
                        OutlinedTextField(text, { text = it }, label = { Text("Test clip") })
                        Button(onClick = { send(Clip.Text(text)) }) { Text("Send test clip") }
                    }
                    if (status.isNotEmpty()) Text(status)
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refreshPushToken()
        finishPendingDownloads()
    }

    /** Images whose background download was blocked: the app is in front now, so fetch them. */
    private fun finishPendingDownloads() {
        val pending = PendingBlobs.all(this)
        if (pending.isEmpty()) return
        val teleport = TeleportApp.of(this).teleport
        lifecycleScope.launch(Dispatchers.IO) {
            for ((id, pointer) in pending) {
                status = "Downloading image…"
                status = runCatching { teleport.fetchBlob(pointer) }.fold(
                    { clip ->
                        PendingBlobs.remove(this@MainActivity, id)
                        ClipDelivery.deliver(this@MainActivity, clip, id)
                        "Image copied — use Save in the notification to keep it"
                    },
                    { e ->
                        if (e is app.teleport.core.RelayException && e.status == 404) PendingBlobs.remove(this@MainActivity, id)
                        "Image download failed: ${e.message}"
                    },
                )
            }
        }
    }

    /** Ask FCM for the token every time the screen is shown, and surface failures. */
    @Suppress("DEPRECATION") // getToken(): still supported; FID-based registration is a later migration.
    private fun refreshPushToken() {
        if (FirebaseApp.getApps(this).isEmpty()) {
            status = "google-services.json missing — no push token"
            return
        }
        val teleport = TeleportApp.of(this).teleport
        FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
            val token = task.result.takeIf { task.isSuccessful }
            if (token == null) {
                val cause = generateSequence<Throwable>(task.exception) { it.cause }.last()
                status = "Push token failed: ${cause.message} — check network, then reopen the app"
                return@addOnCompleteListener
            }
            lifecycleScope.launch(Dispatchers.IO) {
                val changed = teleport.store.ownFcmToken != token
                teleport.store.ownFcmToken = token
                card = teleport.myCard(deviceName).encoded()
                if (changed) runCatching { teleport.announceToken(deviceName) }
            }
        }
    }

    private fun send(clip: Clip) {
        status = "Sending…"
        lifecycleScope.launch {
            status = withContext(Dispatchers.IO) {
                runCatching { TeleportApp.of(this@MainActivity).teleport.send(clip) }
                    .fold({ "Sent ✓" }, { "Failed: ${it.message}" })
            }
        }
    }

    private fun qr(text: String, size: Int = 720): Bitmap {
        val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
        val px = IntArray(size * size) { i -> if (m[i % size, i / size]) Color.BLACK else Color.WHITE }
        return Bitmap.createBitmap(px, size, size, Bitmap.Config.ARGB_8888)
    }
}
