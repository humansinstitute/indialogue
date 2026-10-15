package com.wingmanbefree.indialogue

import fr.acinq.secp256k1.Secp256k1
import java.io.File
import java.nio.file.Files
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class MemoryInstallation : InstallationSecret {
    var value: ByteArray? = null

    override fun get(create: Boolean): ByteArray {
        if (value == null && create) value = random(32)
        return checkNotNull(value).copyOf()
    }

    override fun remove() {
        value = null
    }
}

class IdentityTest {
    @Test
    fun officialBip340VectorsAndInvalidSignatures() {
        val lines =
            javaClass.classLoader!!
                .getResourceAsStream("bip340.csv")!!
                .bufferedReader()
                .readLines()
                .drop(1)
        lines.forEach { line ->
            val c = line.split(',')
            val pub = c[2].unhex()
            val message = c[4].unhex()
            val signature = c[5].unhex()
            if (message.size != 32) {
                assertThrows(IllegalArgumentException::class.java) {
                    Secp256k1.verifySchnorr(signature, message, pub)
                }
                return@forEach
            }
            val expected = c[6] == "TRUE"
            assertEquals(
                "vector ${c[0]}",
                expected,
                runCatching { Secp256k1.verifySchnorr(signature, message, pub) }
                    .getOrDefault(false),
            )
            if (c[1].isNotBlank()) {
                assertEquals(
                    c[5].lowercase(),
                    Secp256k1.signSchnorr(message, c[1].unhex(), c[3].unhex()).hex(),
                )
            }
        }
    }

    @Test
    fun checksumPaddingScalarAndPinValidation() {
        val scalar = ByteArray(32).also { it[31] = 1 }
        val value = Bech32.encode("nsec", scalar)
        assertArrayEquals(scalar, Bech32.secret(value))
        assertArrayEquals(scalar, Bech32.secret(value.uppercase()))
        assertThrows(Exception::class.java) {
            Bech32.secret(value.dropLast(1) + if (value.last() == 'q') "p" else "q")
        }
        assertThrows(Exception::class.java) { Bech32.secret(Bech32.encode("nsec", ByteArray(32))) }
        assertThrows(Exception::class.java) {
            Bech32.secret(Bech32.encode("nsec", ByteArray(32) { 255.toByte() }))
        }
        for (pin in listOf("123", "1234567890123", "12a4", "１２３４")) assertThrows(
            Exception::class.java
        ) {
            VaultCrypto.pin(pin)
        }
    }

    @Test
    fun vaultWrongPinTamperColdStartAndMemoryUnlock() {
        val root = Files.createTempDirectory("vault-test").toFile()
        try {
            val file = File(root, "vault.json")
            val install = MemoryInstallation()
            val v = Identity(file, install)
            val scalar = ByteArray(32).also { it[31] = 1 }
            v.create(Bech32.encode("nsec", scalar), "123456")
            val original = file.readBytes()
            assertEquals(
                "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
                Bech32.decode(v.npub(), "npub").hex(),
            )
            val event = v.sign(1, listOf(listOf("t", "é / 😀")), "test", 1700000000)
            val pub = event.text("pubkey")!!
            val serial = buildJsonArray {
                add(0)
                add(pub)
                add(1700000000)
                add(1)
                add(event["tags"]!!)
                add("test")
            }
            assertEquals(sha(serial.toString().toByteArray()), event.text("id"))
            assertTrue(
                Secp256k1.verifySchnorr(
                    event.text("sig")!!.unhex(),
                    event.text("id")!!.unhex(),
                    pub.unhex(),
                )
            )
            v.lock()
            assertThrows(Exception::class.java) { v.npub() }
            assertThrows(Exception::class.java) { v.unlock("999999") }
            assertArrayEquals(original, file.readBytes())
            assertFalse(v.unlocked)
            v.unlock("123456")
            assertTrue(v.unlocked)
            val cold = Identity(file, install)
            assertFalse(cold.unlocked)
            cold.unlock("123456")
            assertThrows(Exception::class.java) {
                cold.create(Bech32.encode("nsec", scalar), "123456")
            }
            val damaged = file.readText().replaceFirst("sealed\":\"", "sealed\":\"00")
            file.writeText(damaged)
            val fresh = Identity(file, install)
            assertThrows(Exception::class.java) { fresh.unlock("123456") }
            assertTrue(file.exists())
            file.writeBytes(original)
            fresh.unlock("123456")
            fresh.remove()
            assertFalse(file.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun secureFieldsUsePasswordImeSemanticsAndDisableAutocorrect() {
        val secret = secureKeyboardOptions("Paste nsec", true)
        assertEquals(androidx.compose.ui.text.input.KeyboardType.Password, secret.keyboardType)
        assertEquals(false, secret.autoCorrectEnabled)
        val pin = secureKeyboardOptions("Confirm PIN", true)
        assertEquals(androidx.compose.ui.text.input.KeyboardType.NumberPassword, pin.keyboardType)
        assertEquals(false, pin.autoCorrectEnabled)
    }
}
