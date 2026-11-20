package app.teleport.android

import app.teleport.core.SessionException
import app.teleport.core.SessionPipe
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** A file session's WebSocket to the relay (SPEC.md "Sessions"). Blocking receive for the core client. */
class OkHttpSessionPipe private constructor() : SessionPipe {
    private val inbox = LinkedBlockingQueue<Any>()
    private lateinit var socket: WebSocket
    @Volatile private var closed = false

    private object End

    companion object {
        private val http = OkHttpClient.Builder()
            .pingInterval(20, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()

        fun open(url: String, authorization: String): OkHttpSessionPipe {
            val pipe = OkHttpSessionPipe()
            val request = Request.Builder().url(url).header("Authorization", authorization).build()
            pipe.socket = http.newWebSocket(request, pipe.listener)
            return pipe
        }
    }

    private val listener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, bytes: ByteString) { inbox.put(bytes.toByteArray()) }
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null); inbox.put(End) }
        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { inbox.put(End) }
        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            inbox.put(
                when (response?.code) {
                    503 -> SessionException("offline", "The Mac is offline. Check it's awake and connected.")
                    401 -> SessionException("unauthorized", "The relay rejected this app's key.")
                    else -> SessionException("closed", "The connection to the Mac closed.")
                },
            )
        }
    }

    override fun send(data: ByteArray) {
        if (!closed) socket.send(data.toByteString())
    }

    override fun receive(): ByteArray? {
        if (closed && inbox.isEmpty()) return null
        return when (val item = inbox.take()) {
            is ByteArray -> item
            is SessionException -> { closed = true; throw item }
            else -> { closed = true; null }
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        socket.close(1000, null)
        inbox.put(End)
    }
}
