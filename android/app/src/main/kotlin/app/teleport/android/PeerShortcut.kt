package app.teleport.android

import android.content.Context
import android.content.Intent
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import app.teleport.core.Peer

/**
 * Publishes each paired device as a Direct Share target under its exact name, so it appears
 * in the share sheet's top row like a chat contact. The shortcut id is the device's
 * fingerprint, which ShareActivity reads back. Android ranks these by use, so every send
 * pushes the shortcut again.
 */
object PeerShortcut {
    private const val CATEGORY = "app.teleport.android.category.SEND_TO_PEER"

    fun publish(context: Context, peer: Peer) {
        val person = Person.Builder()
            .setName(peer.name)
            .setKey(peer.id)
            .setImportant(true)
            .build()
        val shortcut = ShortcutInfoCompat.Builder(context, peer.id)
            .setShortLabel(peer.name)
            .setLongLabel("Teleport to ${peer.name}")
            .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
            .setIntent(Intent(Intent.ACTION_DEFAULT).setClass(context, MainActivity::class.java))
            .setLongLived(true)
            .setPerson(person)
            .setCategories(setOf(CATEGORY))
            .build()
        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
    }

    /** Re-publish every paired device and drop shortcuts for removed ones. */
    fun sync(context: Context) {
        val peers = TeleportApp.of(context).teleport.store.peers
        val stale = ShortcutManagerCompat.getDynamicShortcuts(context).map { it.id }.filter { it !in peers }
        if (stale.isNotEmpty()) ShortcutManagerCompat.removeLongLivedShortcuts(context, stale)
        peers.values.forEach { publish(context, it) }
    }
}
