package app.teleport.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.widget.MediaController
import android.widget.VideoView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import app.teleport.core.FileEntry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/** What kind of built-in viewer a file gets. */
enum class PreviewKind { IMAGE, PDF, TEXT, MEDIA, NONE;
    companion object {
        fun of(name: String): PreviewKind = when (name.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "avif" -> IMAGE
            "pdf" -> PDF
            "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "log", "ini", "toml", "conf",
            "swift", "kt", "kts", "java", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cpp", "hpp",
            "m", "sh", "zsh", "fish", "html", "htm", "css", "sql", "gradle", "properties", "env", "plist" -> TEXT
            "mp4", "m4v", "mov", "webm", "mkv", "3gp", "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus" -> MEDIA
            else -> NONE
        }
    }
}

/** One open preview: file → preview → save. Nothing is saved until Save is tapped. */
class PreviewState(val entry: FileEntry, val path: String) {
    val kind = PreviewKind.of(entry.name)
    var thumbnail by mutableStateOf<Bitmap?>(null)
    /** loading | thumb (large, waiting for "Load preview") | ready | unsupported | failed | stream (playing while on the computer) */
    var phase by mutableStateOf(if (kind == PreviewKind.NONE) "unsupported" else "loading")
    var progress by mutableFloatStateOf(0f)
    var error by mutableStateOf<String?>(null)
    var file by mutableStateOf<File?>(null)
    /** Saving a file that's streaming: download progress, shown over the player. */
    var saving by mutableStateOf<Float?>(null)
    var job: Job? = null

    companion object {
        /** Files above this size ask before fetching the whole thing just to look at it. */
        const val AUTO_PREVIEW_LIMIT = 50L * 1024 * 1024
    }
}

@Composable
fun PreviewBody(state: PreviewState, onLoad: () -> Unit, contentPadding: PaddingValues, stream: (Long, Int, () -> Boolean) -> ByteArray) {
    val file = state.file
    Box(Modifier.fillMaxSize().padding(contentPadding)) {
        when {
            state.phase == "stream" -> Box(Modifier.fillMaxSize()) {
                StreamingPlayer(state.entry.size, stream)
                state.saving?.let { f ->
                    Column(
                        Modifier.align(Alignment.BottomCenter).padding(bottom = 96.dp)
                            .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(24.dp)).padding(horizontal = 16.dp, vertical = 10.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        LinearProgressIndicator(progress = { f }, modifier = Modifier.width(160.dp))
                        Text("Saving… ${(f * 100).toInt()}%", style = MaterialTheme.typography.labelMedium)
                    }
                }
            }
            state.phase == "ready" && file != null -> when (state.kind) {
                PreviewKind.IMAGE -> ZoomableImage(file)
                PreviewKind.PDF -> PdfPages(file)
                PreviewKind.TEXT -> TextPreview(file)
                PreviewKind.MEDIA -> MediaPreview(file)
                PreviewKind.NONE -> Placeholder(state) { Text("Can't preview this file", style = MaterialTheme.typography.titleMedium) }
            }
            state.phase == "loading" -> Placeholder(state) {
                LinearProgressIndicator(progress = { state.progress }, modifier = Modifier.fillMaxWidth(0.6f))
                Text("Loading preview… ${(state.progress * 100).toInt()}%", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            state.phase == "thumb" -> Placeholder(state) {
                Button(onClick = onLoad) { Text("Load preview") }
            }
            state.phase == "failed" -> Placeholder(state) {
                Text(state.error ?: "Couldn't load the preview", color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
                Button(onClick = onLoad) { Text("Try again") }
            }
            else -> Placeholder(state) {
                Text("Can't preview this file", style = MaterialTheme.typography.titleMedium)
                Text("You can still save it.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** Thumbnail (or a big file icon), name and size, then [extra]. */
@Composable
private fun Placeholder(state: PreviewState, extra: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        val thumb = state.thumbnail
        if (thumb != null) {
            Image(thumb.asImageBitmap(), null, Modifier.sizeIn(maxWidth = 280.dp, maxHeight = 280.dp).clip(RoundedCornerShape(12.dp)))
        } else {
            SymbolIcon(if (state.kind == PreviewKind.IMAGE) R.drawable.ic_sym_image else if (state.kind == PreviewKind.MEDIA) R.drawable.ic_sym_movie else R.drawable.ic_sym_description, size = 72)
        }
        Text(state.entry.name, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Text(android.text.format.Formatter.formatShortFileSize(androidx.compose.ui.platform.LocalContext.current, state.entry.size),
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        extra()
    }
}

/** Downsampled to fit 2048 px; pinch to zoom, drag to pan. */
@Composable
private fun ZoomableImage(file: File) {
    val bitmap by produceState<Bitmap?>(null, file) {
        value = withContext(Dispatchers.IO) {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 2048) sample *= 2
            BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
        }
    }
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val bmp = bitmap ?: return
    Image(
        bmp.asImageBitmap(), null,
        contentScale = ContentScale.Fit,
        modifier = Modifier.fillMaxSize()
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    scale = (scale * zoom).coerceIn(1f, 6f)
                    offset = if (scale == 1f) Offset.Zero else offset + pan
                }
            }
            .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y),
    )
}

/** Every page rendered at screen width, lazily, with Android's PdfRenderer. */
@Composable
private fun PdfPages(file: File) {
    val renderer = remember(file) {
        runCatching { PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)) }.getOrNull()
    }
    DisposableEffect(renderer) { onDispose { renderer?.close() } }
    if (renderer == null) {
        Text("This PDF can't be opened.", Modifier.padding(24.dp))
        return
    }
    val lock = remember { Mutex() }  // PdfRenderer allows one open page at a time
    LazyColumn(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceContainerHighest),
        contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        items(renderer.pageCount) { index ->
            val page by produceState<Bitmap?>(null, index) {
                value = withContext(Dispatchers.IO) {
                    lock.withLock {
                        renderer.openPage(index).use { p ->
                            val width = 1240
                            val bmp = Bitmap.createBitmap(width, width * p.height / p.width, Bitmap.Config.ARGB_8888)
                            bmp.eraseColor(Color.WHITE)
                            p.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            bmp
                        }
                    }
                }
            }
            val bmp = page
            if (bmp != null) {
                Image(bmp.asImageBitmap(), "Page ${index + 1}", Modifier.fillMaxWidth().aspectRatio(bmp.width.toFloat() / bmp.height))
            } else {
                Spacer(Modifier.fillMaxWidth().height(400.dp).background(MaterialTheme.colorScheme.surface))
            }
        }
    }
}

/** The first 1 MB as UTF-8, selectable, monospaced, scrollable both ways. */
@Composable
private fun TextPreview(file: File) {
    val text by produceState<String?>(null, file) {
        value = withContext(Dispatchers.IO) {
            val bytes = file.inputStream().use { it.readNBytes(1024 * 1024) }
            String(bytes, Charsets.UTF_8) + if (file.length() > bytes.size) "\n\n… (preview shows the first 1 MB)" else ""
        }
    }
    SelectionContainer {
        Text(
            text ?: "",
            fontFamily = FontFamily.Monospace,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()).padding(16.dp),
        )
    }
}

/** Video and audio with the system media controls. */
@Composable
private fun MediaPreview(file: File) {
    AndroidView(
        factory = { context ->
            VideoView(context).apply {
                setVideoPath(file.path)
                setMediaController(MediaController(context).also { it.setAnchorView(this) })
                setOnPreparedListener { start() }
            }
        },
        onRelease = { it.stopPlayback() },
        modifier = Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black),
    )
}

/**
 * Plays video or audio while it's still on the computer: MediaPlayer reads through a
 * MediaDataSource that fetches blocks over the encrypted session, staying a few blocks ahead
 * of playback. Tap the picture or ▶ to play and pause; drag the bar to seek (one seek when
 * you let go).
 *
 * Threading: MediaPlayer blocks while its data source waits on the network, and any call on
 * it (even setDisplay or currentPosition) waits behind that. So every call happens on the
 * player's own thread (`PlayerThread`), never the main thread; the screen only waits up to
 * 250 ms when its surface goes away. Leaving closes the source first, so reads stop at once.
 */
@Composable
private fun StreamingPlayer(size: Long, read: (Long, Int, () -> Boolean) -> ByteArray) {
    val source = remember { BlockDataSource(size, read) }
    val p = remember { PlayerThread() }
    var playing by remember { mutableStateOf(false) }
    var position by remember { mutableFloatStateOf(0f) }
    var duration by remember { mutableFloatStateOf(0f) }
    var ready by remember { mutableStateOf(false) }
    var dragging by remember { mutableStateOf<Float?>(null) }
    var buffering by remember { mutableStateOf(true) }
    val main = remember { android.os.Handler(android.os.Looper.getMainLooper()) }

    fun toggle() {
        if (!ready) return
        p.post { mp ->
            val now = runCatching { if (mp.isPlaying) { mp.pause(); false } else { mp.start(); true } }.getOrNull()
            if (now != null) main.post { playing = now }
        }
    }

    DisposableEffect(Unit) {
        p.post { mp ->
            mp.setDataSource(source)
            mp.setOnPreparedListener { it.start(); val d = it.duration.toFloat(); main.post { ready = true; buffering = false; duration = d; playing = true } }
            mp.setOnCompletionListener { main.post { playing = false } }
            mp.setOnInfoListener { _, what, _ ->
                when (what) {
                    android.media.MediaPlayer.MEDIA_INFO_BUFFERING_START -> main.post { buffering = true }
                    android.media.MediaPlayer.MEDIA_INFO_BUFFERING_END -> main.post { buffering = false }
                }
                false
            }
            mp.setOnSeekCompleteListener { main.post { buffering = false } }
            mp.setOnErrorListener { _, _, _ -> main.post { playing = false; buffering = false }; true }
            mp.prepareAsync()
        }
        onDispose {
            source.close()  // pending reads give up, so the player thread frees up quickly
            p.shutdown()
        }
    }
    LaunchedEffect(ready) {
        while (ready) {
            if (dragging == null) p.post { mp -> runCatching { mp.currentPosition.toFloat() }.getOrNull()?.let { main.post { if (dragging == null) position = it } } }
            kotlinx.coroutines.delay(250)
        }
    }
    Column(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) {
        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
            AndroidView(
                factory = { ctx ->
                    android.view.SurfaceView(ctx).apply {
                        holder.addCallback(object : android.view.SurfaceHolder.Callback {
                            override fun surfaceCreated(h: android.view.SurfaceHolder) { p.post { it.setDisplay(h) } }
                            override fun surfaceChanged(h: android.view.SurfaceHolder, f: Int, w: Int, hh: Int) {}
                            // The surface must be released before this returns, but never block
                            // the main thread on the network: wait briefly, then let it go.
                            override fun surfaceDestroyed(h: android.view.SurfaceHolder) { p.postAndWait(250) { it.setDisplay(null) } }
                        })
                        setOnClickListener { toggle() }
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
            if (buffering) androidx.compose.material3.CircularProgressIndicator(color = androidx.compose.ui.graphics.Color.White)
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            androidx.compose.material3.IconButton(onClick = ::toggle, enabled = ready) {
                Text(if (playing) "❚❚" else "▶", color = androidx.compose.ui.graphics.Color.White)
            }
            Text(clock(dragging?.times(duration) ?: position), color = androidx.compose.ui.graphics.Color.White, style = MaterialTheme.typography.labelMedium)
            androidx.compose.material3.Slider(
                value = dragging ?: if (duration > 0) position / duration else 0f,
                onValueChange = { dragging = it },
                onValueChangeFinished = {
                    val f = dragging
                    dragging = null
                    if (f != null && ready && duration > 0) {
                        position = f * duration
                        buffering = true
                        val to = (f * duration).toLong()
                        p.post { runCatching { it.seekTo(to, android.media.MediaPlayer.SEEK_CLOSEST_SYNC) } }
                    }
                },
                enabled = ready,
                modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
            )
            Text(clock(duration), color = androidx.compose.ui.graphics.Color.White, style = MaterialTheme.typography.labelMedium)
        }
    }
}

/**
 * A MediaPlayer that's only ever touched on its own thread. It's also *created* there:
 * MediaPlayer delivers its events (prepared, info, subtitle-track scans…) on the looper of the
 * thread that constructed it, and those calls block on the data source too. Created on the
 * main thread, they froze the screen.
 */
private class PlayerThread {
    private val thread = android.os.HandlerThread("teleport-player").apply { start() }
    private val handler = android.os.Handler(thread.looper)
    private lateinit var player: android.media.MediaPlayer
    @Volatile private var done = false

    init {
        handler.post { player = android.media.MediaPlayer() }
    }

    fun post(block: (android.media.MediaPlayer) -> Unit) {
        if (!done) handler.post { if (!done) runCatching { block(player) } }
    }

    /** Runs [block] on the player thread, waiting at most [ms] for it. */
    fun postAndWait(ms: Long, block: (android.media.MediaPlayer) -> Unit) {
        if (done) return
        val latch = java.util.concurrent.CountDownLatch(1)
        handler.post { if (!done) runCatching { block(player) }; latch.countDown() }
        latch.await(ms, java.util.concurrent.TimeUnit.MILLISECONDS)
    }

    fun shutdown() {
        done = true
        handler.post {
            runCatching { player.reset() }
            runCatching { player.release() }
            thread.quitSafely()
        }
    }
}

private fun clock(ms: Float): String {
    val s = (ms / 1000).toInt()
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/**
 * Serves MediaPlayer's reads from 2 MiB blocks fetched on demand, keeps a few for rewinds,
 * and fetches the next four in the background (two at a time) so playback doesn't stall.
 */
private class BlockDataSource(private val total: Long, private val fetch: (Long, Int, () -> Boolean) -> ByteArray) : android.media.MediaDataSource() {
    private val block = 2 shl 20  // the largest single read the protocol allows
    private val lock = Object()
    private val cache = object : LinkedHashMap<Long, ByteArray>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, ByteArray>?) = size > 12
    }
    private val inflight = HashSet<Long>()
    private val prefetcher = java.util.concurrent.Executors.newFixedThreadPool(2)
    @Volatile private var closed = false
    private val blocks = (total + block - 1) / block

    override fun getSize(): Long = total

    /** A block from the cache, or fetched now (waiting for a prefetch already under way). */
    private fun blockAt(index: Long): ByteArray? {
        synchronized(lock) {
            while (true) {
                cache[index]?.let { return it }
                if (closed) return null
                if (index !in inflight) { inflight += index; break }
                try { lock.wait(200) } catch (e: InterruptedException) { return null }
            }
        }
        val data = runCatching { fetch(index * block, block) { closed } }.getOrNull()
        synchronized(lock) {
            inflight -= index
            if (data != null) cache[index] = data
            lock.notifyAll()
        }
        return data
    }

    private fun prefetch(index: Long) {
        if (index >= blocks || closed) return
        synchronized(lock) { if (cache.containsKey(index) || index in inflight) return }
        runCatching { prefetcher.execute { runCatching { blockAt(index) } } }
    }

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (closed) return -1
        if (position >= total) return -1
        var copied = 0
        while (copied < size && position + copied < total) {
            val at = position + copied
            val index = at / block
            val data = blockAt(index) ?: return if (copied > 0) copied else -1
            for (ahead in 1..4) prefetch(index + ahead)
            val within = (at - index * block).toInt()
            if (within >= data.size) break
            val n = minOf(size - copied, data.size - within)
            System.arraycopy(data, within, buffer, offset + copied, n)
            copied += n
        }
        return copied
    }

    override fun close() {
        closed = true
        synchronized(lock) { lock.notifyAll() }
        // Not shutdownNow(): interrupting a thread mid-wait crashed the app. Closed reads end
        // within ~200 ms by themselves.
        prefetcher.shutdown()
    }
}
