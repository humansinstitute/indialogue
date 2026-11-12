package com.wingmanbefree.indialogue

import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.bouncycastle.crypto.engines.ChaCha7539Engine
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV

/**
 * NIP-44 v2 payload encryption. ChaCha20 (RFC 8439, counter 0) comes from BouncyCastle, HMAC-SHA256 from the
 * platform JCA, ECDH from libsecp256k1. Verified against the official paulmillr/nip44 vectors in unit tests.
 */
object Nip44 {
    private val SALT = "nip44-v2".toByteArray(Charsets.UTF_8)
    const val MIN_PLAINTEXT = 1
    const val EXTENDED_PREFIX_THRESHOLD = 65536

    /** Local policy: reading state never approaches this; refuses oversized inputs before decoding. */
    const val MAX_PLAINTEXT = 16 * 1024 * 1024

    class Nip44Exception(message: String) : Exception(message)

    fun conversationKey(secret: ByteArray, peerPubkeyHex: String): ByteArray =
        hmac(SALT, fr.acinq.secp256k1.Secp256k1.pubKeyCompress(fr.acinq.secp256k1.Secp256k1.pubKeyTweakMul(byteArrayOf(2) + peerPubkeyHex.unhex(), secret)).copyOfRange(1, 33))

    fun messageKeys(conversationKey: ByteArray, nonce: ByteArray): Triple<ByteArray, ByteArray, ByteArray> {
        if (conversationKey.size != 32) throw Nip44Exception("invalid conversation_key length")
        if (nonce.size != 32) throw Nip44Exception("invalid nonce length")
        val keys = hkdfExpand(conversationKey, nonce, 76)
        return Triple(keys.copyOfRange(0, 32), keys.copyOfRange(32, 44), keys.copyOfRange(44, 76))
    }

    fun calcPaddedLen(unpaddedLen: Long): Long {
        if (unpaddedLen <= 32) return 32
        val nextPower = 1L shl (floorLog2(unpaddedLen - 1) + 1)
        val chunk = if (nextPower <= 256) 32L else nextPower / 8
        return chunk * ((unpaddedLen - 1) / chunk + 1)
    }

    private fun floorLog2(v: Long): Int = 63 - java.lang.Long.numberOfLeadingZeros(v)

    fun pad(plaintext: String): ByteArray {
        val unpadded = plaintext.toByteArray(Charsets.UTF_8)
        val len = unpadded.size
        if (len < MIN_PLAINTEXT || len > MAX_PLAINTEXT) throw Nip44Exception("invalid plaintext length")
        val prefix = if (len >= EXTENDED_PREFIX_THRESHOLD) {
            byteArrayOf(0, 0, (len ushr 24).toByte(), (len ushr 16).toByte(), (len ushr 8).toByte(), len.toByte())
        } else {
            byteArrayOf((len ushr 8).toByte(), len.toByte())
        }
        val padded = ByteArray(prefix.size + calcPaddedLen(len.toLong()).toInt())
        System.arraycopy(prefix, 0, padded, 0, prefix.size)
        System.arraycopy(unpadded, 0, padded, prefix.size, len)
        return padded
    }

    fun unpad(padded: ByteArray): String {
        if (padded.size < 2) throw Nip44Exception("invalid padding")
        val firstTwo = ((padded[0].toInt() and 0xff) shl 8) or (padded[1].toInt() and 0xff)
        val len: Long
        val prefixLen: Int
        if (firstTwo == 0) {
            if (padded.size < 6) throw Nip44Exception("invalid padding")
            len = ((padded[2].toLong() and 0xff) shl 24) or ((padded[3].toLong() and 0xff) shl 16) or
                ((padded[4].toLong() and 0xff) shl 8) or (padded[5].toLong() and 0xff)
            if (len < EXTENDED_PREFIX_THRESHOLD) throw Nip44Exception("invalid padding")
            prefixLen = 6
        } else {
            len = firstTwo.toLong()
            prefixLen = 2
        }
        if (len == 0L || prefixLen + len > padded.size || padded.size.toLong() != prefixLen + calcPaddedLen(len)) {
            throw Nip44Exception("invalid padding")
        }
        val bytes = padded.copyOfRange(prefixLen, prefixLen + len.toInt())
        val decoder = Charsets.UTF_8.newDecoder()
        return try {
            decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        } catch (e: java.nio.charset.CharacterCodingException) {
            throw Nip44Exception("invalid utf-8")
        }
    }

    fun encrypt(plaintext: String, conversationKey: ByteArray, nonce: ByteArray = random(32)): String {
        val (chachaKey, chachaNonce, hmacKey) = messageKeys(conversationKey, nonce)
        val ciphertext = chacha20(chachaKey, chachaNonce, pad(plaintext))
        val mac = hmac(hmacKey, nonce + ciphertext)
        return Base64.getEncoder().encodeToString(byteArrayOf(2) + nonce + ciphertext + mac)
    }

    fun decrypt(payload: String, conversationKey: ByteArray): String {
        if (payload.isEmpty() || payload[0] == '#') throw Nip44Exception("unknown version")
        if (payload.length < 132 || payload.length > (MAX_PLAINTEXT / 3) * 4 + 256) throw Nip44Exception("invalid payload size")
        val data = try {
            Base64.getDecoder().decode(payload)
        } catch (e: IllegalArgumentException) {
            throw Nip44Exception("invalid base64")
        }
        if (data.size < 99) throw Nip44Exception("invalid data size")
        if (data[0].toInt() != 2) throw Nip44Exception("unknown version ${data[0]}")
        val nonce = data.copyOfRange(1, 33)
        val ciphertext = data.copyOfRange(33, data.size - 32)
        val mac = data.copyOfRange(data.size - 32, data.size)
        val (chachaKey, chachaNonce, hmacKey) = messageKeys(conversationKey, nonce)
        if (!java.security.MessageDigest.isEqual(hmac(hmacKey, nonce + ciphertext), mac)) throw Nip44Exception("invalid MAC")
        return unpad(chacha20(chachaKey, chachaNonce, ciphertext))
    }

    private fun chacha20(key: ByteArray, nonce: ByteArray, data: ByteArray): ByteArray {
        val engine = ChaCha7539Engine()
        engine.init(true, ParametersWithIV(KeyParameter(key), nonce))
        val out = ByteArray(data.size)
        engine.processBytes(data, 0, data.size, out, 0)
        return out
    }

    private fun hmac(key: ByteArray, message: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(message)
    }

    /** RFC 5869 HKDF-Expand with SHA-256. */
    private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        val out = ByteArray(length)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            previous = hmac(prk, previous + info + byteArrayOf(counter.toByte()))
            val n = minOf(previous.size, length - offset)
            System.arraycopy(previous, 0, out, offset, n)
            offset += n
            counter++
        }
        return out
    }
}
