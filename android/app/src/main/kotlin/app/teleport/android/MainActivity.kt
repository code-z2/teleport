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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import app.teleport.core.Clip
import app.teleport.core.InvalidCodeException
import app.teleport.core.PairRequest
import app.teleport.core.Peer
import app.teleport.core.RelayException
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
    private val teleport get() = TeleportApp.of(this).teleport

    private var name by mutableStateOf("")
    private var peers by mutableStateOf(listOf<Peer>())
    private var requests by mutableStateOf(listOf<PairRequest>())
    private var waiting by mutableStateOf(listOf<Peer>())
    private var qrCode by mutableStateOf<String?>(null)
    private var showingQr by mutableStateOf(false)
    private var hasToken by mutableStateOf(false)
    private var status by mutableStateOf("")

    private val scan = registerForActivityResult(ScanContract()) { result ->
        val code = result.contents ?: return@registerForActivityResult
        status = "Sending pairing request…"
        io {
            status = runCatching { teleport.scan(code, name) }.fold(
                { "Tap Allow on ${it.name} to finish pairing." },
                { if (it is InvalidCodeException) "That isn't a Teleport pairing code (or it's an old one — update the other app)." else "Pairing failed: ${it.message}" },
            )
            reload()
        }
    }

    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        name = deviceName

        // Pushes handled in the background (pairing requests, "Paired") refresh this screen.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                TeleportApp.of(this@MainActivity).changes.collect {
                    reload()
                    if (requests.isNotEmpty()) showingQr = false
                }
            }
        }

        setContent { MaterialTheme { Screen() } }
    }

    @androidx.compose.runtime.Composable
    private fun Screen() {
        var text by remember { mutableStateOf("Hello from Android") }
        Column(
            Modifier.fillMaxSize().padding(24.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Teleport", style = MaterialTheme.typography.headlineMedium)

            Text("This phone's name", style = MaterialTheme.typography.titleMedium)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(name, { name = it }, singleLine = true, modifier = Modifier.weight(1f))
                OutlinedButton(onClick = ::saveName) { Text("Save") }
            }
            Text("Other devices show \"Teleport ($name)\".", style = MaterialTheme.typography.bodySmall)

            if (requests.isNotEmpty()) {
                Text("Pairing requests", style = MaterialTheme.typography.titleMedium)
                requests.forEach { request ->
                    Card(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("${request.name} (${platformLabel(request.platform)}) wants to pair")
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Button(onClick = { allow(request) }) { Text("Allow") }
                                OutlinedButton(onClick = { teleport.deny(request.id); ClipDelivery.cancel(this@MainActivity); reload() }) { Text("Deny") }
                            }
                        }
                    }
                }
            }

            Text("Devices", style = MaterialTheme.typography.titleMedium)
            if (peers.isEmpty() && waiting.isEmpty()) Text("No devices yet")
            peers.forEach { peer ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("${peer.name} (${platformLabel(peer.platform)})", Modifier.weight(1f))
                    TextButton(onClick = { teleport.remove(peer.id); PeerShortcut.sync(this@MainActivity); reload() }) { Text("Remove") }
                }
            }
            waiting.forEach { Text("Waiting for ${it.name} to tap Allow…", style = MaterialTheme.typography.bodyMedium) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = ::showCode, enabled = name.isNotBlank()) { Text("Show my code") }
                OutlinedButton(onClick = {
                    saveName()
                    scan.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setBeepEnabled(false))
                }, enabled = name.isNotBlank()) { Text("Scan a code") }
            }
            Text(
                "Pairing takes one scan: one device shows its code, the other scans it, then the first taps Allow.",
                style = MaterialTheme.typography.bodySmall,
            )

            if (peers.isNotEmpty()) {
                Text("Test", style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(text, { text = it }, label = { Text("Test clip") }, modifier = Modifier.fillMaxWidth())
                peers.forEach { peer ->
                    OutlinedButton(onClick = { send(Clip.Text(text), peer) }) { Text("Send to ${peer.name}") }
                }
            }

            KeystoreKeys.strongBox?.let { Text(if (it) "Keys in StrongBox" else "Keys in TEE (no StrongBox)", style = MaterialTheme.typography.bodySmall) }
            if (status.isNotEmpty()) Text(status)
        }

        if (showingQr) {
            AlertDialog(
                onDismissRequest = { showingQr = false },
                confirmButton = { TextButton(onClick = { showingQr = false }) { Text("Done") } },
                title = { Text(name) },
                text = {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        val code = qrCode
                        when {
                            code != null -> {
                                Image(qr(code).asImageBitmap(), "Pairing code", Modifier.size(260.dp))
                                Text("Scan this with Teleport on the other device, then tap Allow here.")
                                Text("Valid for 10 minutes, for one device.", style = MaterialTheme.typography.bodySmall)
                            }
                            !hasToken -> Text("Waiting for a push token…")
                            else -> Text("Making a code…")
                        }
                    }
                },
            )
        }
    }

    override fun onResume() {
        super.onResume()
        reload()
        refreshPushToken()
        finishPendingDownloads()
    }

    private fun io(block: suspend () -> Unit) = lifecycleScope.launch(Dispatchers.IO) { block() }

    private fun reload() {
        val store = teleport.store
        peers = teleport.sortedPeers()
        requests = store.pairRequests.values.sortedBy { it.expires }
        waiting = store.pendingOutbound.values.filter { it.id !in store.peers }
    }

    private fun saveName() {
        val trimmed = name.trim()
        if (trimmed.isEmpty() || trimmed == teleport.store.deviceName) return
        name = trimmed
        teleport.store.deviceName = trimmed
        io {
            val failed = teleport.announce(trimmed)
            status = if (failed == 0) "Name saved." else "Name saved; $failed device(s) will get it later."
        }
    }

    private fun showCode() {
        saveName()
        showingQr = true
        qrCode = null
        if (teleport.store.ownFcmToken == null) return
        io { qrCode = teleport.qrCode(name) }
    }

    private fun allow(request: PairRequest) {
        io {
            status = runCatching { teleport.allow(request.id, name) }.fold(
                { PeerShortcut.publish(this, it); ClipDelivery.cancel(this); "Paired with ${it.name}" },
                { "Couldn't finish pairing: ${it.message}" },
            )
            reload()
        }
    }

    /** Images whose background download was blocked: the app is in front now, so fetch them. */
    private fun finishPendingDownloads() {
        val pending = PendingBlobs.all(this)
        if (pending.isEmpty()) return
        io {
            for ((id, blob) in pending) {
                status = "Downloading image…"
                status = runCatching { teleport.fetchBlob(blob.pointer) }.fold(
                    { clip ->
                        PendingBlobs.remove(this, id)
                        ClipDelivery.deliver(this, clip, id, blob.from)
                        "Image copied — use Save in the notification to keep it"
                    },
                    { e ->
                        if (e is RelayException && e.status == 404) PendingBlobs.remove(this, id)
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
        FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
            val token = task.result.takeIf { task.isSuccessful }
            if (token == null) {
                val cause = generateSequence<Throwable>(task.exception) { it.cause }.last()
                status = "Push token failed: ${cause.message} — check network, then reopen the app"
                return@addOnCompleteListener
            }
            hasToken = true
            io {
                val changed = teleport.store.ownFcmToken != token
                teleport.store.ownFcmToken = token
                if (changed) teleport.announce(deviceName)
                if (showingQr && qrCode == null) qrCode = teleport.qrCode(name)
                PeerShortcut.sync(this)
            }
        }
    }

    private fun send(clip: Clip, peer: Peer) {
        status = "Sending to ${peer.name}…"
        lifecycleScope.launch {
            status = withContext(Dispatchers.IO) {
                runCatching { teleport.send(clip, peer) }.fold({ "Sent to ${peer.name} ✓" }, { "Failed: ${it.message}" })
            }
        }
    }

    private fun platformLabel(platform: String) = when (platform) {
        "ios" -> "iPhone"
        "mac" -> "Mac"
        else -> "Android"
    }

    private fun qr(text: String, size: Int = 720): Bitmap {
        val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
        val px = IntArray(size * size) { i -> if (m[i % size, i / size]) Color.BLACK else Color.WHITE }
        return Bitmap.createBitmap(px, size, size, Bitmap.Config.ARGB_8888)
    }
}
