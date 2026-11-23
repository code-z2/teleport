package app.teleport.core

/** Persistence the platform layer provides (SharedPreferences on Android). */
interface TeleportStore {
    /** Paired devices by `fp(ks)`. */
    var peers: Map<String, Peer>
    /** Devices we scanned, waiting for their `pair-ok` (expire after 10 minutes). */
    var pendingOutbound: Map<String, Peer>
    /** Devices that scanned us, waiting for Allow (expired ones filtered out). */
    var pairRequests: Map<String, PairRequest>
    var deviceName: String?
    var ownFcmToken: String?

    /** A fresh one-time QR secret, valid 10 minutes. */
    fun newPairingSecret(): ByteArray
    /** The current secret if still valid and unused. */
    fun currentPairingSecret(): ByteArray?
    fun markPairingSecretUsed()

    /** False if `id` was seen in the last 24 h; records it otherwise. */
    fun markSeen(id: String): Boolean
}

sealed interface Clip {
    data class Text(val text: String) : Clip
    class Bytes(val data: ByteArray, val mime: String) : Clip
}

sealed interface Received {
    data class ClipReceived(val clip: Clip, val id: String, val from: Peer) : Received
    data class BlobPending(val pointer: BlobPointer, val id: String, val from: Peer) : Received
    data class PeerUpdated(val peer: Peer) : Received
    /** Someone scanned our QR code; the user must Allow or Deny. */
    data class PairRequested(val request: PairRequest) : Received
    /** A device we scanned accepted. */
    data class Paired(val peer: Peer) : Received
    /** A device we scanned tapped Deny. */
    data class Declined(val peer: Peer) : Received
}

class NotPairedException : Exception("not paired")
class ChooseDeviceException : Exception("several devices are paired")
class TooLargeException : Exception("clip too large")
class InvalidCodeException : Exception("not a Teleport v2 pairing code")

/** High-level send/receive. All methods block — call from Dispatchers.IO. */
class Teleport(
    val agreement: AgreementKey,
    val signing: SigningKey,
    val store: TeleportStore,
    val relay: RelayClient,
    private val platform: String = "android",
) {
    companion object {
        /** Clips (text, images) up to this go as one sealed blob and land on the clipboard. */
        const val MAX_BLOB_BYTES = 10 * 1024 * 1024
        /** Files up to this go as chunked blobs (SPEC.md "Large blobs"). */
        const val MAX_FILE_BYTES = ChunkedBlob.MAX_SIZE
        private const val PAIR_WINDOW_MS = 10 * 60_000L
    }

    val myId: String get() = TeleportCrypto.fingerprint(signing.publicKey)

    fun sortedPeers(): List<Peer> = store.peers.values.sortedBy { it.pairedAt }

    /** The one device to send to when the caller didn't choose. */
    fun defaultPeer(): Peer {
        val peers = sortedPeers()
        if (peers.isEmpty()) throw NotPairedException()
        if (peers.size > 1) throw ChooseDeviceException()
        return peers[0]
    }

    // ---------- pairing (SPEC.md "v2 additions") ----------

    fun myCard(name: String) = PairingCard(
        name = name, platform = platform,
        ka = agreement.publicKey.b64u(), ks = signing.publicKey.b64u(), fcm = store.ownFcmToken,
    )

    /** Our QR code with a fresh one-time secret. */
    fun qrCode(name: String): String = myCard(name).copy(ps = store.newPairingSecret().b64u()).encoded()

    /** We scanned another device: send it a `pair` request; it becomes a peer when `pair-ok` arrives. */
    fun scan(code: String, name: String): Peer {
        val card = try { PairingCard.decode(code) } catch (e: OpenException) { throw InvalidCodeException() }
        val secret = card.ps?.unb64u() ?: throw InvalidCodeException()
        val peer = Peer.from(card).copy(pairedAt = System.currentTimeMillis())
        if (peer.id == myId) throw InvalidCodeException()

        val myJson = myCard(name).json()
        val body = TeleportCrypto.pairPlaintext(myJson, TeleportCrypto.pairProof(secret, myJson))
        relay.send(TeleportCrypto.seal(KIND_PAIR, body, signing, peer.kaBytes), peer)
        store.pendingOutbound = store.pendingOutbound + (peer.id to peer)
        return peer
    }

    /** The user tapped Allow: store the device and send `pair-ok`. */
    fun allow(requestId: String, name: String): Peer {
        val request = store.pairRequests[requestId] ?: throw OpenException("expired")
        val peer = Peer.from(lenientJson.decodeFromString(PairingCard.serializer(), request.cardJson))
        val body = myCard(name).json().toByteArray(Charsets.UTF_8)
        relay.send(TeleportCrypto.seal(KIND_PAIR_OK, body, signing, peer.kaBytes), peer)
        store.peers = store.peers + (peer.id to peer)
        store.pairRequests = store.pairRequests - requestId
        return peer
    }

    /** The user tapped Deny: forget the request and tell the device, so it stops waiting. Safe on any thread. */
    fun deny(requestId: String) {
        val request = store.pairRequests[requestId]
        store.pairRequests = store.pairRequests - requestId
        val peer = request?.let { runCatching { Peer.from(lenientJson.decodeFromString(PairingCard.serializer(), it.cardJson)) }.getOrNull() } ?: return
        kotlin.concurrent.thread(isDaemon = true) {
            runCatching { relay.send(TeleportCrypto.seal(KIND_PAIR_NO, "{}".toByteArray(), signing, peer.kaBytes), peer) }
        }
    }

    fun remove(peerId: String) {
        store.peers = store.peers - peerId
    }

    /** Tell every paired device our current name and push address. Returns how many failed. */
    fun announce(name: String): Int {
        val body = TeleportJson.encodeToString(PeerUpdate.serializer(), PeerUpdate(name = name, fcm = store.ownFcmToken))
            .toByteArray(Charsets.UTF_8)
        return store.peers.values.count { peer ->
            runCatching { relay.send(TeleportCrypto.seal(KIND_PEER, body, signing, peer.kaBytes), peer) }.isFailure
        }
    }

    // ---------- send ----------

    fun send(clip: Clip, to: Peer) {
        when (clip) {
            is Clip.Text -> {
                val bytes = clip.text.toByteArray(Charsets.UTF_8)
                val env = TeleportCrypto.seal(KIND_TEXT, bytes, signing, to.kaBytes)
                if (env.toJson().toByteArray().size <= Envelope.MAX_BYTES) relay.send(env, to)
                else sendBlob(bytes, "text/plain; charset=utf-8", to)
            }
            is Clip.Bytes -> sendBlob(clip.data, clip.mime, to)
        }
    }

    private fun sendBlob(bytes: ByteArray, mime: String, peer: Peer) {
        if (bytes.size + 16 > MAX_BLOB_BYTES) throw TooLargeException()
        val sealed = TeleportCrypto.sealBlob(bytes)
        val id = relay.putBlob(sealed.ciphertext)
        val pointer = BlobPointer(id, mime, bytes.size.toLong(), sealed.key.b64u(), sealed.nonce.b64u())
        val pt = TeleportJson.encodeToString(BlobPointer.serializer(), pointer).toByteArray()
        // Photos get an iPhone Live Activity (Copy / Save); long text stays a plain notification.
        relay.send(TeleportCrypto.seal(KIND_BLOB, pt, signing, peer.kaBytes), peer, hint = if (mime.startsWith("image/")) "image" else null)
    }

    // ---------- receive ----------

    /** Android receives each push exactly once in the FCM service, so replay is always enforced. */
    fun receive(envJson: String): Received {
        val env = Envelope.parse(envJson)

        if (env.k == KIND_PAIR) {
            val secret = store.currentPairingSecret() ?: throw OpenException("proof")
            val opened = TeleportCrypto.openPair(env, agreement, secret)
            if (!store.markSeen(env.id)) throw OpenException("replay")
            store.markPairingSecretUsed()
            val request = PairRequest(
                id = env.from, cardJson = opened.json, name = opened.card.name,
                platform = opened.card.platform, expires = System.currentTimeMillis() + PAIR_WINDOW_MS,
            )
            store.pairRequests = store.pairRequests + (request.id to request)
            return Received.PairRequested(request)
        }

        // Everything else must come from a paired device (or, for pair-ok, one we scanned).
        val known = store.peers[env.from]
        val pending = if (env.k == KIND_PAIR_OK || env.k == KIND_PAIR_NO) store.pendingOutbound[env.from] else null
        val peer = known ?: pending ?: throw OpenException("peer")
        val pt = TeleportCrypto.open(env, agreement, peer.ksBytes)
        if (!store.markSeen(env.id)) throw OpenException("replay")

        return when (env.k) {
            KIND_TEXT -> Received.ClipReceived(Clip.Text(String(pt, Charsets.UTF_8)), env.id, peer)
            // Verified and decrypted, but the content still has to be downloaded:
            // the caller calls fetchBlob(), and can retry it later if the network is blocked.
            KIND_BLOB -> Received.BlobPending(TeleportJson.decodeFromString(BlobPointer.serializer(), String(pt)), env.id, peer)
            KIND_PEER -> {
                if (known == null) throw OpenException("kind")
                val u = lenientJson.decodeFromString(PeerUpdate.serializer(), String(pt))
                val updated = peer.copy(
                    name = u.name ?: peer.name, fcm = u.fcm ?: peer.fcm,
                    la = u.la ?: peer.la, mailbox = u.mailbox ?: peer.mailbox,
                )
                store.peers = store.peers + (updated.id to updated)
                Received.PeerUpdated(updated)
            }
            KIND_PAIR_OK -> {
                if (pending == null) throw OpenException("kind")
                // Their card carries their current name and push address; keys must not change.
                val card = lenientJson.decodeFromString(PairingCard.serializer(), String(pt, Charsets.UTF_8))
                val confirmed = Peer.from(card)
                if (confirmed.id != peer.id || confirmed.ka != peer.ka) throw OpenException("peer")
                store.peers = store.peers + (confirmed.id to confirmed)
                store.pendingOutbound = store.pendingOutbound - confirmed.id
                Received.Paired(confirmed)
            }
            KIND_PAIR_NO -> {
                if (pending == null || known != null) throw OpenException("kind")
                store.pendingOutbound = store.pendingOutbound - pending.id
                Received.Declined(pending)
            }
            else -> throw OpenException("kind")
        }
    }

    /**
     * Sends a file of up to 250 MB as a chunked blob, streaming from [input]: read, sealed and
     * uploaded 16 MiB at a time. Blocking; call from Dispatchers.IO.
     */
    fun sendFile(
        input: java.io.InputStream, size: Long, mime: String, name: String?, to: Peer,
        cancelled: () -> Boolean = { false }, progress: (sent: Long, total: Long) -> Unit = { _, _ -> },
    ) {
        if (size > MAX_FILE_BYTES) throw TooLargeException()
        val key = randomBytes(32)
        val n = randomBytes(12)
        val chunks = ChunkedBlob.count(size)
        val total = size + 16L * chunks
        val upload = relay.startUpload()
        try {
            val pending = java.io.ByteArrayOutputStream(ChunkedBlob.PART + ChunkedBlob.CHUNK + 64)
            val etags = mutableListOf<String>()
            var sent = 0L
            progress(0, total)
            fun flush(bytes: ByteArray) {
                etags += relay.uploadPart(upload, etags.size + 1, bytes)
                sent += bytes.size
                progress(sent, total)
            }
            val buf = ByteArray(ChunkedBlob.CHUNK)
            for (i in 0 until chunks) {
                if (cancelled()) throw java.util.concurrent.CancellationException()
                // Exactly the bytes the pointer will declare: a stream shorter or longer than
                // [size] would arrive as a file the recipient can't open, so fail here instead.
                val want = if (i == chunks - 1) (size - i.toLong() * ChunkedBlob.CHUNK).toInt() else ChunkedBlob.CHUNK
                val read = input.readNBytes(buf, 0, want)
                if (read != want) throw java.io.IOException("The file is shorter than its stated size.")
                pending.write(ChunkedBlob.seal(buf.copyOf(read), i, i == chunks - 1, key, n))
                // Equal-sized parts (R2 requires it); the remainder goes last.
                while (pending.size() >= ChunkedBlob.PART) {
                    val all = pending.toByteArray()
                    flush(all.copyOfRange(0, ChunkedBlob.PART))
                    pending.reset()
                    pending.write(all, ChunkedBlob.PART, all.size - ChunkedBlob.PART)
                }
            }
            if (input.read() != -1) throw java.io.IOException("The file is longer than its stated size.")
            if (pending.size() > 0 || etags.isEmpty()) flush(pending.toByteArray())
            relay.completeUpload(upload, etags)
        } catch (e: Exception) {
            relay.abortUpload(upload)
            throw e
        }
        val pointer = BlobPointer(upload.id, mime, size, key.b64u(), n.b64u(), c = ChunkedBlob.CHUNK.toLong(), name = name)
        val pt = TeleportJson.encodeToString(BlobPointer.serializer(), pointer).toByteArray()
        relay.send(TeleportCrypto.seal(KIND_BLOB, pt, signing, to.kaBytes), to, hint = "file")
    }

    /**
     * Downloads a chunked blob into [scratch] (ciphertext, deleted afterwards), then decrypts it
     * into [out] a chunk at a time, and deletes it from the relay. Blocking.
     */
    fun downloadFile(
        p: BlobPointer, out: java.io.OutputStream, scratch: java.io.File,
        cancelled: () -> Boolean = { false }, progress: (done: Long, total: Long) -> Unit = { _, _ -> },
    ) {
        val chunk = p.c?.takeIf { it > 0 } ?: throw OpenException("encoding")
        if (p.size > MAX_FILE_BYTES) throw OpenException("encoding")
        val key = p.key.unb64u()
        val n = p.n.unb64u()
        try {
            scratch.outputStream().use { relay.downloadBlob(p.id, it, cancelled, progress) }
            val chunks = ChunkedBlob.count(p.size, chunk)
            if (scratch.length() != p.size + 16L * chunks) throw OpenException("decrypt")
            scratch.inputStream().use { input ->
                for (i in 0 until chunks) {
                    val plain = if (i == chunks - 1) (p.size - i * chunk).toInt() else chunk.toInt()
                    val sealed = input.readNBytes(plain + 16)
                    if (sealed.size != plain + 16) throw OpenException("decrypt")
                    out.write(ChunkedBlob.open(sealed, i, i == chunks - 1, key, n))
                }
            }
        } finally {
            scratch.delete()
        }
        runCatching { relay.deleteBlob(p.id) }
    }

    /** Downloads and decrypts a blob, then deletes it from the relay. Throws IOException on network failure. */
    fun fetchBlob(p: BlobPointer): Clip {
        val bytes = TeleportCrypto.openBlob(relay.getBlob(p.id), p.key.unb64u(), p.n.unb64u())
        runCatching { relay.deleteBlob(p.id) }
        return if (p.mime.startsWith("text/")) Clip.Text(String(bytes, Charsets.UTF_8)) else Clip.Bytes(bytes, p.mime)
    }
}
