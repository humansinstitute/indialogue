import SwiftUI

struct NStackChoice: Identifiable { var id: String; var label: String; var app: String = ""; var participants: [String] = [] }
struct NStackSettings: View {
    @ObservedObject var transfers: NStackTransfers
    @ObservedObject var identity: IdentityModel
    @State private var origin = ""
    @State private var workspaces: [NStackChoice] = []
    @State private var channels: [NStackChoice] = []
    @State private var agents: [NStackChoice] = []
    @State private var manualRecipient = false
    @State private var directoryStatus: String?
    @State private var restored = false
    @State private var workspace: NStackChoice?
    @State private var channel: NStackChoice?
    @State private var recipient = ""
    @State private var recipientLabel = ""
    @State private var prompt = "Please review this recording."
    @State private var automatic = false
    @State private var captureMode: DialogueMode
    @State private var loading = false
    @State private var notice: String?
    init(transfers: NStackTransfers, identity: IdentityModel) {
        self.transfers = transfers; self.identity = identity
        _captureMode = State(initialValue:transfers.routing.mode)
    }
    private var api: NStackAPI { NStackAPI { try identity.sign(kind:$0,tags:$1,content:$2) } }
    var body: some View {
        Form {
            Section("Dialogue capture mode") {
                Picker("Mode",selection:$captureMode) {
                    ForEach(DialogueMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Text(captureMode == .normal ? "Uses the ordinary saved automatic or manual destination." : captureMode == .channel ? "Starts a conversation in the selected channel without an agent mention." : "Starts a conversation with the selected canonical agent and instruction.").font(.footnote)
            }
            Section("Connection") {
                TextField("https://your-nstack.example", text:$origin).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Text(identity.npub ?? "Unlock your imported Nostr identity to discover destinations.").font(.footnote).textSelection(.enabled)
                NavigationLink("Identity") { IdentitySettings(model:identity) }
                Button("Discover workspaces") { discover() }.disabled(!identity.unlocked || loading)
                if loading { ProgressView() }
                if let notice { Text(notice).foregroundStyle(.secondary) }
            }
            Section("Storage workspace") {
                if let workspace { Text("Selected: " + workspace.label) }
                ForEach(workspaces) { w in Button(w.label) { select(w) } }
            }
            Section("Message destination · all accessible scopes") {
                if let channel { Text("Selected: " + channel.label) }
                ForEach(channels) { c in Button(c.label) { channel = c; recipient = ""; recipientLabel = "" } }
                Text("Choose an existing channel or DM. Setup does not join workspaces or create channels.").font(.footnote)
            }
            Section("Optional receiving agent") {
                if let directoryStatus { Text(directoryStatus).font(.footnote) }
                ForEach(agents) { agent in
                    Button(agent.label) { recipient = agent.id; recipientLabel = agent.label }
                }
                Button("No receiving agent") { recipient = ""; recipientLabel = "" }
                if !recipient.isEmpty { Text("Selected: " + recipientLabel + " · " + recipient).font(.footnote) }
                if manualRecipient { TextField("Canonical agent npub",text:$recipient).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Agent label",text:$recipientLabel) }
                Text("Use an agent from the workspace directory. If unavailable, obtain its canonical routable npub from the workspace administrator. DM membership alone does not identify an agent.").font(.footnote)
            }
            Section("Delivery") {
                TextEditor(text:$prompt).frame(minHeight:100).accessibilityLabel("Custom prompt")
                Toggle("Automatically upload new recordings",isOn:$automatic)
                Text("New recordings wait for transcription and vocabulary corrections. Existing recordings require Upload. Unlock identity while the app is active to send. Audio stays on this device if delivery fails.").font(.footnote)
                Button("Save \(captureMode.rawValue) route") {
                    do {
                        guard let workspace, let channel, let signer = identity.npub else { throw NStackError.invalidSetup }
                        let trimmed = recipient.trimmingCharacters(in:.whitespacesAndNewlines)
                        let routedRecipient = captureMode == .agent && !trimmed.isEmpty ? trimmed : nil
                        let d = NStackDestination(origin:try NStackAPI.origin(origin).absoluteString,signer:signer,workspace:workspace.id,workspaceLabel:workspace.label,appNpub:workspace.app,channel:channel.id,channelLabel:channel.label,recipient:routedRecipient,recipientLabel:routedRecipient == nil ? nil : recipientLabel.trimmingCharacters(in:.whitespacesAndNewlines),prompt:prompt.trimmingCharacters(in:.whitespacesAndNewlines),automatic:automatic)
                        try transfers.saveRoute(d,mode:captureMode); notice = "Saved. This route is copied into each new recording; later settings changes do not retarget it."
                    } catch { notice = error.localizedDescription }
                }.disabled(loading || !identity.unlocked)
                if let saved = savedRoute { Text("Saved: \(saved.workspaceLabel) → \(saved.channelLabel)\n\(saved.signer)").font(.footnote).textSelection(.enabled) }
            }
        }.navigationTitle("NStack")
            .onAppear {
                guard !restored else { return }; restored = true
                if let d = savedRoute {
                    origin = d.origin; prompt = d.prompt; automatic = d.automatic
                    recipient = d.recipient ?? ""; recipientLabel = d.recipientLabel ?? ""
                    restoreSelection(d)
                }
            }
            .onChange(of:captureMode) { _,_ in loadSavedRoute() }
            .onChange(of:origin) { _,_ in
                reset()
                if let d = savedRoute, d.origin == origin { restoreSelection(d) }
            }
            .onChange(of:identity.npub) { _,_ in reset() }
    }
    var savedRoute: NStackDestination? {
        switch captureMode {
        case .normal: transfers.destination
        case .channel: transfers.routing.channel
        case .agent: transfers.routing.agent
        }
    }
    func loadSavedRoute() {
        guard let d = savedRoute else { return }
        origin = d.origin; prompt = d.prompt; automatic = d.automatic
        recipient = d.recipient ?? ""; recipientLabel = d.recipientLabel ?? ""
        restoreSelection(d)
    }
    func restoreSelection(_ d: NStackDestination) {
        let choices = NStackDiscovery.savedSelections(d)
        workspace = choices.workspace; channel = choices.channel
    }
    func reset() { directoryStatus = nil; agents = []; manualRecipient = false; workspaces = []; channels = []; workspace = nil; channel = nil }
    func discover() {
        reset(); loading = true; notice = nil
        let requestedOrigin = origin; let signer = identity.npub
        Task {
            defer { loading = false }
            do {
                let entries = try await api.list(origin:requestedOrigin,path:"/api/v4/flightdeck-pg/workspaces",key:"workspaces")
                guard origin == requestedOrigin, identity.npub == signer else { return }
                workspaces = try entries.map { w in
                    guard let i = w["identity"] as? [String:Any], let id = i["workspace_id"] as? String, let app = i["app_npub"] as? String, UUID(uuidString:id) != nil, NostrCodec.validNpub(app), let label = w["label"] as? String else { throw NStackError.malformed }
                    return NStackChoice(id:id,label:label,app:app)
                }
                if workspaces.isEmpty { notice = "No accessible workspaces for this identity." }
            } catch { notice = error.localizedDescription }
        }
    }
    func select(_ w: NStackChoice) {
        workspace = w; agents = []; manualRecipient = false; channel = nil; channels = []; recipient = ""; recipientLabel = ""; loading = true
        let requestedOrigin = origin; let signer = identity.npub
        Task {
            defer { loading = false }
            do {
                let descriptor = try await api.request(origin:requestedOrigin,path:"/api/v4/flightdeck-pg/workspaces/\(w.id)/descriptor",app:w.app)
                guard (descriptor["identity"] as? [String:Any])?["workspace_id"] as? String == w.id else { throw NStackError.malformed }
                let discovery = try await api.discoverChannels(origin:requestedOrigin, workspace:w, signer:signer)
                guard origin == requestedOrigin, identity.npub == signer, workspace?.id == w.id else { return }
                agents = discovery.agents; manualRecipient = discovery.directoryError != nil
                directoryStatus = discovery.directoryError.map { "Agent directory unavailable: " + $0 + " Retry workspace discovery or ask the workspace administrator for the canonical agent npub." }
                    ?? (agents.isEmpty ? "Agent directory loaded: no visible receiving agents are available." : "Choose a canonical receiving agent from the workspace directory.")
                channels = discovery.channels
                notice = discovery.channelError ?? (channels.isEmpty ? "No accessible message channels." : discovery.labelNotice)
            } catch { if origin == requestedOrigin, identity.npub == signer, workspace?.id == w.id { agents = []; manualRecipient = true; directoryStatus = "Discovery failed. Retry selecting the workspace."; channels = []; channel = nil; notice = error.localizedDescription } }
        }
    }
}
struct NStackHistory: View {
    @ObservedObject var transfers: NStackTransfers
    var body: some View {
        List {
            if let notice = transfers.notice { Text(notice) }
            if transfers.jobs.isEmpty { Text("No uploads yet. Configure NStack or use Upload on a saved recording.") }
            ForEach(transfers.jobs.reversed()) { job in
                Section(job.title) {
                    Text("\(job.destination.workspaceLabel) → \(job.destination.channelLabel)")
                    Text(job.state.replacingOccurrences(of:"_",with:" "))
                    if let notice = job.notice { Text(notice).font(.footnote) }
                    if let id = job.messageID { Text("Message: " + id).font(.footnote).textSelection(.enabled) }
                    if !["sent","cancelled"].contains(job.state) {
                        Button("Retry same snapshot") { transfers.retry(job.id) }
                        Button("Cancel local delivery",role:.destructive) { transfers.cancel(job.id) }
                    }
                }
            }
            Text("Local deletion and cancellation do not delete remote storage or retract posted messages. Retry uses the original identity, destination and content.").font(.footnote)
        }.navigationTitle("NStack uploads")
    }
}

enum NStackDiscovery {
    static func savedSelections(_ d: NStackDestination) -> (workspace:NStackChoice,channel:NStackChoice) {
        (NStackChoice(id:d.workspace,label:d.workspaceLabel,app:d.appNpub), NStackChoice(id:d.channel,label:d.channelLabel))
    }
    static func text(_ entry: [String:Any], _ keys: [String]) -> String? {
        for key in keys { if let value = entry[key] as? String, !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return value.trimmingCharacters(in:.whitespacesAndNewlines) } }
        return nil
    }
    static func agents(_ response: [String:Any]) throws -> [NStackChoice] {
        guard let entries = response["workspace_agents"] as? [[String:Any]] ?? response["agents"] as? [[String:Any]] else { throw NStackError.malformed }
        var seen = Set<String>()
        return entries.compactMap { entry in
            if entry["is_visible"] as? Bool == false || (entry["metadata"] as? [String:Any])?["can_instruct"] as? Bool == false || entry["archived_at"] is String { return nil }
            let actor = entry["actor"] as? [String:Any] ?? entry
            // The directory's routing identity takes precedence over legacy presentation actors.
            guard let npub = entry["agent_npub"] as? String ?? actor["npub"] as? String ?? actor["actor_npub"] as? String,
                  NostrCodec.validNpub(npub), seen.insert(npub).inserted else { return nil }
            let label = text(entry,["display_name","name"]) ?? text(actor,["display_name","label"]) ?? "Agent"
            return NStackChoice(id:npub,label:label)
        }
    }
    static func memberLabels(_ entries: [[String:Any]]) -> [String:String] {
        var labels: [String:String] = [:]
        for entry in entries {
            let actor = entry["actor"] as? [String:Any] ?? entry
            if let npub = text(actor,["npub","actor_npub"]), NostrCodec.validNpub(npub), let label = text(actor,["display_name","label","name"]) { labels[npub] = label }
        }
        return labels
    }
    static func channel(_ entry: [String:Any], scope: [String:Any], signer: String?, labels: [String:String]) throws -> NStackChoice {
        guard let id = entry["id"] as? String, UUID(uuidString:id) != nil else { throw NStackError.malformed }
        let participants = (entry["participant_npubs"] as? [String] ?? []).filter { NostrCodec.validNpub($0) }
        let title = text(entry,["title","name","label"])
        var label = title ?? "Channel " + String(id.prefix(8))
        if entry["kind"] as? String == "dm" {
            let others = participants.filter { $0 != signer }
            // Preserve a meaningful supplied title; replace generated DM/npub titles with available labels.
            let generated = title.map { value in
                let suffix = value.lowercased().hasPrefix("dm:") ? String(value.dropFirst(3)).trimmingCharacters(in:.whitespacesAndNewlines) : value
                return value.lowercased() == "dm" || NostrCodec.validNpub(suffix)
            } ?? true
            if generated {
                label = others.isEmpty ? "Direct message" : others.map { labels[$0] ?? (String($0.prefix(12)) + "…" + String($0.suffix(6))) }.joined(separator:", ")
            }
            label += " · DM"
        }
        return NStackChoice(id:id,label:(text(scope,["title","name","label"]) ?? "Scope") + " / " + label,participants:participants)
    }
}

struct NStackChannelDiscovery {
    var channels: [NStackChoice]
    var agents: [NStackChoice]
    var directoryError: String?
    var labelNotice: String?
    var channelError: String?
}

extension NStackAPI {
    /// Read every cursor page, refusing loops and capped responses that cannot prove completeness.
    func list(origin: String, path: String, app: String? = nil, key: String) async throws -> [[String:Any]] {
        var entries: [[String:Any]] = []; var cursor: String?; var seen = Set<String>()
        repeat {
            var components = URLComponents(); components.queryItems = [URLQueryItem(name:"limit",value:"200")]
            if let cursor { components.queryItems!.append(URLQueryItem(name:"cursor",value:cursor)) }
            let response = try await request(origin:origin,path:path + "?" + components.percentEncodedQuery!,app:app)
            guard let page = response[key] as? [[String:Any]] else { throw NStackError.malformed }
            entries += page
            cursor = response["next_cursor"] as? String
            if let next = cursor { guard !next.isEmpty, seen.insert(next).inserted else { throw NStackError.malformed } }
            else if response["has_more"] as? Bool == true || page.count >= 200 { throw NStackError.discoveryLimit }
        } while cursor != nil
        return entries
    }
    func discoverChannels(origin: String, workspace: NStackChoice, signer: String?) async throws -> NStackChannelDiscovery {
        let base = "/api/v4/flightdeck-pg/workspaces/" + workspace.id
        var agents: [NStackChoice] = []; var directoryError: String?; var labelNotice: String?
        do { agents = try NStackDiscovery.agents(["workspace_agents":try await list(origin:origin,path:base + "/workspace-agents",app:workspace.app,key:"workspace_agents")]) }
        catch { directoryError = error.localizedDescription }
        var labels: [String:String] = [:]
        do { labels = NStackDiscovery.memberLabels(try await list(origin:origin,path:base + "/members",app:workspace.app,key:"members")) }
        catch { labelNotice = "Participant names unavailable. Showing channel titles or abbreviated public identities. " + error.localizedDescription }
        for agent in agents { labels[agent.id] = agent.label }
        do {
            let records = try await channelRecords(origin:origin,workspace:workspace)
            var channels: [NStackChoice] = []; var seen = Set<String>()
            for entry in records.channels {
                let scope = records.scopes.first { $0["id"] as? String == entry["scope_id"] as? String } ?? [:]
                let choice = try NStackDiscovery.channel(entry,scope:scope,signer:signer,labels:labels)
                if seen.insert(choice.id).inserted { channels.append(choice) }
            }
            let notices = [labelNotice,records.notice].compactMap { $0 }
            return NStackChannelDiscovery(channels:channels,agents:agents,directoryError:directoryError,labelNotice:notices.isEmpty ? nil : notices.joined(separator:"\n\n"),channelError:nil)
        } catch {
            // A channel failure must not discard an independently successful agent directory.
            return NStackChannelDiscovery(channels:[],agents:agents,directoryError:directoryError,labelNotice:labelNotice,channelError:"Channel discovery failed: " + error.localizedDescription + " Retry selecting the workspace.")
        }
    }
    func channelRecords(origin: String, workspace: NStackChoice) async throws -> (scopes:[[String:Any]],channels:[[String:Any]],notice:String?) {
        let base = "/api/v4/flightdeck-pg/workspaces/" + workspace.id
        do {
            // Sync returns all scope/channel metadata on each page; its cursor pages channel message bundles,
            // not discovery records. Request one bundle item rather than walking unrelated chat history.
            let snapshot = try await request(origin:origin,path:base + "/sync?limit=1",app:workspace.app)
            guard snapshot["full_snapshot"] as? Bool == true,
                  let scopes = snapshot["scopes"] as? [[String:Any]], let channels = snapshot["channels"] as? [[String:Any]] else { throw NStackError.malformed }
            guard scopes.count < 10_000 else { throw NStackError.discoveryLimit }
            var counts: [String:Int] = [:]
            for channel in channels {
                guard let scope = channel["scope_id"] as? String else { throw NStackError.malformed }
                counts[scope,default:0] += 1
            }
            guard counts.values.allSatisfy({ $0 < 10_000 }) else { throw NStackError.discoveryLimit }
            return (scopes,channels,nil)
        } catch NStackError.discoveryLimit { throw NStackError.discoveryLimit }
        catch {
            let snapshotError = error.localizedDescription
            var scopes = try await list(origin:origin,path:base + "/scopes",app:workspace.app,key:"scopes")
            var channels: [[String:Any]] = []
            for scope in scopes {
                guard let id = scope["id"] as? String, UUID(uuidString:id) != nil else { throw NStackError.malformed }
                let entries = try await list(origin:origin,path:base + "/scopes/" + id + "/channels",app:workspace.app,key:"channels")
                channels += entries.map { entry in var row = entry; row["scope_id"] = id; return row }
            }
            // Include directly granted channels reported by /me, even if their scopes were omitted.
            do {
                let me = try await request(origin:origin,path:base + "/me",app:workspace.app)
                guard let visible = me["visible"] as? [String:Any], let direct = visible["channels"] as? [[String:Any]], let directScopes = visible["scopes"] as? [[String:Any]] else { throw NStackError.malformed }
                guard direct.count < 200, directScopes.count < 200 else { throw NStackError.discoveryLimit }
                channels += direct; scopes += directScopes
            } catch NStackError.discoveryLimit { throw NStackError.discoveryLimit }
            catch { return (scopes,channels,"Complete sync discovery unavailable: " + snapshotError + " Directly granted channel discovery unavailable: " + error.localizedDescription + " Retry discovery before relying on this list.") }
            return (scopes,channels,"Complete sync discovery unavailable: " + snapshotError + " Showing accessible scope and directly granted channels; retry discovery to confirm completeness.")
        }
    }
}
