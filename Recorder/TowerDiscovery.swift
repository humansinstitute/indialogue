import Foundation
import P256K
import CoreFoundation

enum DiscoveryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return "Tower discovery failed" }
}
struct WorkspaceLocator: Equatable {
    let origin: String
    let identity: [String:String]
    let label: String
    static let keys = ["tower_service_npub","workspace_service_npub","workspace_owner_npub","workspace_id","app_npub"]
    var workspace: String { identity["workspace_id"]! }
    var tower: String { identity["tower_service_npub"]! }
    var app: String { identity["app_npub"]! }
    var choice: NStackChoice { NStackChoice(id:workspace,label:label,app:app,locator:self) }
    static func parse(_ raw: [String:Any]) throws -> WorkspaceLocator {
        guard raw["type"] as? String == "wingman_workspace_locator", SelfIndexes.versionOne(raw["version"]),
              let origin = raw["tower_base_url"] as? String else { throw NStackError.malformed }
        let url = try NStackAPI.origin(origin).absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        let i = raw["identity"] as? [String:Any] ?? raw
        var identity = [String:String]()
        for key in keys { guard let value = i[key] as? String else { throw NStackError.malformed }; identity[key] = value }
        guard UUID(uuidString:identity["workspace_id"]!) != nil,
              keys.filter({$0 != "workspace_id"}).allSatisfy({NostrCodec.validNpub(identity[$0]!)}) else { throw NStackError.malformed }
        return WorkspaceLocator(origin:url,identity:identity,label:raw["label"] as? String ?? "Workspace")
    }
}
struct TowerChoice: Equatable, Identifiable {
    let origin: String
    let service: String
    var id: String { origin + ":" + service }
}
enum SelfIndexes {
    static func versionOne(_ value: Any?) -> Bool { guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }; return n.doubleValue == 1 }
    static let appPub = "166f8d10ed9d5480a05066fd23b0ce8c4b4807d0b43bc424648f9dc00bef114f"
    static var appNpub: String { NostrCodec.npub(hex(appPub)!) }
    @MainActor static func event(_ w: WorkspaceLocator, identity: IdentityModel) throws -> NostrEvent {
        let pub = try identity.sign(kind:27235,tags:[],content:"").pubkey
        let now = ISO8601DateFormatter().string(from:Date())
        var locator: [String:Any] = w.identity; locator["type"]="wingman_workspace_locator";locator["version"]=1;locator["tower_base_url"]=w.origin;locator["label"]=w.label
        let payload: [String:Any] = ["type":"flightdeck_workspace_self_index","version":1,"user_npub":identity.npub!,"issued_at":now,"updated_at":now,"app":["app_npub":appNpub,"app_pubkey":appPub,"namespace":"flightdeck_pg"],"workspace":locator,"state":["deleted":false]]
        let d="fd-self:" + NostrCodec.hash(Data("v1:\(pub):\(appPub):\(w.tower):\(w.workspace)".utf8))
        return try identity.sign(kind:33356,tags:[["d",d],["p",pub],["app_pub",appPub],["protocol","workspace-self-index"],["v","1"]],content:identity.encryptSelf(NostrCodec.json(payload)))
    }
    static func filter(_ pub: String) -> [String:Any] { ["kinds":[33356],"authors":[pub],"#p":[pub],"limit":1000] }
    static func tag(_ e: NostrEvent, _ name: String) throws -> String {
        let tags = e.tags.filter { $0.first == name }
        guard tags.count == 1, tags[0].count == 2 else { throw NStackError.malformed }
        return tags[0][1]
    }
    static func hex(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }; var data = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i,offsetBy:2); guard let b=UInt8(s[i..<j],radix:16) else { return nil }; data.append(b); i=j }; return data
    }
    static func authentic(_ e: NostrEvent, pub: String, now: Int) -> Bool {
        guard e.pubkey == pub, e.kind == 33356, e.created_at >= 0, e.created_at <= now + 300,
            (try? tag(e,"d")) != nil,
            let bytes = try? NostrCodec.json([0,e.pubkey,e.created_at,e.kind,e.tags,e.content]), NostrCodec.hash(bytes) == e.id,
            let publicBytes=hex(pub),publicBytes.count == 32, let sig=hex(e.sig), let signature=try? P256K.Schnorr.SchnorrSignature(dataRepresentation:sig), let hash=hex(e.id) else { return false }
        var digest=Array(hash)
        return P256K.Schnorr.XonlyKey(dataRepresentation:publicBytes).isValid(signature,for:&digest)
    }
    static func valid(_ e: NostrEvent, pub: String, now: Int) -> Bool {
        guard authentic(e,pub:pub,now:now), (try? tag(e,"p")) == pub, (try? tag(e,"protocol")) == "workspace-self-index", (try? tag(e,"v")) == "1", let app=try? tag(e,"app_pub"), let bytes=hex(app),bytes.count == 32 else { return false };return true
    }
    static func candidates(_ events: [NostrEvent], pub: String, decrypt: (String) throws -> Data, now: Int = Int(Date().timeIntervalSince1970)) -> [WorkspaceLocator] {
        var seen=Set<String>(); var results=[WorkspaceLocator]()
        for e in events.filter({authentic($0,pub:pub,now:now)}).sorted(by: {$0.created_at == $1.created_at ? $0.id < $1.id : $0.created_at > $1.created_at}) {
            guard let d=try? tag(e,"d"), seen.insert(d).inserted else { continue }
            // Tombstones and unreadable latest replacements suppress their older addresses.
            do {
                guard valid(e,pub:pub,now:now) else { continue }
                guard let p=try JSONSerialization.jsonObject(with:decrypt(e.content)) as? [String:Any],
                    p["type"] as? String == "flightdeck_workspace_self_index",versionOne(p["version"]),
                    p["user_npub"] as? String == NostrCodec.npub(hex(pub)!),
                    let app=p["app"] as? [String:Any], let appPub=try? tag(e,"app_pub"),
                    app["namespace"] as? String == "flightdeck_pg",app["app_pubkey"] as? String == appPub,
                    app["app_npub"] as? String == NostrCodec.npub(hex(appPub)!),
                    let raw=p["workspace"] as? [String:Any] else { continue }
                let w=try WorkspaceLocator.parse(raw)
                guard d == "fd-self:" + NostrCodec.hash(Data("v1:\(pub):\(appPub):\(w.tower):\(w.workspace)".utf8)),
                    let state=p["state"] as? [String:Any],state["deleted"] as? Bool == false else { continue }
                if !results.contains(w) { results.append(w) }
            } catch { continue }
        }
        return results
    }
}
@MainActor
final class TowerDiscovery {
    let identity: IdentityModel
    init(_ identity: IdentityModel) { self.identity=identity }
    func publish(_ w: WorkspaceLocator) async throws {
        let signer=identity.npub; let epoch=identity.generation
        let api=NStackAPI { kind,tags,content in guard self.identity.generation == epoch else { throw VaultError.unavailable }; return try self.identity.sign(kind:kind,tags:tags,content:content) }
        try await api.verify(w)
        let event=try SelfIndexes.event(w,identity:identity)
        for relay in ["wss://relay.primal.net","wss://relay.damus.io"] {
            do {
                try await RelayIndexQuery.publish(relay,event:event)
                let read=try await RelayIndexQuery.query(relay,filter:["ids":[event.id],"limit":1])
                guard read.contains(where:{$0.id == event.id && $0.sig == event.sig}),SelfIndexes.candidates(read,pub:event.pubkey,decrypt:identity.decryptSelf).contains(w),identity.npub == signer, identity.generation == epoch else { throw NStackError.malformed }
                return
            } catch is CancellationError { throw CancellationError() } catch { }
        };throw DiscoveryError.invalid("Workspace announcement pending. Select the workspace again to retry.")
    }
    func discover() async throws -> [TowerChoice] {
        guard let signer=identity.npub else { throw VaultError.unavailable }; let epoch=identity.generation
        let event=try identity.sign(kind:27235,tags:[],content:""); let pub=event.pubkey
        var events=[NostrEvent](); var successes=0
        for relay in ["wss://relay.primal.net","wss://relay.damus.io"] {
            do { let rows=try await RelayIndexQuery.query(relay,filter:SelfIndexes.filter(pub)); guard rows.count < 1000 else { throw NStackError.discoveryLimit }; events += rows; successes += 1 }
            catch is CancellationError { throw CancellationError() } catch { }
        }
        guard successes > 0 else { throw DiscoveryError.invalid("Tower discovery failed. Retry or enter an HTTPS Tower manually.") }
        guard identity.npub == signer, identity.generation == epoch else { throw VaultError.unavailable }
        let candidates=SelfIndexes.candidates(events,pub:pub,decrypt:identity.decryptSelf)
        guard candidates.count <= 100 else { throw NStackError.discoveryLimit }
        let api=NStackAPI { kind,tags,content in guard self.identity.generation == epoch else { throw VaultError.unavailable }; return try self.identity.sign(kind:kind,tags:tags,content:content) }; var towers=[TowerChoice]()
        for w in candidates {
            do { try await api.verify(w); let t=TowerChoice(origin:w.origin,service:w.tower); if !towers.contains(t) { towers.append(t) } }
            catch is CancellationError { throw CancellationError() } catch { }
        }
        guard identity.npub == signer, identity.generation == epoch else { throw VaultError.unavailable }
        return towers
    }
}
enum RelayIndexQuery {
    static func publish(_ relay: String, event: NostrEvent) async throws {
        guard let url=URL(string:relay),url.scheme == "wss" else { throw NStackError.unsafeURL }
        let socket=URLSession.shared.webSocketTask(with:url);socket.resume();defer { socket.cancel(with:.normalClosure,reason:nil) }
        let raw=try JSONSerialization.jsonObject(with:JSONEncoder().encode(event))
        try await socket.send(.string(String(decoding:try NostrCodec.json(["EVENT",raw]),as:UTF8.self)))
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask {
                for _ in 0..<100 {
                    let message=try await socket.receive();let data:Data
                    switch message { case .data(let d):data=d;case .string(let s):data=Data(s.utf8);@unknown default:throw NStackError.malformed }
                    guard data.count <= 200000,let frame=try JSONSerialization.jsonObject(with:data) as? [Any] else { throw NStackError.malformed }
                    if frame.count >= 3,frame[0] as? String == "OK",frame[1] as? String == event.id { guard frame[2] as? Bool == true else { throw NStackError.malformed };return }
                };throw NStackError.malformed
            }
            group.addTask { try await Task.sleep(for:.seconds(20));socket.cancel(with:.goingAway,reason:nil);throw NStackError.malformed }
            defer { group.cancelAll() };try await group.next()!
        }
    }

    static func query(_ relay: String, filter: [String:Any]) async throws -> [NostrEvent] {
        guard let url=URL(string:relay),url.scheme == "wss" else { throw NStackError.unsafeURL }
        let socket=URLSession.shared.webSocketTask(with:url); socket.resume()
        defer { socket.cancel(with:.normalClosure,reason:nil) }
        let id=UUID().uuidString
        try await socket.send(.string(String(decoding:try NostrCodec.json(["REQ",id,filter]),as:UTF8.self)))
        return try await withThrowingTaskGroup(of:[NostrEvent].self) { group in
            group.addTask {
                var events=[NostrEvent]()
                for _ in 0..<2000 {
                    let message=try await socket.receive(); let data: Data
                    switch message { case .data(let d): data=d; case .string(let s): data=Data(s.utf8); @unknown default: throw NStackError.malformed }
                    guard data.count <= 200000,let frame=try JSONSerialization.jsonObject(with:data) as? [Any],frame.count >= 2 else { throw NStackError.malformed }
                    guard frame[1] as? String == id else { continue }
                    if frame[0] as? String == "EOSE" { return events }
                    if frame[0] as? String == "CLOSED" { throw NStackError.malformed }
                    if frame[0] as? String == "EVENT",frame.count == 3 {
                        guard events.count < 1000 else { throw NStackError.discoveryLimit }
                        if let event=try? JSONDecoder().decode(NostrEvent.self,from:JSONSerialization.data(withJSONObject:frame[2])) { events.append(event) }
                    }
                }; throw NStackError.discoveryLimit
            }
            group.addTask { try await Task.sleep(for:.seconds(20)); socket.cancel(with:.goingAway,reason:nil); throw DiscoveryError.invalid("Relay discovery timed out. Retry or enter an HTTPS origin.") }
            defer { group.cancelAll() }; return try await group.next()!
        }
    }
}
extension NStackAPI {
    func verify(_ w: WorkspaceLocator) async throws {
        let me=try await request(origin:w.origin,path:"/api/v4/flightdeck-pg/workspaces/\(w.workspace)/me",app:w.app)
        guard let i=me["identity"] as? [String:Any],WorkspaceLocator.keys.allSatisfy({i[$0] as? String == w.identity[$0]}) else { throw NStackError.malformed }
    }
    func workspaces(origin: String) async throws -> [NStackChoice] {
        let entries=try await list(origin:origin,path:"/api/v4/flightdeck-pg/workspaces",key:"workspaces")
        var choices=[NStackChoice]()
        for row in entries {
            var raw=row["locator"] as? [String:Any] ?? row["workspace_locator"] as? [String:Any] ?? row
            raw["type"]="wingman_workspace_locator";raw["version"]=1;raw["tower_base_url"]=origin
            raw["label"]=row["label"] ?? row["name"] ?? "Workspace"
            let w=try WorkspaceLocator.parse(raw);try await verify(w);choices.append(w.choice)
        };return choices
    }
}
