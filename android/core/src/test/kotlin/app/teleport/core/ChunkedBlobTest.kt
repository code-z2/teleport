package app.teleport.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

/** protocol/vectors.json "chunked" (SPEC.md "Large blobs"). */
class ChunkedBlobTest {
    private val c = Json.parseToJsonElement(File(System.getProperty("vectors")).readText()).jsonObject["chunked"]!!.jsonObject
    private fun JsonObject.s(k: String) = this[k]!!.jsonPrimitive.content
    private val key = c.s("key").unb64u()
    private val n = c.s("n").unb64u()
    private val chunk = c["c"]!!.jsonPrimitive.int

    @Test fun sealMatchesAndOpens() {
        for (v in c["cases"]!!.jsonArray.map { it.jsonObject }) {
            val plain = v.s("plaintext").unb64u()
            assertEquals(v.s("ciphertext"), ChunkedBlob.seal(plain, key, n, chunk).b64u(), v.s("name"))
            assertContentEquals(plain, ChunkedBlob.open(v.s("ciphertext").unb64u(), plain.size.toLong(), key, n, chunk), v.s("name"))
        }
    }

    @Test fun rejectsTruncationReorderingAndWrongSize() {
        val ct = c["cases"]!!.jsonArray[0].jsonObject.s("ciphertext").unb64u() // 25 bytes: 26 + 26 + 21
        assertFailsWith<OpenException> { ChunkedBlob.open(ct.copyOf(52), 20, key, n, chunk) }
        val swapped = ct.copyOfRange(26, 52) + ct.copyOfRange(0, 26) + ct.copyOfRange(52, ct.size)
        assertFailsWith<OpenException> { ChunkedBlob.open(swapped, 25, key, n, chunk) }
        assertFailsWith<OpenException> { ChunkedBlob.open(ct, 24, key, n, chunk) }
    }

    @Test fun pointerOmitsAbsentFields() {
        val small = BlobPointer("a", "image/png", 3, "k", "n")
        assertFalse(TeleportJson.encodeToString(BlobPointer.serializer(), small).contains("\"c\""))
        val big = TeleportJson.decodeFromString(BlobPointer.serializer(), """{"id":"a","mime":"video/mp4","size":9,"key":"k","n":"n","c":4194304,"name":"Clip.mp4"}""")
        assertEquals(4194304L, big.c)
        assertEquals("Clip.mp4", big.name)
    }
}
