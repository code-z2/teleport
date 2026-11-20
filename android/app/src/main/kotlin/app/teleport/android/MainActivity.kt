package app.teleport.android

import android.Manifest
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
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
import java.text.DateFormat
import java.util.Date

class MainActivity : ComponentActivity() {
    private val teleport get() = TeleportApp.of(this).teleport

    private var name by mutableStateOf("")
    private var peers by mutableStateOf(listOf<Peer>())
    private var requests by mutableStateOf(listOf<PairRequest>())
    private var waiting by mutableStateOf(listOf<Peer>())
    private var qrCode by mutableStateOf<String?>(null)
    private var showingQr by mutableStateOf(false)
    private var hasToken by mutableStateOf(false)
    /** Shown as a snackbar; the counter makes repeated identical messages show again. */
    private var message by mutableStateOf<Pair<String, Int>?>(null)

    private fun say(text: String) {
        message = text to ((message?.second ?: 0) + 1)
    }

    private val scan = registerForActivityResult(ScanContract()) { result ->
        val code = result.contents ?: return@registerForActivityResult
        say("Sending pairing request…")
        io {
            say(
                runCatching { teleport.scan(code, name) }.fold(
                    { "Tap Allow on ${it.name} to finish pairing" },
                    { if (it is InvalidCodeException) "That isn't a Teleport pairing code" else "Pairing failed: ${it.message}" },
                ),
            )
            reload()
        }
    }

    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
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

        setContent { TeleportTheme { Screen() } }
    }

    // ---------- UI ----------

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun Screen() {
        val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
        val snackbar = remember { SnackbarHostState() }
        var renaming by remember { mutableStateOf(false) }
        var removing by remember { mutableStateOf<Peer?>(null) }
        LaunchedEffect(message) { message?.let { snackbar.showSnackbar(it.first) } }

        Scaffold(
            modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
            topBar = { LargeTopAppBar(title = { Text("Teleport") }, scrollBehavior = scroll) },
            snackbarHost = { SnackbarHost(snackbar) },
        ) { padding ->
            LazyColumn(
                contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = 32.dp),
                modifier = Modifier.navigationBarsPadding(),
            ) {
                section("This phone") {}
                item {
                    ListItem(
                        headlineContent = { Text(name) },
                        supportingContent = { Text("Your other devices show this name") },
                        leadingContent = { SymbolIcon(R.drawable.ic_sym_android) },
                        trailingContent = {
                            IconButton(onClick = { renaming = true }) { SymbolIcon(R.drawable.ic_sym_edit, "Rename") }
                        },
                        colors = groupedColors(),
                        modifier = Modifier.groupedItem(),
                    )
                }

                if (requests.isNotEmpty()) {
                    section("Pairing requests") {}
                    items(requests, key = { "req-" + it.id }) { request -> PairRequestCard(request) }
                }

                section("Devices") {}
                if (peers.isEmpty() && waiting.isEmpty()) {
                    item {
                        ListItem(
                            headlineContent = { Text("No devices yet") },
                            supportingContent = { Text("Pair your other phone or your Mac below") },
                            leadingContent = { SymbolIcon(R.drawable.ic_sym_devices) },
                            colors = groupedColors(),
                            modifier = Modifier.groupedItem(),
                        )
                    }
                }
                items(peers, key = { it.id }) { peer ->
                    ListItem(
                        headlineContent = { Text(peer.name) },
                        supportingContent = { Text("${platformLabel(peer.platform)} · paired ${DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(peer.pairedAt))}") },
                        leadingContent = { SymbolIcon(platformIcon(peer.platform)) },
                        trailingContent = {
                            IconButton(onClick = { removing = peer }) { SymbolIcon(R.drawable.ic_sym_delete, "Remove ${peer.name}") }
                        },
                        colors = groupedColors(),
                        modifier = Modifier.groupedItem(),
                    )
                }
                items(waiting, key = { "wait-" + it.id }) { peer ->
                    ListItem(
                        headlineContent = { Text(peer.name) },
                        supportingContent = { Text("Waiting for Allow on ${peer.name}…") },
                        leadingContent = { CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp) },
                        colors = groupedColors(),
                        modifier = Modifier.groupedItem(),
                    )
                }
                item {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        FilledTonalButton(onClick = ::showCode, modifier = Modifier.weight(1f)) {
                            SymbolIcon(R.drawable.ic_sym_qr_code_2, size = 18)
                            Spacer(Modifier.size(8.dp))
                            Text("Show my code")
                        }
                        OutlinedButton(onClick = ::startScan, modifier = Modifier.weight(1f)) {
                            SymbolIcon(R.drawable.ic_sym_qr_code_scanner, size = 18)
                            Spacer(Modifier.size(8.dp))
                            Text("Scan a code")
                        }
                    }
                    Text(
                        "One device shows its code, the other scans it, then the first taps Allow.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 20.dp),
                    )
                }

                if (peers.isNotEmpty()) {
                    // Temporary: removed once the Mac integration is complete.
                    section("Test") {}
                    item { TestSection() }
                }

                item {
                    KeystoreKeys.strongBox?.let { strongBox ->
                        Row(
                            Modifier.padding(horizontal = 20.dp, vertical = 24.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            SymbolIcon(R.drawable.ic_sym_lock, size = 16, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(Modifier.size(8.dp))
                            Text(
                                if (strongBox) "Keys are stored in StrongBox" else "Keys are stored in the secure hardware (TEE)",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }

        if (renaming) RenameDialog(onDismiss = { renaming = false })
        removing?.let { peer -> RemoveDialog(peer, onDismiss = { removing = null }) }
        if (showingQr) PairingCodeSheet()
    }

    @Composable
    private fun PairRequestCard(request: PairRequest) {
        ElevatedCard(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SymbolIcon(platformIcon(request.platform), tint = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.size(12.dp))
                    Text("${request.name} wants to pair", style = MaterialTheme.typography.titleMedium)
                }
                Text(
                    "Allow it to send to and receive from this phone.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.align(Alignment.End)) {
                    TextButton(onClick = {
                        teleport.deny(request.id); ClipDelivery.cancel(this@MainActivity); reload()
                    }) { Text("Deny") }
                    Button(onClick = { allow(request) }) { Text("Allow") }
                }
            }
        }
    }

    @Composable
    private fun TestSection() {
        var text by remember { mutableStateOf("Hello from Android") }
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(text, { text = it }, label = { Text("Test clip") }, modifier = Modifier.fillMaxWidth())
            peers.forEach { peer ->
                OutlinedButton(onClick = { send(Clip.Text(text), peer) }, modifier = Modifier.fillMaxWidth()) {
                    SymbolIcon(R.drawable.ic_sym_send, size = 18)
                    Spacer(Modifier.size(8.dp))
                    Text("Send to ${peer.name}")
                }
            }
        }
    }

    @Composable
    private fun RenameDialog(onDismiss: () -> Unit) {
        var draft by remember { mutableStateOf(name) }
        AlertDialog(
            onDismissRequest = onDismiss,
            icon = { SymbolIcon(R.drawable.ic_sym_edit) },
            title = { Text("Rename this phone") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(draft, { draft = it }, singleLine = true, label = { Text("Name") })
                    Text("Shown as \"Teleport (${draft.ifBlank { "…" }})\" on your other devices.", style = MaterialTheme.typography.bodySmall)
                }
            },
            confirmButton = {
                TextButton(enabled = draft.isNotBlank(), onClick = { saveName(draft); onDismiss() }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        )
    }

    @Composable
    private fun RemoveDialog(peer: Peer, onDismiss: () -> Unit) {
        AlertDialog(
            onDismissRequest = onDismiss,
            icon = { SymbolIcon(R.drawable.ic_sym_delete) },
            title = { Text("Remove ${peer.name}?") },
            text = { Text("It won't be able to send to this phone until you pair again.") },
            confirmButton = {
                TextButton(onClick = {
                    teleport.remove(peer.id); PeerShortcut.sync(this@MainActivity); reload(); onDismiss()
                    say("Removed ${peer.name}")
                }) { Text("Remove") }
            },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        )
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun PairingCodeSheet() {
        ModalBottomSheet(
            onDismissRequest = { showingQr = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        ) {
            Column(
                Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(name, style = MaterialTheme.typography.headlineSmall)
                Box(
                    Modifier.size(280.dp).clip(RoundedCornerShape(24.dp)).background(androidx.compose.ui.graphics.Color.White),
                    contentAlignment = Alignment.Center,
                ) {
                    val code = qrCode
                    when {
                        code != null -> Image(qr(code).asImageBitmap(), "Pairing code", Modifier.size(248.dp))
                        else -> CircularProgressIndicator()
                    }
                }
                Text(
                    when {
                        qrCode != null -> "Scan this with Teleport on the other device, then tap Allow here."
                        !hasToken -> "Waiting for a push token…"
                        else -> "Making a code…"
                    },
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.bodyLarge,
                )
                Text(
                    "Valid for 10 minutes, for one device.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(8.dp))
            }
        }
    }

    // ---------- actions ----------

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

    private fun saveName(newName: String) {
        val trimmed = newName.trim()
        if (trimmed.isEmpty() || trimmed == teleport.store.deviceName) return
        name = trimmed
        teleport.store.deviceName = trimmed
        io {
            val failed = teleport.announce(trimmed)
            say(if (failed == 0) "Renamed to $trimmed" else "Renamed; $failed device(s) will see it later")
        }
    }

    private fun showCode() {
        showingQr = true
        qrCode = null
        if (teleport.store.ownFcmToken == null) return
        io { qrCode = teleport.qrCode(name) }
    }

    private fun startScan() {
        scan.launch(
            ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setBeepEnabled(false)
                .setPrompt("Scan the pairing code on your other device"),
        )
    }

    private fun allow(request: PairRequest) {
        io {
            say(
                runCatching { teleport.allow(request.id, name) }.fold(
                    { PeerShortcut.publish(this, it); ClipDelivery.cancel(this); "Paired with ${it.name}" },
                    { "Couldn't finish pairing: ${it.message}" },
                ),
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
                say("Downloading image from ${blob.from}…")
                say(
                    runCatching { teleport.fetchBlob(blob.pointer) }.fold(
                        { clip ->
                            PendingBlobs.remove(this, id)
                            ClipDelivery.deliver(this, clip, id, blob.from)
                            "Image copied. Use Save in the notification to keep it"
                        },
                        { e ->
                            if (e is RelayException && e.status == 404) PendingBlobs.remove(this, id)
                            "Image download failed: ${e.message}"
                        },
                    ),
                )
            }
        }
    }

    /** Ask FCM for the token every time the screen is shown, and surface failures. */
    @Suppress("DEPRECATION") // getToken(): still supported; FID-based registration is a later migration.
    private fun refreshPushToken() {
        if (FirebaseApp.getApps(this).isEmpty()) {
            say("google-services.json missing — no push token")
            return
        }
        FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
            val token = task.result.takeIf { task.isSuccessful }
            if (token == null) {
                val cause = generateSequence<Throwable>(task.exception) { it.cause }.last()
                say("Push token failed: ${cause.message}. Check the network, then reopen")
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
        say("Sending to ${peer.name}…")
        lifecycleScope.launch {
            say(
                withContext(Dispatchers.IO) {
                    runCatching { teleport.send(clip, peer) }.fold({ "Sent to ${peer.name}" }, { "Failed: ${it.message}" })
                },
            )
        }
    }

    private fun qr(text: String, size: Int = 720): Bitmap {
        val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size)
        val px = IntArray(size * size) { i -> if (m[i % size, i / size]) Color.BLACK else Color.WHITE }
        return Bitmap.createBitmap(px, size, size, Bitmap.Config.ARGB_8888)
    }
}

// ---------- shared UI pieces ----------

/** Material You: colours follow the wallpaper; light and dark follow the system. */
@Composable
fun TeleportTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val scheme = if (isSystemInDarkTheme()) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    MaterialTheme(colorScheme = scheme, content = content)
}

@Composable
fun SymbolIcon(
    res: Int,
    description: String? = null,
    size: Int = 24,
    tint: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.onSurfaceVariant,
) = Icon(painterResource(res), description, Modifier.size(size.dp), tint = tint)

private fun LazyListScope.section(title: String, content: LazyListScope.() -> Unit) {
    item(key = "header-$title") {
        Text(
            title,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 24.dp, bottom = 8.dp),
        )
    }
    content()
}

/** List rows on a tonal surface with rounded corners, the Material 3 "grouped list" look. */
@Composable
private fun groupedColors() = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainer)

private fun Modifier.groupedItem() = padding(horizontal = 16.dp, vertical = 2.dp).clip(RoundedCornerShape(16.dp))

private fun platformLabel(platform: String) = when (platform) {
    "ios" -> "iPhone"
    "mac" -> "Mac"
    else -> "Android"
}

private fun platformIcon(platform: String) = when (platform) {
    "ios" -> R.drawable.ic_sym_phone_iphone
    "mac" -> R.drawable.ic_sym_laptop_mac
    else -> R.drawable.ic_sym_android
}
