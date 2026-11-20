package app.teleport.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.security.interfaces.ECPublicKey
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class SessionTest {
    private val v = Json.parseToJsonElement(File(System.getProperty("vectors")).readText()).jsonObject
    private val s = v["session"]!!.jsonObject
    private fun JsonObject.str(k: String) = this[k]!!.jsonPrimitive.content
    private fun key(o: JsonObject) = JcaAgreementKey(P256.privateKey(o.str("d").unb64u()), o.str("pub").unb64u())

    @Test fun signaturesVerify() {
        val h = s["hello"]!!.jsonObject
        val helloT = SessionCrypto.helloTranscript(s.str("mailbox"), h.str("from"), h.str("epk"), h.str("n"), h["ts"]!!.jsonPrimitive.long)
        assertTrue(Primitives.verify(v["sender_ks"]!!.jsonObject.str("pub").unb64u(), helloT, h.str("sig").unb64u()))
        val a = s["accept"]!!.jsonObject
        val acceptT = SessionCrypto.acceptTranscript(helloT, a.str("epk"), a.str("n"))
        assertEquals(s.str("accept_transcript"), acceptT.b64u())
        assertTrue(Primitives.verify(s["mac_ks"]!!.jsonObject.str("pub").unb64u(), acceptT, a.str("sig").unb64u()))
    }

    @Test fun keysMatch() {
        val acceptT = s.str("accept_transcript").unb64u()
        val phone = SessionCrypto.keys(key(s["phone_eph"]!!.jsonObject).sharedSecret(s["accept"]!!.jsonObject.str("epk").unb64u()), acceptT)
        val mac = SessionCrypto.keys(key(s["mac_eph"]!!.jsonObject).sharedSecret(s["hello"]!!.jsonObject.str("epk").unb64u()), acceptT)
        assertEquals(s.str("k_p2m"), phone.first.b64u())
        assertEquals(s.str("k_m2p"), mac.second.b64u())
    }

    @Test fun framesMatch() {
        for (f in s["frames"]!!.jsonArray.map { it.jsonObject }) {
            val dir = f.str("dir").toInt()
            val k = s.str(if (dir == 1) "k_p2m" else "k_m2p").unb64u()
            val counter = f.str("counter").toLong()
            assertEquals(f.str("frame"), FrameCipher(k, dir, counter).seal(f.str("plaintext").unb64u()).b64u())
            assertEquals(f.str("plaintext"), FrameCipher(k, dir, counter).open(f.str("frame").unb64u()).b64u())
            assertFailsWith<Exception> { FrameCipher(k, dir, counter + 1).open(f.str("frame").unb64u()) }
            SessionFrame.decode(f.str("plaintext").unb64u())
        }
    }

    @Test fun pathRules() {
        for (p in s["paths"]!!.jsonArray.map { it.jsonObject }) {
            val ok = p["ok"]!!.jsonPrimitive.let { if (it.content == "null" && !it.isString) null else it.content }
            assertEquals(ok, FilePaths.check(p.str("path"), p["hidden"]!!.jsonPrimitive.booleanOrNull!!), p.str("path"))
        }
    }

    // ---------- client against a minimal fake Mac ----------

    private class MemPipe(val inbox: LinkedBlockingQueue<ByteArray>, val outbox: LinkedBlockingQueue<ByteArray>) : SessionPipe {
        override fun send(data: ByteArray) { outbox.put(data) }
        override fun receive(): ByteArray? = inbox.take().takeIf { it.isNotEmpty() }
        override fun close() { outbox.put(ByteArray(0)) }
    }

    private val phoneKs = P256.generate().let { JcaSigningKey(it.private, P256.raw(it.public as ECPublicKey)) }
    private val macKs = P256.generate().let { JcaSigningKey(it.private, P256.raw(it.public as ECPublicKey)) }

    /** Accepts the hello, then serves one file ("big.bin") and a listing, and stores uploads. */
    private fun fakeMac(pipe: MemPipe, file: ByteArray, uploads: MutableMap<String, ByteArray>) = thread(isDaemon = true) {
        val hello = Json.parseToJsonElement(String(pipe.receive()!!)).jsonObject
        val helloT = SessionCrypto.helloTranscript("rcAUFPmhXeQ", hello.str("from"), hello.str("epk"), hello.str("n"), hello["ts"]!!.jsonPrimitive.long)
        check(Primitives.verify(phoneKs.publicKey, helloT, hello.str("sig").unb64u()))
        val eph = P256.generate()
        val ephKey = JcaAgreementKey(eph.private, P256.raw(eph.public as ECPublicKey))
        val epk = ephKey.publicKey.b64u(); val n = randomBytes(16).b64u()
        val acceptT = SessionCrypto.acceptTranscript(helloT, epk, n)
        pipe.send("""{"t":"accept","epk":"$epk","n":"$n","sig":"${macKs.sign(acceptT).b64u()}"}""".toByteArray())
        val (p2m, m2p) = SessionCrypto.keys(ephKey.sharedSecret(hello.str("epk").unb64u()), acceptT)
        val tx = FrameCipher(m2p, 2); val rx = FrameCipher(p2m, 1)
        fun out(f: SessionFrame) = pipe.send(tx.seal(f.encode()))
        var upload: Pair<Control, ByteArrayOutputStream>? = null
        while (true) {
            val raw = pipe.receive() ?: break
            when (val f = SessionFrame.decode(rx.open(raw))) {
                is SessionFrame.Data -> upload!!.second.write(f.bytes)
                is SessionFrame.Ctl -> when (f.c.op) {
                    "list" -> out(SessionFrame.Ctl(Control("entries", f.c.id, path = f.c.path,
                        entries = listOf(FileEntry("Notes", true, 0, 0), FileEntry("big.bin", false, file.size.toLong(), 0)))))
                    "download" -> {
                        out(SessionFrame.Ctl(Control("meta", f.c.id, size = file.size.toLong(), mime = "application/octet-stream")))
                        file.toList().chunked(SessionCrypto.CHUNK).forEach { out(SessionFrame.Data(f.c.id, it.toByteArray())) }
                        out(SessionFrame.Ctl(Control("done", f.c.id, sha256 = MessageDigest.getInstance("SHA-256").digest(file).b64u())))
                    }
                    "upload" -> { upload = f.c to ByteArrayOutputStream(); out(SessionFrame.Ctl(Control("ready", f.c.id, name = f.c.name))) }
                    "done" -> {
                        val (c, buf) = upload!!
                        uploads[c.name!!] = buf.toByteArray()
                        out(SessionFrame.Ctl(Control("saved", c.id, name = c.name)))
                    }
                    "ack", "cancel" -> {}
                }
            }
        }
    }

    @Test fun listDownloadUploadRoundTrip() {
        val toMac = LinkedBlockingQueue<ByteArray>(); val toPhone = LinkedBlockingQueue<ByteArray>()
        val file = ByteArray(1_300_000) { (it * 31).toByte() }
        val uploads = java.util.concurrent.ConcurrentHashMap<String, ByteArray>()
        fakeMac(MemPipe(toMac, toPhone), file, uploads)
        val client = FileSessionClient.handshake(MemPipe(toPhone, toMac), phoneKs, "rcAUFPmhXeQ", macKs.publicKey)

        assertEquals(listOf("Notes", "big.bin"), client.list("").map { it.name })
        val out = ByteArrayOutputStream()
        client.download("big.bin", out)
        assertContentEquals(file, out.toByteArray())
        assertEquals("copy.bin", client.upload(ByteArrayInputStream(file), file.size.toLong(), "Notes", "copy.bin"))
        assertContentEquals(file, uploads["copy.bin"])
        client.close()
    }

    @Test fun wrongMacKeyIsRejected() {
        val toMac = LinkedBlockingQueue<ByteArray>(); val toPhone = LinkedBlockingQueue<ByteArray>()
        fakeMac(MemPipe(toMac, toPhone), ByteArray(1), mutableMapOf())
        val e = assertFailsWith<SessionException> {
            FileSessionClient.handshake(MemPipe(toPhone, toMac), phoneKs, "rcAUFPmhXeQ", phoneKs.publicKey)
        }
        assertEquals("untrusted", e.code)
    }
}
