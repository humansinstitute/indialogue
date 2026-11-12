package com.wingmanbefree.indialogue

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow

/** Public identity and an authentication epoch; never contains secret material. */
data class AuthContext(val npub: String?, val generation: Long)

data class SetupState(
    val origin: String = "",
    val towers: List<TowerChoice> = emptyList(),
    val selectedTower: TowerChoice? = null,
    val workspace: Choice? = null,
    val channel: Choice? = null,
    val workspaces: List<Choice> = emptyList(),
    val channels: List<Choice> = emptyList(),
    val agents: List<Choice> = emptyList(),
    val recipient: String = "",
    val recipientLabel: String = "",
    val manualRecipient: Boolean = false,
    val busy: Boolean = false,
    val notice: String = "",
)

/** Owns selector authority so delayed network responses cannot revive an obsolete connection. */
class NStackSetup(
    private val scope: CoroutineScope,
    private val auth: () -> AuthContext,
    private val loadWorkspaces: suspend (String, AuthContext) -> List<Choice>,
    private val loadChannels: suspend (String, Choice, AuthContext) -> NStackAPI.Discovery,
    private val saved: Destination? = null,
    private val keepSeedChannel: Boolean = true,
    private val loadTowers: suspend (AuthContext) -> List<TowerChoice> = { emptyList() },
    private val publishIndex: suspend (WorkspaceLocator, AuthContext) -> Unit = { _, _ -> },
) {
    val state = MutableStateFlow(SetupState(origin = saved?.origin.orEmpty()))
    private var connection = auth()
    private var generation = 0L
    private var pending: Job? = null
    private var restoreAvailable = true

    init {
        restoreIfMatching()
    }

    private fun restoreIfMatching() {
        if (!restoreAvailable || saved == null) return
        if (connection.npub == saved.signer && state.value.origin == saved.origin) {
            state.value =
                state.value.copy(
                    workspace = Choice(saved.workspace, saved.workspaceLabel, saved.appNpub),
                    channel = if (keepSeedChannel) Choice(saved.channel, saved.channelLabel) else null,
                    recipient = saved.recipient.orEmpty(),
                    recipientLabel = saved.recipientLabel.orEmpty(),
                )
            restoreAvailable = false
        } else if (connection.npub != null) restoreAvailable = false
    }

    private fun clear(origin: String = state.value.origin) {
        generation++
        pending?.cancel()
        pending = null
        state.value = SetupState(origin = origin)
    }

    fun setOrigin(value: String) {
        if (value != state.value.origin) {
            restoreAvailable = false
            clear(value)
        }
    }

    fun refreshIdentity() {
        val current = auth()
        if (current != connection) {
            clear()
            connection = current
            restoreIfMatching()
        }
    }

    private data class Ticket(
        val generation: Long,
        val origin: String,
        val auth: AuthContext,
        val workspace: String?,
    )

    private fun valid(ticket: Ticket): Boolean =
        ticket.generation == generation &&
            ticket.origin == state.value.origin &&
            ticket.auth == auth() &&
            ticket.auth == connection &&
            ticket.workspace == state.value.workspace?.id

    private fun begin(workspace: Choice?): Ticket {
        refreshIdentity()
        check(connection.npub != null) { "Unlock identity first." }
        val origin = NStackAPI.origin(state.value.origin)
        generation++
        pending?.cancel()
        state.value =
            state.value.copy(
                origin = origin,
                workspace = workspace,
                channel = null,
                channels = emptyList(),
                agents = emptyList(),
                recipient = "",
                recipientLabel = "",
                manualRecipient = false,
                busy = true,
                notice = "",
            )
        return Ticket(generation, origin, connection, workspace?.id)
    }

    fun discoverTowers() {
        refreshIdentity()
        val requested = connection
        if (requested.npub == null) return
        generation++
        pending?.cancel()
        val ticket = generation
        state.value = state.value.copy(busy = true, notice = "Discovering Towers…")
        pending = scope.launch {
            try {
                val towers = loadTowers(requested)
                if (ticket == generation && auth() == requested) state.value = state.value.copy(towers = towers, notice = if (towers.isEmpty()) "No verified Towers found. Retry or enter an HTTPS origin." else "Choose a Tower, then a workspace.")
            } catch (e: Exception) {
                if (e !is CancellationException && ticket == generation && auth() == requested) state.value = state.value.copy(notice = e.message.orEmpty())
            } finally { if (ticket == generation && auth() == requested) state.value = state.value.copy(busy = false) }
        }
    }

    fun selectTower(tower: TowerChoice) {
        require(tower in state.value.towers)
        val towers = state.value.towers
        clear(tower.origin)
        state.value = state.value.copy(towers = towers, selectedTower = tower)
        discover()
    }

    fun discover() {
        val ticket =
            try {
                begin(null)
            } catch (e: Exception) {
                state.value = state.value.copy(notice = e.message.orEmpty())
                return
            }
        state.value = state.value.copy(workspaces = emptyList())
        pending = scope.launch {
            try {
                val rows = loadWorkspaces(ticket.origin, ticket.auth)
                val tower = state.value.selectedTower
                check(tower == null || rows.all { it.locator?.tower == tower.service }) { "Selected Tower identity changed." }
                if (valid(ticket))
                    state.value =
                        state.value.copy(
                            workspaces = rows,
                            notice =
                                if (rows.isEmpty()) "No accessible workspaces."
                                else "Choose a storage workspace.",
                        )
            } catch (e: Exception) {
                if (valid(ticket) && e !is CancellationException)
                    state.value = state.value.copy(notice = e.message.orEmpty())
            } finally {
                if (valid(ticket)) state.value = state.value.copy(busy = false)
            }
        }
    }

    fun selectWorkspace(choice: Choice, preserve: Boolean = false) {
        val retained = state.value.takeIf { preserve && it.workspace?.id == choice.id }
        val ticket =
            try {
                begin(choice)
            } catch (e: Exception) {
                state.value = state.value.copy(notice = e.message.orEmpty())
                return
            }
        pending = scope.launch {
            try {
                val result = loadChannels(ticket.origin, choice, ticket.auth)
                var publicationNotice = ""
                choice.locator?.let { w -> try { publishIndex(w,ticket.auth) } catch (e: CancellationException) { throw e } catch (_: Exception) { publicationNotice = " Workspace announcement pending. Select the workspace again to retry." } }
                if (valid(ticket))
                    state.value =
                        state.value.copy(
                            channel = retained?.channel?.takeIf { it in result.channels },
                            recipient = retained?.recipient?.takeIf { value -> result.agents.any { it.id == value } }.orEmpty(),
                            recipientLabel = retained?.recipientLabel?.takeIf { result.agents.any { agent -> agent.id == retained.recipient } }.orEmpty(),
                            channels = result.channels,
                            agents = result.agents,
                            manualRecipient = result.directoryUnavailable,
                            notice = result.notice + publicationNotice,
                        )
            } catch (e: Exception) {
                if (valid(ticket) && e !is CancellationException)
                    state.value = state.value.copy(notice = e.message.orEmpty())
            } finally {
                if (valid(ticket)) state.value = state.value.copy(busy = false)
            }
        }
    }

    fun selectChannel(choice: Choice) {
        refreshIdentity()
        require(choice in state.value.channels)
        state.value = state.value.copy(channel = choice, recipient = "", recipientLabel = "")
    }

    fun selectAgent(choice: Choice?) {
        refreshIdentity()
        if (choice != null) require(choice in state.value.agents)
        state.value =
            state.value.copy(
                recipient = choice?.id.orEmpty(),
                recipientLabel = choice?.label.orEmpty(),
            )
    }

    fun manualRecipient(npub: String, label: String) {
        refreshIdentity()
        check(state.value.manualRecipient)
        state.value = state.value.copy(recipient = npub, recipientLabel = label)
    }

    fun destination(prompt: String, automatic: Boolean): Destination {
        check(auth() == connection && connection.npub != null) {
            "Identity changed; discover destinations again."
        }
        val s = state.value
        check(!s.busy)
        val workspace = checkNotNull(s.workspace) { "Choose workspace." }
        val channel = checkNotNull(s.channel) { "Choose channel." }
        return Destination(
                NStackAPI.origin(s.origin),
                connection.npub!!,
                workspace.id,
                workspace.label,
                workspace.app,
                channel.id,
                channel.label,
                prompt.trim(),
                automatic,
                s.recipient.trim().ifBlank { null },
                s.recipientLabel.trim().ifBlank { null },
            )
            .also { it.validate() }
    }
}
