package com.wingmanbefree.indialogue

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import fr.acinq.secp256k1.Secp256k1
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*

fun random(n: Int) = ByteArray(n).also { SecureRandom().nextBytes(it) }

object Bech32 {
    private const val alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    private fun polymod(values: List<Int>): Int {
        var chk = 1
        values.forEach { v ->
            val top = chk ushr 25
            chk = ((chk and 0x1ffffff) shl 5) xor v
            intArrayOf(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3).forEachIndexed {
                i,
                g ->
                if ((top ushr i) and 1 != 0) chk = chk xor g
            }
        }
        return chk
    }

    private fun expand(hrp: String) = hrp.map { it.code ushr 5 } + 0 + hrp.map { it.code and 31 }

    private fun convert(values: List<Int>, from: Int, to: Int, pad: Boolean): List<Int> {
        var acc = 0
        var bits = 0
        val out = mutableListOf<Int>()
        val mask = (1 shl to) - 1
        values.forEach {
            require(it ushr from == 0)
            acc = ((acc shl from) or it) and 0xffff
            bits += from
            while (bits >= to) {
                bits -= to
                out += (acc ushr bits) and mask
            }
        }
        if (pad && bits > 0) out += (acc shl (to - bits)) and mask
        if (!pad)
            require(bits < from && ((acc shl (to - bits)) and mask) == 0) {
                "Invalid Bech32 padding"
            }
        return out
    }

    fun encode(hrp: String, bytes: ByteArray): String {
        val words = convert(bytes.map { it.toInt() and 255 }, 8, 5, true)
        val p = polymod(expand(hrp) + words + List(6) { 0 }) xor 1
        return hrp +
            "1" +
            (words + List(6) { (p ushr (5 * (5 - it))) and 31 })
                .map { alphabet[it] }
                .joinToString("")
    }

    fun decode(value: String, hrp: String): ByteArray {
        require(
            value == value.lowercase() &&
                value.startsWith(hrp + "1") &&
                value.length == hrp.length + 59
        ) {
            "Invalid $hrp"
        }
        val words =
            value.drop(hrp.length + 1).map { alphabet.indexOf(it).also { n -> require(n >= 0) } }
        require(polymod(expand(hrp) + words) == 1) { "Invalid Bech32 checksum" }
        return convert(words.dropLast(6), 5, 8, false)
            .map { it.toByte() }
            .toByteArray()
            .also { require(it.size == 32) }
    }

    fun validPublic(value: String) = runCatching { decode(value, "npub") }.isSuccess

    fun secret(value: String) =
        decode(
                value
                    .trim()
                    .also {
                        require(it == it.lowercase() || it == it.uppercase()) {
                            "Mixed-case nsec is invalid."
                        }
                    }
                    .lowercase(),
                "nsec",
            )
            .also {
                require(Secp256k1.secKeyVerify(it)) { "Secret scalar outside secp256k1 range" }
            }
}

@Serializable
data class Envelope(val version: Int = 1, val salt: String, val iv: String, val sealed: String)

object VaultCrypto {
    fun pin(pin: String) {
        require(Regex("[0-9]{4,12}").matches(pin)) { "PIN must contain 4–12 digits." }
    }

    fun key(pin: String, install: ByteArray, salt: ByteArray): ByteArray {
        pin(pin)
        val chars = (pin + ":" + Base64.getEncoder().encodeToString(install)).toCharArray()
        val spec = PBEKeySpec(chars, salt, 210000, 256)
        return try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            chars.fill('\u0000')
            spec.clearPassword()
        }
    }

    fun seal(secret: ByteArray, pin: String, install: ByteArray): Envelope {
        val salt = random(16)
        val key = key(pin, install, salt)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        try {
            c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
            c.updateAAD("InDialogue-vault-1".toByteArray())
            return Envelope(salt = salt.hex(), iv = c.iv.hex(), sealed = c.doFinal(secret).hex())
        } finally {
            key.fill(0)
        }
    }

    fun open(e: Envelope, pin: String, install: ByteArray): ByteArray {
        require(e.version == 1 && e.salt.length == 32 && e.iv.length == 24)
        val key = key(pin, install, e.salt.unhex())
        try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(128, e.iv.unhex()),
            )
            c.updateAAD("InDialogue-vault-1".toByteArray())
            return c.doFinal(e.sealed.unhex()).also { require(Secp256k1.secKeyVerify(it)) }
        } finally {
            key.fill(0)
        }
    }
}

interface InstallationSecret {
    fun get(create: Boolean): ByteArray

    fun remove()
}

class KeystoreSecret(private val file: File) : InstallationSecret {
    private val alias = "InDialogue.installation.v1"

    private fun key(create: Boolean): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!ks.containsAlias(alias)) {
            check(create) { "Installation key unavailable; vault retained." }
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                .apply {
                    init(
                        KeyGenParameterSpec.Builder(
                                alias,
                                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                            )
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .setRandomizedEncryptionRequired(true)
                            .build()
                    )
                }
                .generateKey()
        }
        return ks.getKey(alias, null) as SecretKey
    }

    override fun get(create: Boolean): ByteArray {
        val k = key(create)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        if (!file.exists()) {
            check(create)
            val secret = random(32)
            c.init(Cipher.ENCRYPT_MODE, k)
            atomic(file, c.iv.hex() + ":" + c.doFinal(secret).hex())
            return secret
        }
        val parts = file.readText().split(':')
        require(parts.size == 2)
        c.init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(128, parts[0].unhex()))
        return c.doFinal(parts[1].unhex())
    }

    override fun remove() {
        if (file.exists()) check(file.delete())
        KeyStore.getInstance("AndroidKeyStore").apply {
            load(null)
            deleteEntry(alias)
        }
    }
}

class Identity(private val file: File, private val installation: InstallationSecret) {
    private var secret: ByteArray? = null
    val generation = kotlinx.coroutines.flow.MutableStateFlow(0L)
    val exists
        get() = file.exists()

    val unlocked
        get() = secret != null

    @Synchronized
    fun create(nsec: String, pin: String) {
        check(!exists) { "Remove existing identity explicitly first." }
        val s = Bech32.secret(nsec)
        try {
            val install = installation.get(true)
            try {
                atomic(file, codec.encodeToString(VaultCrypto.seal(s, pin, install)))
            } finally {
                install.fill(0)
            }
            secret = s.copyOf()
            generation.value++
        } finally {
            s.fill(0)
        }
    }

    @Synchronized
    fun unlock(pin: String) {
        val install = installation.get(false)
        try {
            val s = VaultCrypto.open(codec.decodeFromString(file.readText()), pin, install)
            lock()
            secret = s
            generation.value++
        } catch (_: Exception) {
            throw IllegalArgumentException(
                "Incorrect PIN or damaged vault. Existing identity retained."
            )
        } finally {
            install.fill(0)
        }
    }

    @Synchronized
    fun lock() {
        secret?.fill(0)
        secret = null
        generation.value++
    }

    @Synchronized
    fun remove() {
        lock()
        if (file.exists()) check(file.delete())
        installation.remove()
    }

    @Synchronized fun npub(): String = Bech32.encode("npub", publicKey())

    private fun publicKey() =
        Secp256k1.pubkeyCreate(checkNotNull(secret) { "Unlock identity first." }).copyOfRange(1, 33)

    @Synchronized
    fun sign(
        kind: Int,
        tags: List<List<String>>,
        content: String,
        timestamp: Long = System.currentTimeMillis() / 1000,
    ): JsonObject {
        val pub = publicKey().hex()
        val tagJson = JsonArray(tags.map { JsonArray(it.map(::JsonPrimitive)) })
        val serial = buildJsonArray {
            add(0)
            add(pub)
            add(timestamp)
            add(kind)
            add(tagJson)
            add(content)
        }
            .toString()
            .toByteArray()
        val id = sha(serial)
        val sig = Secp256k1.signSchnorr(id.unhex(), checkNotNull(secret), random(32)).hex()
        return buildJsonObject {
            put("id", id)
            put("pubkey", pub)
            put("created_at", timestamp)
            put("kind", kind)
            put("tags", tagJson)
            put("content", content)
            put("sig", sig)
        }
    }
}
