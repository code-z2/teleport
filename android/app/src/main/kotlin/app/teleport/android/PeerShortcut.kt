package app.teleport.android

import android.content.Context
import android.content.Intent
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import app.teleport.core.Peer

/**
 * Publishes the paired device as a Direct Share target, so it appears in the share
 * sheet's top row like a chat contact. Android ranks these by use, so every send
 * pushes the shortcut again.
 */
object PeerShortcut {
    private const val ID = "peer"
    private const val CATEGORY = "app.teleport.android.category.SEND_TO_PEER"

    fun publish(context: Context, peer: Peer) {
        val person = Person.Builder()
            .setName(peer.name)
            .setKey(peer.ks.take(16))
            .setImportant(true)
            .build()
        val shortcut = ShortcutInfoCompat.Builder(context, ID)
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
}
