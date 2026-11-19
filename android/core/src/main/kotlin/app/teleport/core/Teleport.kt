package app.teleport.core

/** Persistence the platform layer provides (SharedPreferences on Android). */
interface TeleportStore {
    var peer: Peer?
    var ownFcmToken: String?
    /** False if `id` was seen in the last 24 h; records it otherwise. */
    fun markSeen(id: String): Boolean
}

sealed interface Clip {
    data class Text(val text: String) : Clip
    class Bytes(val data: ByteArray, val mime: String) : Clip
}

sealed interface Received {
    data class ClipReceived(val clip: Clip, val id: String) : Received
    data class BlobPending(val pointer: BlobPointer, val id: String) : Received
    data class PeerUpdated(val peer: Peer) : Received
}

class NotPairedException : Exception("not paired")
class TooLargeException : Exception("clip too large")

/** High-level send/receive. All methods block — call from Dispatchers.IO. */
class Teleport(
    val agreement: AgreementKey,
    val signing: SigningKey,
    val store: TeleportStore,
    val relay: RelayClient,
) {
    companion object {
        const val MAX_BLOB_BYTES = 10 * 1024 * 1024
    }

    private fun peer() = store.peer ?: throw NotPairedException()

    fun myCard(name: String): PairingCard =
        PairingCard(name = name, platform = "android", ka = agreement.publicKey.b64u(), ks = signing.publicKey.b64u(), fcm = store.ownFcmToken ?: "")

    fun pair(encoded: String): Peer = Peer.from(PairingCard.decode(encoded)).also { store.peer = it }

    fun announceToken(name: String) {
        val peer = store.peer ?: return
        val fcm = store.ownFcmToken ?: return
        val body = TeleportJson.encodeToString(PeerUpdate.serializer(), PeerUpdate(fcm = fcm, name = name))
        relay.send(TeleportCrypto.seal(KIND_PEER, body.toByteArray(), signing, peer.kaBytes), peer)
    }

    fun send(clip: Clip) {
        val peer = peer()
        when (clip) {
            is Clip.Text -> {
                val bytes = clip.text.toByteArray(Charsets.UTF_8)
                val env = TeleportCrypto.seal(KIND_TEXT, bytes, signing, peer.kaBytes)
                if (env.toJson().toByteArray().size <= Envelope.MAX_BYTES) relay.send(env, peer)
                else sendBlob(bytes, "text/plain; charset=utf-8", peer)
            }
            is Clip.Bytes -> sendBlob(clip.data, clip.mime, peer)
        }
    }

    private fun sendBlob(bytes: ByteArray, mime: String, peer: Peer) {
        if (bytes.size + 16 > MAX_BLOB_BYTES) throw TooLargeException()
        val sealed = TeleportCrypto.sealBlob(bytes)
        val id = relay.putBlob(sealed.ciphertext)
        val pointer = BlobPointer(id, mime, bytes.size.toLong(), sealed.key.b64u(), sealed.nonce.b64u())
        val pt = TeleportJson.encodeToString(BlobPointer.serializer(), pointer).toByteArray()
        relay.send(TeleportCrypto.seal(KIND_BLOB, pt, signing, peer.kaBytes), peer)
    }

    /** Android receives each push exactly once in the FCM service, so replay is always enforced. */
    fun receive(envJson: String): Received {
        val env = Envelope.parse(envJson)
        var peer = peer()
        val pt = TeleportCrypto.open(env, agreement, peer.ksBytes)
        if (!store.markSeen(env.id)) throw OpenException("replay")
        return when (env.k) {
            KIND_TEXT -> Received.ClipReceived(Clip.Text(String(pt, Charsets.UTF_8)), env.id)
            // Verified and decrypted, but the content still has to be downloaded:
            // the caller calls fetchBlob(), and can retry it later if the network is blocked.
            KIND_BLOB -> Received.BlobPending(TeleportJson.decodeFromString(BlobPointer.serializer(), String(pt)), env.id)
            else -> {
                val u = TeleportJson.decodeFromString(PeerUpdate.serializer(), String(pt))
                peer = peer.copy(fcm = u.fcm, la = u.la, name = u.name ?: peer.name)
                store.peer = peer
                Received.PeerUpdated(peer)
            }
        }
    }

    /** Downloads and decrypts a blob, then deletes it from the relay. Throws IOException on network failure. */
    fun fetchBlob(p: BlobPointer): Clip {
        val bytes = TeleportCrypto.openBlob(relay.getBlob(p.id), p.key.unb64u(), p.n.unb64u())
        runCatching { relay.deleteBlob(p.id) }
        return if (p.mime.startsWith("text/")) Clip.Text(String(bytes, Charsets.UTF_8)) else Clip.Bytes(bytes, p.mime)
    }
}
