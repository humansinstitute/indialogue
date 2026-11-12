package com.wingmanbefree.indialogue

import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class TowerDiscoveryTest {
    private fun identity(): Identity = Identity(Files.createTempDirectory("discovery").resolve("vault").toFile(),MemoryInstallation()).also { it.create(Bech32.encode("nsec",ByteArray(32).also { b -> b[31]=3 }),"123456") }
    private val appPub = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    private val npub get() = Bech32.encode("npub",appPub.unhex())
    private fun locator(origin: String = "https://a.example", workspace: String = "11111111-1111-4111-8111-111111111111", nested: Boolean = false): JsonObject {
        val i=buildJsonObject { put("tower_service_npub",npub);put("workspace_service_npub",npub);put("workspace_owner_npub",npub);put("app_npub",npub);put("workspace_id",workspace) }
        return buildJsonObject { put("type","wingman_workspace_locator");put("version",1);put("tower_base_url",origin);put("label","Synthetic");if(nested) put("identity",i) else i.forEach { (k,v)-> put(k,v) } }
    }
    private fun event(identity: Identity, w: JsonObject, time: Long = 100, deleted: Boolean = false, invalid: Boolean = false): JsonObject {
        val pub=Bech32.decode(identity.npub(),"npub").hex();val space=WorkspaceLocator.parse(w)
        val payload=buildJsonObject { put("type","flightdeck_workspace_self_index");put("version",1);put("user_npub",identity.npub());put("workspace",w);put("app",buildJsonObject { put("namespace","flightdeck_pg");put("app_pubkey",appPub);put("app_npub",npub) });put("state",buildJsonObject { put("deleted",deleted) }) }
        return identity.sign(33356,listOf(listOf("d","fd-self:"+sha("v1:$pub:$appPub:${space.tower}:${space.workspace}".toByteArray())),listOf("p",pub),listOf("app_pub",appPub),listOf("protocol","workspace-self-index"),listOf("v","1")),if(invalid) "unreadable" else payload.toString(),time)
    }
    @Test fun sharedNostrToolsEncryptedFixtureInteroperatesAcrossApps() {
        val fixture=codec.parseToJsonElement(javaClass.classLoader!!.getResourceAsStream("workspace-self-index-v1.json")!!.bufferedReader().readText()).jsonObject
        val pub=fixture.text("user_pubkey")!!;val events=fixture["events"]!!.jsonArray.map { it.jsonObject }
        val secret=ByteArray(32).also { it[31]=1 };val key=Nip44.conversationKey(secret,pub)
        val decrypt:(String)->String={Nip44.decrypt(it,key)}
        assertEquals(setOf("https://one.example","https://two.example"),SelfIndexes.candidates(events.take(2),pub,decrypt).map { it.origin }.toSet())
        assertEquals(listOf("https://two.example"),SelfIndexes.candidates(events,pub,decrypt).map { it.origin })
    }
    @Test fun revokedCandidateDoesNotHideAnotherTower(): Unit = runBlocking {
        val fixture=codec.parseToJsonElement(javaClass.classLoader!!.getResourceAsStream("workspace-self-index-v1.json")!!.bufferedReader().readText()).jsonObject
        val events=fixture["events"]!!.jsonArray.take(2).map { it.jsonObject }
        val identity=Identity(Files.createTempDirectory("discovery-authority").resolve("vault").toFile(),MemoryInstallation()).also { it.create(Bech32.encode("nsec",ByteArray(32).also { b->b[31]=1 }),"123456") }
        val visited=mutableListOf<String>()
        val discovery=TowerDiscovery(identity,query={_,_->events},verifyCandidate={ w -> visited+=w.origin;check(w.origin == "https://two.example") { "Membership revoked" } })
        assertEquals(listOf("https://two.example"),discovery.discover().map { it.origin })
        assertEquals(setOf("https://one.example","https://two.example"),visited.toSet())
    }
    @Test fun crossAppFlatNestedTowersAndTombstones() {
        val id=identity();val pub=Bech32.decode(id.npub(),"npub").hex()
        assertFalse(SelfIndexes.filter(pub).containsKey("#app_pub"))
        val a=event(id,locator());val b=event(id,locator("https://b.example","22222222-2222-4222-8222-222222222222",true))
        assertEquals(setOf("https://a.example","https://b.example"),SelfIndexes.candidates(listOf(a,b),pub,{it},100).map { it.origin }.toSet())
        val tomb=event(id,locator(),101,true)
        assertEquals(listOf("https://b.example"),SelfIndexes.candidates(listOf(a,b,tomb),pub,{it},101).map { it.origin })
        assertTrue(SelfIndexes.candidates(listOf(a,event(id,locator(),102,invalid=true)),pub,{it},102).isEmpty())
        val malformed=id.sign(33356,a["tags"]!!.jsonArray.map { it.jsonArray.map { x -> x.jsonPrimitive.content } }+listOf(listOf("p",pub)),a.text("content")!!,103)
        assertTrue(SelfIndexes.candidates(listOf(a,malformed),pub,{it},103).isEmpty())
        val tampered=JsonObject(b + ("sig" to JsonPrimitive("0".repeat(128))))
        assertEquals(1,SelfIndexes.candidates(listOf(a,tampered),pub,{it},100).size)
        assertTrue(SelfIndexes.candidates(listOf(a),"0".repeat(64),{it},100).isEmpty())
    }
    @Test fun publicationNamespaceIsValidPublicPointAndEncryptedIndexRoundTrips() {
        fr.acinq.secp256k1.Secp256k1.pubkeyParse(byteArrayOf(2)+SelfIndexes.APP_PUB.unhex())
        assertEquals(SelfIndexes.APP_PUB,sha("org.wingman.nstack.app:com.wingmanbefree.indialogue:v1:0".toByteArray()))
        val id=identity();val w=WorkspaceLocator.parse(locator());val event=SelfIndexes.event(id,w)
        assertEquals(listOf(w),SelfIndexes.candidates(listOf(event),event.text("pubkey")!!,id::decryptSelf))
        assertEquals(setOf("d","p","app_pub","protocol","v"),event["tags"]!!.jsonArray.map { it.jsonArray.first().jsonPrimitive.content }.toSet())
        assertFalse(event["tags"].toString().contains("a.example"))
    }
    @Test fun nip44RoundTripTamperAndWrongIdentity() {
        val secret=ByteArray(32).also { it[31]=3 };val pub=fr.acinq.secp256k1.Secp256k1.pubkeyCreate(secret).copyOfRange(1,33).hex()
        val key=Nip44.conversationKey(secret,pub)
        assertEquals("fc5e31fe0006369674bb81fb7aab0a54241d5ac42f631399d51a8ed0f888c300",key.hex())
        assertEquals("Synthetic cross-app locator",Nip44.decrypt("AgEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBFRTaG/tNVtJqu3n1o59bKaoZeCDxr+DxvowrTDBpWKpPkcpAGQ3r1JTe7MCBqcyfY8pfDPBZ+uT9O7Vp/p8lj1/L",key))
        val encrypted=Nip44.encrypt("cross-app locator",key,ByteArray(32){1})
        assertEquals("cross-app locator",Nip44.decrypt(encrypted,key))
        assertThrows(Exception::class.java) { Nip44.decrypt(encrypted,ByteArray(32)) }
        assertThrows(Exception::class.java) { Nip44.decrypt(encrypted.dropLast(4)+"AAAA",key) }
    }
    @Test fun explicitTowerChoiceListsOnlySelectedTowerAndPreservesSavedRoute(): Unit = runBlocking {
        val auth=AuthContext(npub,1);val a=TowerChoice("https://a.example",npub);val b=TowerChoice("https://b.example",npub)
        val listed=mutableListOf<String>();val route=Destination(a.origin,npub,"11111111-1111-4111-8111-111111111111","Old",npub,"33333333-3333-4333-8333-333333333333","Channel","Review")
        val setup=NStackSetup(this,{auth},{ origin,_ -> listed += origin; listOf(WorkspaceLocator.parse(locator(origin)).choice()) },{_,_,_->NStackAPI.Discovery(emptyList(),emptyList(),"",false)},route,loadTowers={listOf(a,b)})
        setup.discoverTowers();yield()
        assertEquals(listOf(a,b),setup.state.value.towers);assertEquals(route.origin,setup.state.value.origin);assertEquals(route.workspace,setup.state.value.workspace?.id)
        assertTrue(listed.isEmpty());setup.selectTower(b);yield()
        assertEquals(listOf(b.origin),listed);assertNull(setup.state.value.workspace);assertNull(setup.state.value.channel)
        assertEquals(a.origin,route.origin)
    }
}
