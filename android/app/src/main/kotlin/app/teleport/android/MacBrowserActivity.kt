package app.teleport.android

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import app.teleport.core.FileEntry
import app.teleport.core.FileSessionClient
import app.teleport.core.Peer
import app.teleport.core.SessionException
import app.teleport.core.SocketPipe
import app.teleport.core.Teleport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.CancellationException
import kotlin.coroutines.coroutineContext

/** Browse a paired Mac's home folder over an end-to-end encrypted file session. */
class MacBrowserActivity : ComponentActivity() {
    companion object {
        private const val EXTRA_PEER = "peer"
        fun intent(context: Context, peer: Peer) = Intent(context, MacBrowserActivity::class.java).putExtra(EXTRA_PEER, peer.id)
    }

    private val teleport: Teleport get() = (application as TeleportApp).teleport
    private lateinit var mac: Peer
    private var client: FileSessionClient? = null
    private val connectLock = Mutex()

    // UI state
    private var path by mutableStateOf("")
    private var entries by mutableStateOf<List<FileEntry>?>(null)
    private var loading by mutableStateOf(false)
    private var error by mutableStateOf<String?>(null)
    private var message by mutableStateOf<Pair<String, Long>?>(null)
    private val transfers = mutableStateListOf<Transfer>()
    /** The file being previewed (file → preview → save); null shows the folder. */
    private var previewing by mutableStateOf<PreviewState?>(null)
    private val previewCache get() = java.io.File(cacheDir, "previews")

    class Transfer(val name: String, val upload: Boolean) {
        var done by mutableStateOf(0L)
        var total by mutableStateOf(0L)
        var state by mutableStateOf("running") // running | done | failed | cancelled
        var detail by mutableStateOf<String?>(null)
        var uri by mutableStateOf<Uri?>(null)
        var job: Job? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val peer = intent.getStringExtra(EXTRA_PEER)?.let { teleport.store.peers[it] }
        if (peer == null || !peer.hasMailbox) { finish(); return }
        mac = peer
        // Previews are kept a day so an interrupted or reopened one resumes; older ones go.
        previewCache.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 86_400_000 }?.forEach { it.deleteRecursively() }
        setContent { TeleportTheme { Screen() } }
        load("")
    }

    override fun onDestroy() {
        super.onDestroy()
        client?.close()
    }

    /** In the background, hang up (the Mac stops showing this phone as browsing) unless a
     *  transfer is still running. The next action reconnects on its own. */
    override fun onStop() {
        super.onStop()
        if (transfers.none { it.state == "running" }) { client?.close(); client = null }
    }

    // ---------- session ----------

    private suspend fun session(): FileSessionClient = connectLock.withLock {
        client?.takeIf { it.isOpen } ?: withContext(Dispatchers.IO) {
            val mailbox = mac.mailbox ?: throw SessionException("protocol", "This Mac has no mailbox. Pair it again.")
            if (teleport.relay.isOnline(mailbox) == false) {
                throw SessionException("offline", "${mac.name} is offline. Check it's awake and connected.")
            }
            val pipe = OkHttpSessionPipe.open(teleport.relay.sessionUrl(mailbox), teleport.relay.authorization)
            val relayed = try {
                FileSessionClient.handshake(pipe, teleport.signing, mailbox, mac.ksBytes)
            } catch (e: Exception) {
                pipe.close(); throw e
            }
            // Same Wi-Fi? Move to a direct connection (as fast as the network, not the home
            // internet's upload). The addresses come over the encrypted session.
            val direct = runCatching { SocketPipe.upgrade(relayed.endpoints(), teleport.signing, mailbox, mac.ksBytes) }.getOrNull()
            if (direct != null) { relayed.close(); direct } else relayed
        }.also { client = it }
    }

    /**
     * One block for a playing video. A connection that stalls without closing (Wi-Fi dropped,
     * the computer slept) would hang playback for good, so each read gets 20 s. After that, or
     * any failure, the session is dropped and the player's retry connects afresh.
     */
    private fun streamRead(path: String, offset: Long, length: Int, cancelled: () -> Boolean): ByteArray {
        val c = kotlinx.coroutines.runBlocking { session() }
        val deadline = android.os.SystemClock.elapsedRealtime() + 20_000
        try {
            return c.read(path, offset, length) { cancelled() || android.os.SystemClock.elapsedRealtime() > deadline }
        } catch (e: Exception) {
            if (!cancelled()) {
                android.util.Log.w("Teleport", "stream read at $offset failed; reconnecting", e)
                c.close()
            }
            throw e
        }
    }

    /** Runs [op] on the session, reconnecting once if the old one had closed. */
    private suspend fun <T> withSession(op: (FileSessionClient) -> T): T = try {
        withContext(Dispatchers.IO) { op(session()) }
    } catch (e: SessionException) {
        if (e.code != "closed") throw e
        client = null
        withContext(Dispatchers.IO) { op(session()) }
    }

    private fun load(newPath: String) {
        lifecycleScope.launch {
            loading = true
            try {
                val list = withSession { it.list(newPath) }
                path = newPath
                entries = list
                error = null
            } catch (e: Exception) {
                error = e.message ?: "Couldn't reach ${mac.name}."
            } finally {
                loading = false
            }
        }
    }

    private fun child(name: String) = if (path.isEmpty()) name else "$path/$name"
    private fun parent(p: String) = p.substringBeforeLast('/', "")

    // ---------- transfers ----------

    // ---------- preview ----------

    private fun openPreview(entry: FileEntry) {
        val state = PreviewState(entry, child(entry.name))
        previewing = state
        lifecycleScope.launch {
            val jpeg = runCatching { withSession { it.thumbnail(state.path, 600) } }.getOrNull()
            if (jpeg != null) state.thumbnail = withContext(Dispatchers.IO) { BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) }
        }
        when {
            state.kind == PreviewKind.NONE -> state.phase = "unsupported"
            state.kind == PreviewKind.MEDIA -> state.phase = "stream"  // plays at once; Save fetches it all
            entry.size > PreviewState.AUTO_PREVIEW_LIMIT -> state.phase = "thumb"
            else -> fetch(state)
        }
    }

    private fun closePreview() {
        previewing?.job?.cancel()
        previewing = null
    }

    /** Streams the whole file into the preview cache once, then runs [then]. */
    private fun fetch(state: PreviewState, then: (java.io.File) -> Unit = {}) {
        state.file?.let { return then(it) }
        if (state.job?.isActive == true) return
        val before = state.phase
        val streaming = before == "stream"
        // Same place every time for this file: an interrupted or reopened preview resumes.
        val key = java.security.MessageDigest.getInstance("SHA-256")
            .digest("${mac.id}|${state.path}|${state.entry.size}|${state.entry.mtime}".toByteArray()).take(12).joinToString("") { "%02x".format(it) }
        val dest = java.io.File(java.io.File(previewCache, key).also { it.mkdirs() }, state.entry.name)
        if (dest.exists()) { state.file = dest; if (!streaming) state.phase = if (state.kind == PreviewKind.NONE) "unsupported" else "ready"; return then(dest) }
        if (streaming) state.saving = 0f else { state.phase = "loading"; state.progress = 0f }
        state.job = lifecycleScope.launch {
            val scope = coroutineContext
            try {
                var tries = 0
                while (true) {
                    try {
                        withSession { s ->
                            s.downloadToFile(state.path, dest, cancelled = { !scope.isActive }) { d, total ->
                                val t = if (total > 0) total else state.entry.size
                                val f = if (t > 0) d.toFloat() / t else 0f
                                if (streaming) state.saving = f else state.progress = f
                            }
                        }
                        break
                    } catch (e: app.teleport.core.SessionException) {
                        // The computer dropped off for a moment: wait, reconnect, carry on from the saved bytes.
                        if (e.code !in setOf("closed", "offline", "protocol") || ++tries > 60) throw e
                        client = null
                        kotlinx.coroutines.delay(minOf(tries, 5) * 1000L)
                    }
                }
                state.file = dest
                state.saving = null
                if (!streaming) state.phase = if (state.kind == PreviewKind.NONE) "unsupported" else "ready"
                then(dest)
            } catch (e: Exception) {
                state.saving = null
                if (e is CancellationException) { state.phase = before } else if (!streaming) { state.phase = "failed"; state.error = e.message }
                else message = "Couldn't save ${state.entry.name}: ${e.message}" to System.nanoTime()
            }
        }
    }

    /** Copies the previewed file into Download/Teleport (MediaStore: no storage permission). */
    private fun save(state: PreviewState) = fetch(state) { file ->
        lifecycleScope.launch {
            val uri = withContext(Dispatchers.IO) {
                runCatching {
                    val item = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
                        put(MediaStore.Downloads.DISPLAY_NAME, state.entry.name)
                        put(MediaStore.Downloads.RELATIVE_PATH, "Download/Teleport")
                        put(MediaStore.Downloads.IS_PENDING, 1)
                    })!!
                    contentResolver.openOutputStream(item)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
                    contentResolver.update(item, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                    item
                }.getOrNull()
            }
            message = (if (uri != null) "Saved to Download/Teleport" else "Couldn't save ${state.entry.name}") to System.nanoTime()
        }
    }

    private fun upload(uris: List<Uri>) {
        val dir = path
        for (uri in uris) {
            val (name, size) = describe(uri)
            val t = Transfer(name, upload = true).also { it.total = size }
            transfers.add(0, t)
            t.job = lifecycleScope.launch {
                val scope = coroutineContext
                try {
                    val saved = withSession { s ->
                        contentResolver.openInputStream(uri)!!.use { input ->
                            s.upload(input, size, dir, name, cancelled = { !scope.isActive }) { d, total -> t.done = d; t.total = total }
                        }
                    }
                    t.state = "done"
                    t.detail = if (saved != name) "Saved as $saved" else null
                    if (path == dir) load(dir)
                } catch (e: Exception) {
                    if (e is CancellationException) t.state = "cancelled" else { t.state = "failed"; t.detail = e.message }
                }
            }
        }
    }

    private fun describe(uri: Uri): Pair<String, Long> {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val name = c.getString(0)?.replace('/', '-') ?: "file"
                val size = if (c.isNull(1)) 0L else c.getLong(1)
                return name to size
            }
        }
        return (uri.lastPathSegment ?: "file") to 0L
    }

    // ---------- UI ----------

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun Screen() {
        val preview = previewing
        if (preview != null) return PreviewScreen(preview)
        val snackbar = remember { SnackbarHostState() }
        val scroll = TopAppBarDefaults.pinnedScrollBehavior()
        val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { if (it.isNotEmpty()) upload(it) }
        LaunchedEffect(message) { message?.let { snackbar.showSnackbar(it.first) } }
        BackHandler(enabled = path.isNotEmpty()) { load(parent(path)) }

        Scaffold(
            modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
            topBar = {
                TopAppBar(
                    title = {
                        Column {
                            Text(if (path.isEmpty()) mac.name else path.substringAfterLast('/'), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text("~/$path".trimEnd('/'), style = MaterialTheme.typography.labelMedium, fontFamily = FontFamily.Monospace,
                                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.StartEllipsis)
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = { if (path.isEmpty()) finish() else load(parent(path)) }) {
                            SymbolIcon(R.drawable.ic_sym_arrow_back, "Back")
                        }
                    },
                    scrollBehavior = scroll,
                )
            },
            floatingActionButton = {
                if (entries != null) {
                    ExtendedFloatingActionButton(
                        onClick = { pick.launch(arrayOf("*/*")) },
                        icon = { SymbolIcon(R.drawable.ic_sym_upload, tint = MaterialTheme.colorScheme.onPrimaryContainer) },
                        text = { Text("Upload here") },
                    )
                }
            },
            snackbarHost = { SnackbarHost(snackbar) },
        ) { padding ->
            PullToRefreshBox(isRefreshing = loading && entries != null, onRefresh = { load(path) }, modifier = Modifier.padding(padding)) {
                LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 96.dp)) {
                    if (transfers.isNotEmpty()) {
                        item {
                            Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text("Transfers", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.weight(1f))
                                TextButton(onClick = { transfers.removeAll { it.state != "running" } }) { Text("Clear") }
                            }
                        }
                        items(transfers, key = { System.identityHashCode(it) }) { TransferRow(it) }
                    }
                    error?.let { e ->
                        item {
                            ListItem(
                                headlineContent = { Text(e) },
                                supportingContent = { Button(onClick = { load(path) }, Modifier.padding(top = 8.dp)) { Text("Try again") } },
                                colors = grouped(), modifier = Modifier.groupedRow().padding(top = 12.dp),
                            )
                        }
                    }
                    val list = entries
                    if (list == null && error == null) {
                        item {
                            Row(Modifier.fillMaxWidth().padding(32.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                                Text("  Connecting to ${mac.name}…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    if (list != null) {
                        item { Text(" ", Modifier.padding(4.dp)) }
                        if (list.isEmpty()) {
                            item { ListItem(headlineContent = { Text("This folder is empty") }, colors = grouped(), modifier = Modifier.groupedRow()) }
                        }
                        items(list, key = { "e-" + it.name }) { EntryRow(it) }
                    }
                }
            }
        }
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun PreviewScreen(state: PreviewState) {
        val snackbar = remember { SnackbarHostState() }
        LaunchedEffect(message) { message?.let { snackbar.showSnackbar(it.first) } }
        BackHandler { closePreview() }
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(state.entry.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    navigationIcon = { IconButton(onClick = ::closePreview) { SymbolIcon(R.drawable.ic_sym_arrow_back, "Back") } },
                    actions = {
                        TextButton(onClick = { save(state) }, enabled = state.phase != "loading") {
                            SymbolIcon(R.drawable.ic_sym_download, tint = MaterialTheme.colorScheme.primary, size = 20)
                            Text("  Save")
                        }
                    },
                )
            },
            snackbarHost = { SnackbarHost(snackbar) },
        ) { padding ->
            PreviewBody(state, onLoad = { fetch(state) }, contentPadding = padding,
                // Called on the player's own threads (never the main thread); `cancelled` lets a
                // closing player abandon a read at once instead of waiting for the network.
                stream = { offset, length, cancelled ->
                    streamRead(state.path, offset, length, cancelled)
                })
        }
    }

    @Composable
    private fun EntryRow(entry: FileEntry) {
        val modified = DateUtils.getRelativeTimeSpanString(entry.mtime * 1000, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
        ListItem(
            headlineContent = { Text(entry.name, maxLines = 2, overflow = TextOverflow.Ellipsis) },
            supportingContent = {
                Text(if (entry.dir) "Folder · $modified" else "${Formatter.formatShortFileSize(this, entry.size)} · $modified")
            },
            leadingContent = {
                SymbolIcon(
                    if (entry.dir) R.drawable.ic_sym_folder else iconFor(entry.name),
                    tint = if (entry.dir) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            colors = grouped(),
            modifier = Modifier.groupedRow().clickable { if (entry.dir) load(child(entry.name)) else openPreview(entry) },
        )
    }

    @Composable
    private fun TransferRow(t: Transfer) {
        ListItem(
            headlineContent = { Text(t.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            supportingContent = {
                when (t.state) {
                    "running" -> Column {
                        LinearProgressIndicator(
                            progress = { if (t.total > 0) (t.done.toFloat() / t.total).coerceIn(0f, 1f) else 0f },
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                        )
                        Text("${Formatter.formatShortFileSize(this@MacBrowserActivity, t.done)} of ${Formatter.formatShortFileSize(this@MacBrowserActivity, t.total)}")
                    }
                    "done" -> Text(t.detail ?: if (t.upload) "Uploaded to ${mac.name}" else "Saved to Download/Teleport", color = MaterialTheme.colorScheme.primary)
                    "cancelled" -> Text("Cancelled")
                    else -> Text(t.detail ?: "Failed", color = MaterialTheme.colorScheme.error)
                }
            },
            leadingContent = {
                SymbolIcon(if (t.upload) R.drawable.ic_sym_upload else R.drawable.ic_sym_download, tint = MaterialTheme.colorScheme.primary)
            },
            trailingContent = {
                if (t.state == "running") {
                    IconButton(onClick = { t.job?.cancel() }) { SymbolIcon(R.drawable.ic_sym_close, "Cancel") }
                }
            },
            colors = grouped(),
            modifier = Modifier.groupedRow(),
        )
    }

    @Composable
    private fun grouped() = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainer)
    private fun Modifier.groupedRow() = padding(horizontal = 16.dp, vertical = 2.dp).clip(RoundedCornerShape(16.dp))

    private fun iconFor(name: String): Int {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp", "svg" -> R.drawable.ic_sym_image
            "mov", "mp4", "m4v", "mkv", "avi", "webm" -> R.drawable.ic_sym_movie
            else -> R.drawable.ic_sym_description
        }
    }
}
