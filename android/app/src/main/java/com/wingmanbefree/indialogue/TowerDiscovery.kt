package com.wingmanbefree.indialogue

import fr.acinq.secp256k1.Secp256k1
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Public locator hints. Only a fresh authenticated /me response makes a candidate usable. */
data class WorkspaceLocator(val origin: String, val identity: JsonObject, val label: String) {
    val workspace get() = identity.text("workspace_id")!!
    val app get() = identity.text("app_npub")!!
    val tower get() = identity.text("tower_service_npub")!!
    fun choice() = Choice(workspace, label, app, this)
    companion object {
        val keys = listOf("tower_service_npub", "workspace_service_npub", "workspace_owner_npub", "workspace_id", "app_npub")
        fun parse(value: JsonObject): WorkspaceLocator {
            require(value.text("type") == "wingman_workspace_locator" && value["version"] == JsonPrimitive(1))
            val i = value["identity"] as? JsonObject ?: value
            keys.filter { it != "workspace_id" }.forEach { require(Bech32.validPublic(i.text(it).orEmpty())) }
            val id = i.text("workspace_id")!!
            require(UUID.fromString(id).toString() == id.lowercase())
            return WorkspaceLocator(NStackAPI.origin(value.text("tower_base_url")!!), JsonObject(keys.associateWith { i[it]!! }), value.text("label") ?: "Workspace")
        }
    }
}
data class TowerChoice(val origin: String, val service: String)

object SelfIndexes {
    const val APP_PUB = "166f8d10ed9d5480a05066fd23b0ce8c4b4807d0b43bc424648f9dc00bef114f"
    val APP_NPUB get() = Bech32.encode("npub",APP_PUB.unhex())
    fun event(identity: Identity, w: WorkspaceLocator): JsonObject {
        val pub = Bech32.decode(identity.npub(),"npub").hex()
        val now = java.time.Instant.now().toString()
        val payload = buildJsonObject {
            put("type","flightdeck_workspace_self_index");put("version",1);put("user_npub",identity.npub());put("issued_at",now);put("updated_at",now)
            put("app",buildJsonObject { put("app_npub",APP_NPUB);put("app_pubkey",APP_PUB);put("namespace","flightdeck_pg") })
            put("workspace",buildJsonObject { put("type","wingman_workspace_locator");put("version",1);put("tower_base_url",w.origin);put("label",w.label);w.identity.forEach { (k,v)->put(k,v) } })
            put("state",buildJsonObject { put("deleted",false) })
        }
        return identity.sign(33356,listOf(listOf("d","fd-self:"+sha("v1:$pub:$APP_PUB:${w.tower}:${w.workspace}".toByteArray())),listOf("p",pub),listOf("app_pub",APP_PUB),listOf("protocol","workspace-self-index"),listOf("v","1")),identity.encryptSelf(payload.toString()))
    }
    fun filter(pub: String) = buildJsonObject {
        put("kinds", JsonArray(listOf(JsonPrimitive(33356)))); put("authors", JsonArray(listOf(JsonPrimitive(pub))))
        put("#p", JsonArray(listOf(JsonPrimitive(pub)))); put("limit", 1000)
    }
    private fun tag(e: JsonObject, name: String): String {
        val tags = e["tags"]!!.jsonArray.map { it.jsonArray.map { x -> x.jsonPrimitive.content } }.filter { it.firstOrNull() == name }
        require(tags.size == 1 && tags[0].size == 2)
        return tags[0][1]
    }
    fun authentic(e: JsonObject, pub: String, now: Long): Boolean = runCatching {
        require(e.text("pubkey") == pub && e["kind"] == JsonPrimitive(33356))
        val time = e["created_at"]!!.jsonPrimitive.long
        require(time >= 0 && time <= now + 300)
        tag(e,"d")
        val bytes = buildJsonArray { add(0); add(pub); add(time); add(33356); add(e["tags"]!!); add(e.text("content")!!) }.toString().toByteArray()
        require(sha(bytes) == e.text("id"))
        Secp256k1.verifySchnorr(e.text("sig")!!.unhex(), sha(bytes).unhex(), pub.unhex())
    }.getOrDefault(false)
    fun valid(e: JsonObject, pub: String, now: Long): Boolean = authentic(e,pub,now) && runCatching {
        tag(e,"p") == pub && tag(e,"protocol") == "workspace-self-index" && tag(e,"v") == "1" && Regex("[0-9a-f]{64}").matches(tag(e,"app_pub"))
    }.getOrDefault(false)
    fun candidates(events: List<JsonObject>, pub: String, decrypt: (String) -> String, now: Long = System.currentTimeMillis()/1000): List<WorkspaceLocator> {
        // Reduce signed addresses before decryption: an unreadable replacement must not resurrect an old locator.
        return events.filter { authentic(it,pub,now) }.sortedWith(compareByDescending<JsonObject> { it["created_at"]!!.jsonPrimitive.long }.thenBy { it.text("id") })
            .distinctBy { tag(it,"d") }.mapNotNull { e -> runCatching {
                require(valid(e,pub,now))
                val p = codec.parseToJsonElement(decrypt(e.text("content")!!)).jsonObject
                require(p.text("type") == "flightdeck_workspace_self_index" && p["version"] == JsonPrimitive(1) && p.text("user_npub") == Bech32.encode("npub", pub.unhex()))
                val app = p["app"]!!.jsonObject
                require(app.text("namespace") == "flightdeck_pg" && app.text("app_pubkey") == tag(e,"app_pub") && app.text("app_npub") == Bech32.encode("npub", tag(e,"app_pub").unhex()))
                val w = WorkspaceLocator.parse(p["workspace"]!!.jsonObject)
                require(tag(e,"d") == "fd-self:" + sha("v1:$pub:${tag(e,"app_pub")}:${w.tower}:${w.workspace}".toByteArray()))
                require(p["state"]!!.jsonObject["deleted"] == JsonPrimitive(false))
                w
            }.getOrNull() }.distinctBy { it.origin to it.workspace }
    }
}

class TowerDiscovery(private val identity: Identity, private val gate: () -> Unit = {}, private val query: suspend (String, JsonObject) -> List<JsonObject> = { relay, filter -> RelayIndexQuery.query(relay,filter) }, private val verifyCandidate: (suspend (WorkspaceLocator) -> Unit)? = null) {
    suspend fun publish(w: WorkspaceLocator) {
        gate(); NStackAPI(identity,gate).verify(w); val e = SelfIndexes.event(identity,w)
        for (relay in listOf("wss://relay.primal.net","wss://relay.damus.io")) {
            try { RelayIndexQuery.publish(relay,e); val read=query(relay,buildJsonObject { put("ids",JsonArray(listOf(JsonPrimitive(e.text("id")!!))));put("limit",1) });
                check(read.any { it == e });check(SelfIndexes.candidates(read,e.text("pubkey")!!,identity::decryptSelf).contains(w));gate();return
            } catch (e:CancellationException) { throw e } catch (_:Exception) { }
        };error("Connected. Workspace announcement pending; retry publication.")
    }
    suspend fun discover(): List<TowerChoice> {
        gate()
        val pub = Bech32.decode(identity.npub(), "npub").hex()
        val events = mutableListOf<JsonObject>(); var success = false
        for (relay in listOf("wss://relay.primal.net", "wss://relay.damus.io")) {
            try { val rows = query(relay,SelfIndexes.filter(pub)); require(rows.size < 1000); events += rows; success = true }
            catch (e: CancellationException) { throw e } catch (_: Exception) { }
        }
        check(success) { "Tower discovery failed. Retry or enter an HTTPS Tower manually." }
        gate()
        val candidates = SelfIndexes.candidates(events,pub,identity::decryptSelf)
        check(candidates.size <= 100) { "Too many discovery candidates." }
        val api = NStackAPI(identity,gate)
        val verified = mutableListOf<TowerChoice>()
        for (w in candidates) {
            try { if (verifyCandidate == null) api.verify(w) else verifyCandidate.invoke(w); verified += TowerChoice(w.origin,w.tower) }
            catch (e: CancellationException) { throw e } catch (_: Exception) { }
        }
        gate()
        return verified.distinct()
    }
}

object RelayIndexQuery {
    suspend fun publish(relay: String, event: JsonObject) = withTimeout(20000) {
        val result=CompletableDeferred<Unit>();val client=OkHttpClient()
        val socket=client.newWebSocket(Request.Builder().url(relay).build(),object:WebSocketListener() {
            override fun onOpen(ws:WebSocket,response:Response) { ws.send(buildJsonArray { add("EVENT");add(event) }.toString()) }
            override fun onMessage(ws:WebSocket,text:String) { runCatching {
                require(text.length <= 200000);val f=codec.parseToJsonElement(text).jsonArray
                if(f.getOrNull(0)?.jsonPrimitive?.content == "OK" && f.getOrNull(1)?.jsonPrimitive?.content == event.text("id")) {
                    check(f[2].jsonPrimitive.boolean) { "Relay rejected workspace index" };result.complete(Unit)
                }
            }.onFailure { result.completeExceptionally(it) } }
            override fun onFailure(ws:WebSocket,t:Throwable,response:Response?) { result.completeExceptionally(t) }
        })
        try { result.await() } finally { socket.cancel();client.dispatcher.executorService.shutdown();client.connectionPool.evictAll() }
    }

    suspend fun query(relay: String, filter: JsonObject): List<JsonObject> = withTimeout(20000) {
        val result = CompletableDeferred<List<JsonObject>>()
        val rows = mutableListOf<JsonObject>(); val subscription = UUID.randomUUID().toString()
        val client = OkHttpClient.Builder().readTimeout(20,TimeUnit.SECONDS).build()
        val socket = client.newWebSocket(Request.Builder().url(relay).build(), object: WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { webSocket.send(buildJsonArray { add("REQ"); add(subscription); add(filter) }.toString()) }
            override fun onMessage(webSocket: WebSocket, text: String) {
                if(text.length > 200000) { result.completeExceptionally(IllegalStateException("Relay frame too large")); return }
                runCatching {
                    val f=codec.parseToJsonElement(text).jsonArray
                    if(f.getOrNull(1)?.jsonPrimitive?.content != subscription) return
                    when(f[0].jsonPrimitive.content) {
                        "EOSE" -> result.complete(rows.toList())
                        "CLOSED" -> result.completeExceptionally(IllegalStateException("Relay refused discovery"))
                        "EVENT" -> { check(rows.size < 1000); rows += f[2].jsonObject }
                    }
                }.onFailure { result.completeExceptionally(it) }
            }
            override fun onFailure(webSocket: WebSocket,t: Throwable,response: Response?) { result.completeExceptionally(t) }
            override fun onClosed(webSocket: WebSocket,code:Int,reason:String) { if(!result.isCompleted) result.completeExceptionally(IllegalStateException("Incomplete relay query")) }
        })
        try { result.await() } finally { socket.cancel(); client.dispatcher.executorService.shutdown(); client.connectionPool.evictAll() }
    }
}
