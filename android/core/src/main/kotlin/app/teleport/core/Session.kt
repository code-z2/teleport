package app.teleport.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

// File sessions: SPEC.md "File sessions (v2)". Signed ephemeral ECDH through the Mac's
// relay mailbox, then AES-GCM frames with implicit counters.

object SessionCrypto {
    private val INFO = "teleport/v1/session".toByteArray()
    const val PHONE_TO_MAC = 1
    const val MAC_TO_PHONE = 2
    const val CHUNK = 256 * 1024
    const val WINDOW = 2L * 1024 * 1024
    const val ACK_EVERY = 1024L * 1024

    fun helloTranscript(mailbox: String, from: String, epk: String, n: String, ts: Long): ByteArray =
        "teleport/v1/session|$mailbox|$from|$epk|$n|$ts".toByteArray()

    fun acceptTranscript(hello: ByteArray, epk: String, n: String): ByteArray = hello + "|$epk|$n".toByteArray()

    /** 64 bytes from HKDF: phone→Mac key, then Mac→phone key. */
    fun keys(sharedSecret: ByteArray, acceptTranscript: ByteArray): Pair<ByteArray, ByteArray> {
        val okm = Primitives.hkdfSha256(sharedSecret, Primitives.sha256(acceptTranscript), INFO, 64)
        return okm.copyOfRange(0, 32) to okm.copyOfRange(32, 64)
    }
}

/** One direction of a session: AES-256-GCM, nonce = dir (u32 BE) ‖ counter (u64 BE). */
class FrameCipher(private val key: ByteArray, private val dir: Int, private var counter: Long = 0) {
    private fun nonce(): ByteArray = ByteBuffer.allocate(12).putInt(dir).putLong(counter).array()

    fun seal(plaintext: ByteArray): ByteArray =
        Primitives.aesGcm(true, key, nonce(), plaintext, ByteArray(0)).also { counter++ }

    fun open(frame: ByteArray): ByteArray =
        Primitives.aesGcm(false, key, nonce(), frame, ByteArray(0)).also { counter++ }
}

@Serializable
data class FileEntry(val name: String, val dir: Boolean, val size: Long, val mtime: Long)

/** A control message: one flat shape for every `op`; unused fields are omitted. */
@Serializable
data class Control(
    val op: String,
    val id: Long,
    val path: String? = null,
    val offset: Long? = null,
    val size: Long? = null,
    val mime: String? = null,
    val sha256: String? = null,
    val name: String? = null,
    val dir: String? = null,
    val bytes: Long? = null,
    /** `thumbnail`: longest side in pixels. */
    val px: Int? = null,
    val entries: List<FileEntry>? = null,
    val code: String? = null,
    val message: String? = null,
)

sealed class SessionFrame {
    abstract val id: Long
    data class Ctl(val c: Control) : SessionFrame() { override val id get() = c.id }
    class Data(override val id: Long, val bytes: ByteArray) : SessionFrame()

    fun encode(): ByteArray = when (this) {
        is Ctl -> byteArrayOf(1) + SessionJson.encodeToString(Control.serializer(), c).toByteArray()
        is Data -> ByteBuffer.allocate(5 + bytes.size).put(2).putInt(id.toInt()).put(bytes).array()
    }

    companion object {
        fun decode(p: ByteArray): SessionFrame = when {
            p.isNotEmpty() && p[0] == 1.toByte() ->
                Ctl(SessionJson.decodeFromString(Control.serializer(), String(p, 1, p.size - 1)))
            p.size >= 5 && p[0] == 2.toByte() ->
                Data(ByteBuffer.wrap(p, 1, 4).int.toLong() and 0xffffffffL, p.copyOfRange(5, p.size))
            else -> throw SessionException("protocol", "The Mac sent something unexpected.")
        }
    }
}

internal val SessionJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

/** Every session failure. [code] is the SPEC error code, or a local one ("offline", "closed"…). */
open class SessionException(val code: String, message: String) : Exception(message)

/** An ordered byte pipe to the Mac (a WebSocket in the app, in-memory in tests). */
interface SessionPipe {
    fun send(data: ByteArray)
    /** Blocks for the next message; null once the pipe is closed. */
    fun receive(): ByteArray?
    fun close()
}

/** Lexical path rules (SPEC.md "Path rules"); the normalised path, or null. */
object FilePaths {
    fun check(path: String, showHidden: Boolean): String? {
        if (path.startsWith("/") || path.contains('\u0000')) return null
        val parts = path.split("/").filter { it.isNotEmpty() && it != "." }
        if (parts.contains("..")) return null
        if (!showHidden && parts.withIndex().any { (i, p) -> p.startsWith(".") || (i == 0 && p == "Library") }) return null
        return parts.joinToString("/")
    }
}

/**
 * The phone's end of a file session. Blocking (call from Dispatchers.IO); operations may run on
 * several threads at once. Cancel a transfer by making [cancelled] return true.
 */
class FileSessionClient private constructor(private val pipe: SessionPipe, private val tx: FrameCipher, private val rx: FrameCipher) {
    private val nextId = AtomicInteger(1)
    private val routes = ConcurrentHashMap<Long, LinkedBlockingQueue<Any>>()
    @Volatile private var failure: SessionException? = null

    private object Closed

    companion object {
        /** Handshake over [pipe] (SPEC.md "Handshake"). */
        fun handshake(pipe: SessionPipe, signer: SigningKey, mailbox: String, macKs: ByteArray,
                      now: Long = System.currentTimeMillis() / 1000): FileSessionClient {
            val eph = P256.generate()
            val ephKey = JcaAgreementKey(eph.private, P256.raw(eph.public as java.security.interfaces.ECPublicKey))
            val epk = ephKey.publicKey.b64u()
            val n = randomBytes(16).b64u()
            val from = TeleportCrypto.fingerprint(signer.publicKey)
            val helloT = SessionCrypto.helloTranscript(mailbox, from, epk, n, now)
            val hello = """{"t":"hello","v":1,"from":"$from","epk":"$epk","n":"$n","ts":$now,"sig":"${signer.sign(helloT).b64u()}"}"""
            pipe.send(hello.toByteArray())

            val first = pipe.receive() ?: throw SessionException("closed", "The connection to the Mac closed.")
            val o = runCatching { Json.parseToJsonElement(String(first)).jsonObject }.getOrNull()
                ?: throw SessionException("protocol", "The Mac sent something unexpected.")
            fun s(k: String) = o[k]?.jsonPrimitive?.content
            if (s("t") == "error") throw refused(s("code") ?: "unknown")
            val macEpk = s("epk") ?: throw SessionException("protocol", "The Mac sent something unexpected.")
            val macN = s("n") ?: ""
            val acceptT = SessionCrypto.acceptTranscript(helloT, macEpk, macN)
            val sig = s("sig")?.let { runCatching { it.unb64u() }.getOrNull() }
            if (sig == null || !Primitives.verify(macKs, acceptT, sig)) {
                throw SessionException("untrusted", "The Mac's identity didn't check out.")
            }
            val (p2m, m2p) = SessionCrypto.keys(ephKey.sharedSecret(macEpk.unb64u()), acceptT)
            return FileSessionClient(pipe, FrameCipher(p2m, SessionCrypto.PHONE_TO_MAC), FrameCipher(m2p, SessionCrypto.MAC_TO_PHONE))
                .also { it.startReader() }
        }

        private fun refused(code: String) = SessionException(code, when (code) {
            "denied" -> "The Mac doesn't recognise this phone. Pair them again."
            "stale" -> "This phone's clock is too far off the Mac's."
            else -> "The Mac refused the connection ($code)."
        })
    }

    private fun startReader() {
        thread(name = "teleport-session", isDaemon = true) {
            try {
                while (true) {
                    val frame = pipe.receive() ?: break
                    val msg = SessionFrame.decode(synchronized(rx) { rx.open(frame) })
                    routes[msg.id]?.put(msg)
                }
                fail(SessionException("closed", "The connection to the Mac closed."))
            } catch (e: Exception) {
                fail(e as? SessionException ?: SessionException("closed", "The connection to the Mac closed."))
            }
        }
    }

    private fun fail(e: SessionException) {
        if (failure != null) return
        failure = e
        routes.values.forEach { it.put(Closed) }
        pipe.close()
    }

    val isOpen: Boolean get() = failure == null

    fun close() = fail(SessionException("closed", "The connection to the Mac closed."))

    private fun send(f: SessionFrame) {
        failure?.let { throw it }
        synchronized(tx) { pipe.send(tx.seal(f.encode())) }
    }

    private fun begin(make: (Long) -> Control): Pair<Long, LinkedBlockingQueue<Any>> {
        failure?.let { throw it }
        val id = nextId.getAndIncrement().toLong() and 0xffffffffL
        val q = LinkedBlockingQueue<Any>()
        routes[id] = q
        send(SessionFrame.Ctl(make(id)))
        return id to q
    }

    /** Next frame for an operation; throws on failure, remote error or cancellation. */
    private fun next(q: LinkedBlockingQueue<Any>, cancelled: () -> Boolean): SessionFrame {
        while (true) {
            if (cancelled()) throw CancellationException()
            when (val item = q.poll(200, TimeUnit.MILLISECONDS)) {
                null -> continue
                Closed -> throw failure ?: SessionException("closed", "The connection to the Mac closed.")
                is SessionFrame.Ctl -> {
                    if (item.c.op == "error") throw SessionException(item.c.code ?: "io", item.c.message ?: "The Mac couldn't do that.")
                    if (item.c.op == "cancel") throw CancellationException()
                    return item
                }
                is SessionFrame -> return item
            }
        }
    }

    private fun end(id: Long, cancel: Boolean) {
        routes.remove(id)
        if (cancel && failure == null) runCatching { send(SessionFrame.Ctl(Control("cancel", id))) }
    }

    fun list(path: String): List<FileEntry> {
        val (id, q) = begin { Control("list", it, path = path) }
        try {
            while (true) {
                val f = next(q) { false }
                if (f is SessionFrame.Ctl && f.c.op == "entries") return f.c.entries.orEmpty()
            }
        } finally {
            end(id, cancel = false)
        }
    }

    /** Streams [path] into [out]. Returns the MIME type. Throws on a hash mismatch (discard [out] then). */
    fun download(path: String, out: OutputStream, cancelled: () -> Boolean = { false },
                 progress: (done: Long, total: Long) -> Unit = { _, _ -> }): String {
        val (id, q) = begin { Control("download", it, path = path) }
        var ok = false
        try {
            val sha = MessageDigest.getInstance("SHA-256")
            var total = 0L; var got = 0L; var acked = 0L; var mime = "application/octet-stream"
            while (true) {
                when (val f = next(q, cancelled)) {
                    is SessionFrame.Data -> {
                        out.write(f.bytes); sha.update(f.bytes); got += f.bytes.size
                        if (got - acked >= SessionCrypto.ACK_EVERY) {
                            send(SessionFrame.Ctl(Control("ack", id, bytes = got))); acked = got
                        }
                        progress(got, total)
                    }
                    is SessionFrame.Ctl -> when (f.c.op) {
                        "meta" -> { total = f.c.size ?: 0; mime = f.c.mime ?: mime; progress(0, total) }
                        "done" -> {
                            if (sha.digest().b64u() != f.c.sha256) throw SessionException("hash", "The file was corrupted in transit. Try again.")
                            ok = true
                            return mime
                        }
                    }
                }
            }
        } finally {
            end(id, cancel = !ok)
        }
    }

    /** A JPEG thumbnail rendered by Quick Look on the Mac, or null if it can't preview this file. */
    fun thumbnail(path: String, px: Int = 512): ByteArray? {
        val (id, q) = begin { Control("thumbnail", it, path = path, px = px) }
        try {
            val out = java.io.ByteArrayOutputStream()
            while (true) {
                val f = try { next(q) { false } } catch (e: SessionException) {
                    if (e.code == "unsupported") return null else throw e
                }
                when (f) {
                    is SessionFrame.Data -> out.write(f.bytes)
                    is SessionFrame.Ctl -> if (f.c.op == "done") {
                        val bytes = out.toByteArray()
                        if (MessageDigest.getInstance("SHA-256").digest(bytes).b64u() != f.c.sha256) {
                            throw SessionException("hash", "The preview was corrupted in transit.")
                        }
                        return bytes
                    }
                }
            }
        } finally {
            end(id, cancel = false)
        }
    }

    /** Uploads [size] bytes from [input] into Mac folder [dir]. Returns the name the Mac saved it as. */
    fun upload(input: InputStream, size: Long, dir: String, name: String, cancelled: () -> Boolean = { false },
               progress: (done: Long, total: Long) -> Unit = { _, _ -> }): String {
        val (id, q) = begin { Control("upload", it, dir = dir, name = name, size = size) }
        var ok = false
        try {
            var saved = name
            while (true) {
                val f = next(q, cancelled)
                if (f is SessionFrame.Ctl && f.c.op == "ready") { saved = f.c.name ?: name; break }
            }
            val sha = MessageDigest.getInstance("SHA-256")
            val buf = ByteArray(SessionCrypto.CHUNK)
            var sent = 0L; var acked = 0L
            progress(0, size)
            while (true) {
                val read = input.readNBytes(buf, 0, buf.size)
                if (read <= 0) break
                while (sent - acked >= SessionCrypto.WINDOW) {
                    val f = next(q, cancelled)
                    if (f is SessionFrame.Ctl && f.c.op == "ack") acked = maxOf(acked, f.c.bytes ?: 0)
                }
                if (cancelled()) throw CancellationException()
                val chunk = buf.copyOf(read)
                send(SessionFrame.Data(id, chunk)); sha.update(chunk); sent += read
                progress(sent, size)
            }
            send(SessionFrame.Ctl(Control("done", id, sha256 = sha.digest().b64u())))
            while (true) {
                val f = next(q, cancelled)
                if (f is SessionFrame.Ctl && f.c.op == "saved") { ok = true; return f.c.name ?: saved }
            }
        } finally {
            end(id, cancel = !ok)
        }
    }
}
