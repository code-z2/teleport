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
    /** loading | thumb (large, waiting for "Load preview") | ready | unsupported | failed */
    var phase by mutableStateOf(if (kind == PreviewKind.NONE) "unsupported" else "loading")
    var progress by mutableFloatStateOf(0f)
    var error by mutableStateOf<String?>(null)
    var file by mutableStateOf<File?>(null)
    var job: Job? = null

    companion object {
        /** Files above this size ask before fetching the whole thing just to look at it. */
        const val AUTO_PREVIEW_LIMIT = 50L * 1024 * 1024
    }
}

@Composable
fun PreviewBody(state: PreviewState, onLoad: () -> Unit, contentPadding: PaddingValues) {
    val file = state.file
    Box(Modifier.fillMaxSize().padding(contentPadding)) {
        when {
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
