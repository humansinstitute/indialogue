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
    @State private var workspace: NStackChoice?
    @State private var channel: NStackChoice?
    @State private var recipient = ""
    @State private var recipientLabel = ""
    @State private var prompt = "Please review this recording."
    @State private var automatic = false
    @State private var loading = false
    @State private var notice: String?
    private var api: NStackAPI { NStackAPI { try identity.sign(kind:$0,tags:$1,content:$2) } }
    var body: some View {
        Form {
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
                ForEach(agents) { agent in
                    Button(agent.label) { recipient = agent.id; recipientLabel = agent.label }
                }
                Button("No receiving agent") { recipient = ""; recipientLabel = "" }
                if !recipient.isEmpty { Text("Selected: " + recipientLabel + " · " + recipient).font(.footnote) }
                ForEach(channel?.participants ?? [],id: \.self) { npub in
                    Button("Use participant " + npub) { recipient = npub; recipientLabel = "Agent" }
                }
                if manualRecipient { TextField("Canonical agent npub",text:$recipient).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Agent label",text:$recipientLabel) }
                Text("Enter the canonical npub from the workspace agent or DM participant. Names alone cannot route instructions.").font(.footnote)
            }
            Section("Delivery") {
                TextEditor(text:$prompt).frame(minHeight:100).accessibilityLabel("Custom prompt")
                Toggle("Automatically upload new recordings",isOn:$automatic)
                Text("New recordings wait for transcription and vocabulary corrections. Existing recordings require Upload. Unlock identity while the app is active to send. Audio stays on this device if delivery fails.").font(.footnote)
                Button("Save NStack setup") {
                    do {
                        guard let workspace, let channel, let signer = identity.npub else { throw NStackError.invalidSetup }
                        let trimmed = recipient.trimmingCharacters(in:.whitespacesAndNewlines)
                        let d = NStackDestination(origin:try NStackAPI.origin(origin).absoluteString,signer:signer,workspace:workspace.id,workspaceLabel:workspace.label,appNpub:workspace.app,channel:channel.id,channelLabel:channel.label,recipient:trimmed.isEmpty ? nil : trimmed,recipientLabel:trimmed.isEmpty ? nil : recipientLabel.trimmingCharacters(in:.whitespacesAndNewlines),prompt:prompt.trimmingCharacters(in:.whitespacesAndNewlines),automatic:automatic)
                        try transfers.save(d); notice = "Saved. Automatic uploads apply only to newly completed recordings."
                    } catch { notice = error.localizedDescription }
                }.disabled(loading || !identity.unlocked)
                if let saved = transfers.destination { Text("Saved: \(saved.workspaceLabel) → \(saved.channelLabel)\n\(saved.signer)").font(.footnote).textSelection(.enabled) }
            }
        }.navigationTitle("NStack")
            .onAppear {
                if let d = transfers.destination { origin = d.origin; prompt = d.prompt; automatic = d.automatic; recipient = d.recipient ?? ""; recipientLabel = d.recipientLabel ?? "" }
            }
            .onChange(of:origin) { _,_ in reset() }
            .onChange(of:identity.npub) { _,_ in reset() }
    }
    func reset() { agents = []; manualRecipient = false; workspaces = []; channels = []; workspace = nil; channel = nil }
    func discover() {
        reset(); loading = true; notice = nil
        let requestedOrigin = origin; let signer = identity.npub
        Task {
            defer { loading = false }
            do {
                let result = try await api.request(origin:requestedOrigin,path:"/api/v4/flightdeck-pg/workspaces")
                guard origin == requestedOrigin, identity.npub == signer else { return }
                workspaces = try (result["workspaces"] as? [[String:Any]] ?? []).map { w in
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
                var foundAgents: [NStackChoice] = []; var directoryUnavailable = false
                do {
                    let agentResponse = try await api.request(origin:requestedOrigin,path:"/api/v4/flightdeck-pg/workspaces/\(w.id)/workspace-agents",app:w.app)
                    foundAgents = try NStackDiscovery.agents(agentResponse)
                } catch { directoryUnavailable = true }
                let result = try await api.request(origin:requestedOrigin,path:"/api/v4/flightdeck-pg/workspaces/\(w.id)/scopes",app:w.app)
                var found: [NStackChoice] = []
                for scope in result["scopes"] as? [[String:Any]] ?? [] {
                    guard let id = scope["id"] as? String, UUID(uuidString:id) != nil else { throw NStackError.malformed }
                    let response = try await api.request(origin:requestedOrigin,path:"/api/v4/flightdeck-pg/workspaces/\(w.id)/scopes/\(id)/channels",app:w.app)
                    for c in response["channels"] as? [[String:Any]] ?? [] {
                        guard let cid = c["id"] as? String, UUID(uuidString:cid) != nil else { throw NStackError.malformed }
                        found.append(NStackChoice(id:cid,label:"\(scope["name"] as? String ?? scope["label"] as? String ?? "Scope") / \(c["name"] as? String ?? c["label"] as? String ?? "Channel") · \(c["kind"] as? String ?? "channel")", participants:(c["participant_npubs"] as? [String] ?? []).filter { NostrCodec.validNpub($0) && $0 != signer }))
                    }
                }
                guard origin == requestedOrigin, identity.npub == signer, workspace?.id == w.id else { return }
                agents = foundAgents; manualRecipient = directoryUnavailable; channels = found; notice = found.isEmpty ? "No accessible message channels." : nil
            } catch { if workspace?.id == w.id { agents = []; manualRecipient = true; channels = []; channel = nil; notice = error.localizedDescription } }
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
    static func agents(_ response: [String:Any]) throws -> [NStackChoice] {
        guard let entries = response["agents"] as? [[String:Any]] ?? response["workspace_agents"] as? [[String:Any]] else { throw NStackError.malformed }
        var seen = Set<String>()
        return entries.compactMap { entry in
            if entry["is_visible"] as? Bool == false || (entry["metadata"] as? [String:Any])?["can_instruct"] as? Bool == false { return nil }
            let actor = entry["actor"] as? [String:Any] ?? entry
            guard let npub = actor["npub"] as? String ?? actor["actor_npub"] as? String ?? entry["agent_npub"] as? String,
                  NostrCodec.validNpub(npub), seen.insert(npub).inserted else { return nil }
            let label = actor["label"] as? String ?? entry["display_name"] as? String ?? entry["name"] as? String ?? "Agent"
            return NStackChoice(id:npub,label:label)
        }
    }
}
