package com.wingmanbefree.indialogue

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.ClickableText
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val app
        get() = application as DialogueApp

    private var permissionResult: ((Boolean) -> Unit)? = null
    private val permission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            permissionResult?.invoke(granted)
            permissionResult = null
        }
    private val notification =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        setContent {
            MaterialTheme(
                colorScheme =
                    lightColorScheme(primary = Color(0xff18392b), background = Color(0xfff8f3e9))
            ) {
                Surface(Modifier.fillMaxSize()) {
                    DialogueUI(
                        app,
                        { done ->
                            if (
                                ContextCompat.checkSelfPermission(
                                    this,
                                    Manifest.permission.RECORD_AUDIO,
                                ) == PackageManager.PERMISSION_GRANTED
                            )
                                done(true)
                            else {
                                permissionResult = done
                                permission.launch(Manifest.permission.RECORD_AUDIO)
                            }
                        },
                        ::shareFiles,
                    )
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        app.onForeground()
    }

    override fun onStop() {
        app.onBackground()
        super.onStop()
    }

    private fun shareFiles(files: List<File>) {
        val uris =
            ArrayList(files.map { FileProvider.getUriForFile(this, "$packageName.files", it) })
        startActivity(
            Intent.createChooser(
                Intent(Intent.ACTION_SEND_MULTIPLE)
                    .setType("*/*")
                    .putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                "Export recording and transcript",
            )
        )
    }

    fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= 33) notification.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}

internal fun secureKeyboardOptions(label: String, secure: Boolean) =
    KeyboardOptions(
        keyboardType =
            when {
                !secure -> KeyboardType.Text
                label.contains("PIN") -> KeyboardType.NumberPassword
                else -> KeyboardType.Password
            },
        autoCorrectEnabled = if (secure) false else null,
    )

@Composable
fun Field(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    secure: Boolean = false,
    multiline: Boolean = false,
) {
    OutlinedTextField(
        value,
        onChange,
        label = { Text(label) },
        modifier = Modifier.fillMaxWidth(),
        singleLine = !multiline,
        visualTransformation =
            if (secure) PasswordVisualTransformation()
            else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = secureKeyboardOptions(label, secure),
    )
}

@Composable
fun Action(label: String, enabled: Boolean = true, click: () -> Unit) {
    Button(onClick = click, enabled = enabled, modifier = Modifier.fillMaxWidth()) { Text(label) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DialogueUI(
    app: DialogueApp,
    permission: ((Boolean) -> Unit) -> Unit,
    share: (List<File>) -> Unit,
) {
    val recordings by app.recordings.collectAsState()
    val active by app.active.collectAsState()
    val pending by app.capturePending.collectAsState()
    val elapsed by app.elapsed.collectAsState()
    val levels by app.levels.collectAsState()
    val route by app.route.collectAsState()
    val notice by app.notice.collectAsState()
    val modelStatus by app.modelStatus.collectAsState()
    val revision by app.revision.collectAsState()
    val foreground by app.foreground.collectAsState()
    var screen by rememberSaveable { mutableStateOf("Capture") }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var unlockPrompt by remember { mutableStateOf(false) }
    var pin by remember { mutableStateOf("") }
    var unlockError by remember { mutableStateOf("") }
    val context = LocalContext.current
    LaunchedEffect(foreground) {
        if (!foreground) {
            pin = ""
            unlockPrompt = false
        } else if (app.identity.exists && !app.identity.unlocked) unlockPrompt = true
    }
    androidx.activity.compose.BackHandler(enabled = screen != "Capture") {
        screen = if (screen == "Menu") "Capture" else "Menu"
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (screen == "Capture") "In Dialogue" else screen) },
                navigationIcon = {
                    TextButton(
                        onClick = {
                            screen =
                                if (screen == "Capture") "Menu"
                                else if (screen == "Menu") "Capture" else "Menu"
                        }
                    ) {
                        Text(if (screen == "Capture") "Menu" else "Back")
                    }
                },
            )
        }
    ) { padding ->
        Column(
            Modifier.padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (notice.isNotBlank()) {
                Card {
                    Column(Modifier.padding(12.dp)) {
                        Text(notice)
                        TextButton(onClick = { app.notice.value = "" }) { Text("Dismiss notice") }
                    }
                }
            }
            // Reading the revision keeps non-flow vault, queue and settings changes visible.
            @Suppress("UNUSED_VARIABLE") val observed = revision
            when (screen) {
                "Capture" -> {
                    Text(
                        "Private audio. Your words, on your device.",
                        style = MaterialTheme.typography.titleLarge,
                    )
                    var inputs by remember { mutableStateOf(false) }
                    Action("Microphone preference: " + app.inputLabel(), active == null) {
                        permission {
                            if (it) inputs = true
                            else
                                app.notice.value =
                                    "Microphone permission denied. Enable it in Android Settings to record."
                        }
                    }
                    if (inputs) {
                        val devices =
                            (context.getSystemService(AudioManager::class.java)).getDevices(
                                AudioManager.GET_DEVICES_INPUTS
                            )
                        TextButton(
                            onClick = {
                                app.action { app.chooseInput(null) }
                                inputs = false
                            }
                        ) {
                            Text("System default")
                        }
                        devices.forEach { d ->
                            TextButton(
                                onClick = {
                                    app.action { app.chooseInput(d) }
                                    inputs = false
                                }
                            ) {
                                Text("${d.productName} · ${inputType(d.type)}")
                            }
                        }
                    }
                    Text("Actual input: $route")
                    if (active != null) {
                        Text(
                            "%02d:%02d".format(elapsed / 60000, (elapsed / 1000) % 60),
                            style = MaterialTheme.typography.displayMedium,
                        )
                        Canvas(
                            Modifier.fillMaxWidth().height(90.dp).semantics {
                                contentDescription =
                                    "Live recording level: " +
                                        if ((levels.lastOrNull() ?: 0f) > .4f) "Audio detected"
                                        else "Quiet"
                            }
                        ) {
                            val width = size.width / 40
                            levels.forEachIndexed { i, v ->
                                drawLine(
                                    Color(0xff18392b),
                                    Offset(
                                        (40 - levels.size + i) * width,
                                        size.height * (1 - v) / 2,
                                    ),
                                    Offset(
                                        (40 - levels.size + i) * width,
                                        size.height * (1 + v) / 2,
                                    ),
                                    width * .65f,
                                )
                            }
                        }
                        Action("Stop and save") { app.stopCapture() }
                    } else
                        Action("Start recording") {
                            permission {
                                if (it) app.startCapture()
                                else
                                    app.notice.value =
                                        "Microphone permission denied. Recordings are retained; enable permission in Android Settings."
                            }
                        }
                    Text(
                        "Recording continues with a microphone notification while backgrounded. Android may stop capture on interruption, input loss, force stop, reboot or low storage. Earlier saved segments are recovered.",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                "Menu" -> {
                    listOf(
                            "Recordings",
                            "Models",
                            "Vocabulary",
                            "Identity",
                            "NStack",
                            "NStack uploads",
                            "Settings",
                        )
                        .forEach { item -> Action(item) { screen = item } }
                    Text("In Dialogue 1.0.0 · native Android")
                }
                "Recordings" -> {
                    if (recordings.isEmpty()) Text("Your saved recordings will appear here.")
                    recordings.forEach { r ->
                        Card(
                            Modifier.fillMaxWidth().clickable {
                                selected = r.id
                                screen = "Recording"
                            }
                        ) {
                            Column(Modifier.padding(16.dp)) {
                                Text(r.title, style = MaterialTheme.typography.titleMedium)
                                Text("${r.state} · ${r.durationMs/1000}s · speech ${r.speech}")
                                r.notice?.let { Text(it) }
                            }
                        }
                    }
                }
                "Recording" -> {
                    val r = recordings.firstOrNull { it.id == selected }
                    if (r == null) Text("Recording unavailable.") else RecordingView(app, r, share)
                }
                "Models" -> {
                    Text(
                        "Speech: Vosk small English (US), Apache 2.0, 40 MiB download, about 300 MiB runtime. Other languages are not installed by this release."
                    )
                    Text(
                        if (app.models.speechReady) "Speech model installed and verified."
                        else "Speech model not installed."
                    )
                    Action("Download speech model") { app.download("speech") }
                    Action("Remove speech model") { app.removeModel("speech") }
                    HorizontalDivider()
                    Text(
                        "Optional cleanup: Qwen2.5 0.5B Instruct Q4_K_M, Apache 2.0, 469 MiB download. CPU inference requires about 1.5 GiB available RAM. Small models can change meaning; review every draft. No cloud fallback."
                    )
                    Text(
                        if (app.models.cleanupReady) "Cleanup model installed and verified."
                        else "Cleanup model not installed."
                    )
                    Action("Download cleanup model") { app.download("cleanup") }
                    Action("Remove cleanup model") { app.removeModel("cleanup") }
                    Action("Cancel model download") { app.cancelDownload() }
                    Text(modelStatus)
                    Text(
                        "Downloads contact Alpha Cephei or Hugging Face only when requested. Recording and installed-model inference work offline."
                    )
                }
                "Vocabulary" -> VocabularyView(app)
                "Identity" -> IdentityView(app)
                "NStack" -> NStackView(app)
                "NStack uploads" -> {
                    if (!app.transfers.readable)
                        Text("Upload ledger unreadable; original files retained.")
                    if (app.transfers.jobs.isEmpty())
                        Text("No uploads yet. Configure NStack or use Upload on a saved recording.")
                    app.transfers.jobs.reversed().forEach { j ->
                        Card {
                            Column(
                                Modifier.padding(12.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text(j.title)
                                Text(
                                    "${j.destination.workspaceLabel} → ${j.destination.channelLabel}"
                                )
                                Text(j.state)
                                j.notice?.let { Text(it) }
                                j.messageId?.let { Text("Message: $it") }
                                if (j.state !in setOf("sent", "cancelled")) {
                                    Action("Retry same snapshot") { app.retryUpload(j) }
                                    Action("Cancel local delivery") { app.cancelUpload(j) }
                                }
                            }
                        }
                    }
                    Text(
                        "Retry keeps original identity, content, destination and request ID. Cancellation cannot retract remotely committed messages or storage."
                    )
                }
                "Settings" -> SettingsView(app)
            }
        }
    }
    if (unlockPrompt) {
        AlertDialog(
            onDismissRequest = {
                pin = ""
                unlockPrompt = false
            },
            title = { Text("Unlock your identity") },
            text = {
                Column {
                    Text(
                        "Enter your PIN to resume eligible NStack deliveries, or continue locked to record."
                    )
                    Field("PIN", pin, { pin = it }, true)
                    if (unlockError.isNotBlank()) Text(unlockError)
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        try {
                            app.identity.unlock(pin)
                            pin = ""
                            unlockPrompt = false
                            unlockError = ""
                            app.refresh()
                            app.resume()
                        } catch (e: Exception) {
                            pin = ""
                            unlockError = e.message.orEmpty()
                        }
                    }
                ) {
                    Text("Unlock")
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        pin = ""
                        unlockPrompt = false
                    }
                ) {
                    Text("Continue locked")
                }
            },
        )
    }
}

@Composable
fun RecordingView(app: DialogueApp, r: Recording, share: (List<File>) -> Unit) {
    val active by app.active.collectAsState()
    val pending by app.capturePending.collectAsState()
    var title by remember(r.id) { mutableStateOf(r.title) }
    var edited by remember(r.id, r.review) { mutableStateOf(r.review) }
    var deleting by remember { mutableStateOf(false) }
    var selectedRange by remember { mutableStateOf<IntRange?>(null) }
    var replacement by remember { mutableStateOf("") }
    var teach by remember { mutableStateOf(false) }
    Field("Title", title, { title = it })
    Action("Save title", r.state != "recording") {
        app.action { app.update(r.id) { it.title = title.ifBlank { "Recording" } } }
    }
    Text("${r.state} · ${r.durationMs/1000}s · Transcription ${r.speech}")
    r.events.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
    r.notice?.let { Text(it) }
    Action(
        if (app.playingId == r.id) "Stop playback" else "Play full audio",
        active == null && !pending,
    ) {
        if (app.playingId == r.id) app.stopPlayback() else app.play(r.id)
    }
    Action("Share audio and transcript", active == null && !pending) { app.share(r.id, share) }
    Action(
        "Transcribe offline / Retry",
        r.speech !in setOf("queued", "running") && r.state != "recording",
    ) {
        app.retrySpeech(r.id)
    }
    if (r.speech in setOf("queued", "running"))
        Action("Cancel transcription") { app.cancelSpeech(r.id) }
    Text(
        "Reviewed transcript · tap a word to replace that occurrence",
        style = MaterialTheme.typography.titleMedium,
    )
    @Suppress("DEPRECATION")
    ClickableText(
        AnnotatedString(r.review.ifBlank { "No transcript yet." }),
        style =
            MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
        onClick = { offset ->
            Corrections.words(r.review)
                .firstOrNull { offset in it.range }
                ?.let {
                    selectedRange = it.range
                    replacement = it.value
                    teach = false
                }
        },
    )
    Field("Edit transcript", edited, { edited = it }, multiline = true)
    Action("Save transcript edit", r.state != "recording") {
        app.action { app.update(r.id) { it.editReview(edited) } }
    }
    Action("Apply saved vocabulary", r.state != "recording") {
        app.action { app.update(r.id) { it.editReview(Corrections.apply(it.review, app.rules)) } }
    }
    Text("Original transcript", style = MaterialTheme.typography.titleMedium)
    Text(r.raw ?: "No original transcript yet.")
    Action("Clean up on device", r.review.isNotBlank()) { app.cleanup(r.id) }
    if (app.cleaningId == r.id) Action("Cancel cleanup") { app.cancelCleanup() }
    r.draft?.let { draft ->
        Text(
            "Untrusted cleanup draft — review names, numbers and meaning.",
            style = MaterialTheme.typography.titleMedium,
        )
        Text(draft)
        Action("Accept cleanup draft") {
            app.action {
                app.update(r.id) {
                    it.acceptDraft()
                }
            }
        }
        Action("Reject cleanup draft") { app.action { app.update(r.id) { it.rejectDraft() } } }
    }
    Action("Upload / Retry upload", r.state == "saved") { app.upload(r.id) }
    if (r.autoDestination != null) {
        Text("Automatic delivery intent is retained for the destination selected at save time.")
        Action("Cancel automatic delivery intent") {
            app.action { app.update(r.id) { it.autoDestination = null } }
        }
    }
    Action("Delete recording") { deleting = true }
    if (deleting)
        AlertDialog(
            onDismissRequest = { deleting = false },
            title = { Text("Delete local recording?") },
            text = {
                Text(
                    "Permanently removes local audio, original and edited transcripts, drafts and finished local upload copies. Export important audio first. Remote workspace copies remain."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        app.delete(r.id)
                        deleting = false
                    }
                ) {
                    Text("Delete permanently")
                }
            },
            dismissButton = { TextButton(onClick = { deleting = false }) { Text("Keep") } },
        )
    if (selectedRange != null)
        AlertDialog(
            onDismissRequest = { selectedRange = null },
            title = { Text("Correct word") },
            text = {
                Column {
                    Field("Replacement", replacement, { replacement = it })
                    Row {
                        Checkbox(teach, { teach = it })
                        Text("Teach reusable vocabulary")
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        app.action {
                            val range = selectedRange!!
                            val heard = r.review.substring(range)
                            val text = Corrections.occurrence(r.review, range, replacement)
                            app.update(r.id) {
                                check(it.review == r.review) { "Transcript changed; select again." }
                                it.editReview(text)
                            }
                            if (teach)
                                app.saveRules(
                                    app.rules + Rule(heard = heard, replacement = replacement)
                                )
                        }
                        selectedRange = null
                    }
                ) {
                    Text("Apply")
                }
            },
            dismissButton = { TextButton(onClick = { selectedRange = null }) { Text("Cancel") } },
        )
}

@Composable
fun VocabularyView(app: DialogueApp) {
    var heard by remember { mutableStateOf("") }
    var replacement by remember { mutableStateOf("") }
    var editing by remember { mutableStateOf<String?>(null) }
    Text(
        "Whole words and phrases, punctuation and capitalization preserved. Replacements never cascade. No default corrections."
    )
    Field("Heard word or phrase", heard, { heard = it })
    Field("Replacement", replacement, { replacement = it })
    Action(if (editing == null) "Add correction" else "Save correction") {
        app.action {
            require(heard.isNotBlank() && replacement.isNotBlank())
            val rule = Rule(editing ?: uuid(), heard.trim(), replacement.trim())
            app.saveRules(app.rules.filter { it.id != rule.id } + rule)
            heard = ""
            replacement = ""
            editing = null
        }
    }
    app.rules.forEach { r ->
        Card {
            Column(Modifier.padding(12.dp)) {
                Text("${r.heard} → ${r.replacement}")
                TextButton(
                    onClick = {
                        heard = r.heard
                        replacement = r.replacement
                        editing = r.id
                    }
                ) {
                    Text("Edit")
                }
                TextButton(
                    onClick = { app.action { app.saveRules(app.rules.filter { it.id != r.id }) } }
                ) {
                    Text("Remove")
                }
            }
        }
    }
}

@Composable
fun IdentityView(app: DialogueApp) {
    val epoch by app.identity.generation.collectAsState()
    val unlocked = remember(epoch) { app.identity.unlocked }
    var nsec by remember { mutableStateOf("") }
    var pin by remember { mutableStateOf("") }
    var confirmPIN by remember { mutableStateOf("") }
    val foreground by app.foreground.collectAsState()
    LaunchedEffect(foreground) {
        if (!foreground) {
            pin = ""
            nsec = ""
            confirmPIN = ""
        }
    }
    var removing by remember { mutableStateOf(false) }
    Text(
        if (app.identity.exists) "Imported identity · " + if (unlocked) "unlocked" else "locked"
        else "No identity imported"
    )
    Text(
        "Your own Nostr identity signs NStack requests locally. The app publisher is a separate identity. Keep your own key backup; this vault is excluded from backups. PIN and plaintext key are never saved. Unlock lasts through background until Lock or process exit."
    )
    if (!app.identity.exists) {
        Field("Paste nsec", nsec, { nsec = it }, true)
        Field("Create PIN (4–12 digits)", pin, { pin = it }, true)
        Field("Confirm PIN", confirmPIN, { confirmPIN = it }, true)
        Action("Import identity") {
            app.action {
                try {
                    require(pin == confirmPIN) { "PINs do not match. Re-enter both PIN fields." }
                    app.identity.create(nsec, pin)
                    app.resume()
                } finally {
                    pin = ""
                    confirmPIN = ""
                    nsec = ""
                }
            }
        }
    } else {
        if (app.identity.unlocked) {
            Text(app.identity.npub())
            Action("Lock") { app.lock() }
        } else {
            Field("PIN", pin, { pin = it }, true)
            Action("Unlock") {
                app.action {
                    try {
                        app.identity.unlock(pin)
                        app.resume()
                    } finally {
                        pin = ""
                    }
                }
            }
        }
        Action("Remove identity") { removing = true }
    }
    if (removing)
        AlertDialog(
            onDismissRequest = { removing = false },
            title = { Text("Remove local identity?") },
            text = {
                Text(
                    "Keep your own nsec backup. Recordings remain. Queued deliveries stay bound to the original identity."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        app.action {
                            app.lock()
                            app.identity.remove()
                        }
                        removing = false
                    }
                ) {
                    Text("Remove")
                }
            },
            dismissButton = { TextButton(onClick = { removing = false }) { Text("Keep") } },
        )
}

@Composable
fun SettingsView(app: DialogueApp) {
    val context = LocalContext.current
    var enabled by remember { mutableStateOf(app.retention.enabled) }
    var days by remember { mutableStateOf(app.retention.days.toString()) }
    var confirm by remember { mutableStateOf(false) }
    Text("Automatically delete recordings", style = MaterialTheme.typography.titleLarge)
    Row {
        Switch(enabled, { enabled = it })
        Text(if (enabled) "Enabled" else "Disabled")
    }
    Field("Retention days (1–3650)", days, { days = it })
    Text(
        "Deletes local audio, metadata, original and edited transcripts, drafts and finished upload copies after elapsed days since creation. Uploaded workspace copies remain. Active capture, playback and unfinished jobs defer deletion. Checks run only while the app is open and idle."
    )
    Text(
        if (app.retention.enabled) "Saved: delete after ${app.retention.days} days."
        else "Saved: automatic deletion is off."
    )
    Action("Save retention") {
        app.action {
            require(Regex("[0-9]+").matches(days))
            val policy = Retention(enabled, days.toInt())
            if (policy.enabled) confirm = true else app.saveRetention(policy)
        }
    }
    if (confirm)
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("Apply deletion to existing recordings?") },
            text = {
                Text(
                    "Old eligible recordings will be permanently deleted now and at later safe checks. Export anything important first. No remote deletion is requested."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        app.action { app.saveRetention(Retention(enabled, days.toInt())) }
                        confirm = false
                    }
                ) {
                    Text("Enable deletion")
                }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
        )
    HorizontalDivider()
    Text(
        "Update in place with the same package and signing certificate. Uninstalling deletes your library and vault. Export important recordings using Share, and back up your Nostr key separately. Recordings and vault are excluded from Android backup. Android does not guarantee recording after force stop, reboot, storage exhaustion or OS termination."
    )
    Action("Enable recording notifications") { (context as? MainActivity)?.requestNotifications() }
}

@Composable
fun NStackView(app: DialogueApp) {
    val scope = rememberCoroutineScope()
    val epoch by app.identity.generation.collectAsState()
    val saved = app.transfers.destination
    val setup = remember {
        fun current() =
            AuthContext(
                if (app.identity.unlocked) app.identity.npub() else null,
                app.identity.generation.value,
            )
        fun api(requested: AuthContext) =
            NStackAPI(
                app.identity,
                {
                    check(
                        app.foreground.value &&
                            app.active.value == null &&
                            !app.capturePending.value &&
                            current() == requested &&
                            requested.npub != null
                    ) {
                        "Discovery context changed; retry in foreground with the same unlocked identity."
                    }
                },
            )
        NStackSetup(
            scope,
            ::current,
            { origin, auth -> api(auth).workspaces(origin) },
            { origin, w, auth -> api(auth).discover(origin, w) },
            saved,
        )
    }
    LaunchedEffect(epoch) { setup.refreshIdentity() }
    val state by setup.state.collectAsState()
    var prompt by remember { mutableStateOf(saved?.prompt ?: "Please review this recording.") }
    var automatic by remember { mutableStateOf(saved?.automatic ?: false) }
    Field("https://your-nstack.example", state.origin, setup::setOrigin)
    Text(
        if (app.identity.unlocked) app.identity.npub()
        else "Unlock your imported identity in Identity settings."
    )
    Action("Discover workspaces", app.identity.unlocked && !state.busy) { setup.discover() }
    Text("Storage workspace: " + (state.workspace?.label ?: "Choose below"))
    state.workspaces.forEach { w -> Action(w.label, !state.busy) { setup.selectWorkspace(w) } }
    Text("Message destination: " + (state.channel?.label ?: "Choose an existing channel or DM"))
    state.channels.forEach { c ->
        TextButton(onClick = { setup.selectChannel(c) }) { Text(c.label) }
    }
    Text(state.notice)
    if (state.busy) CircularProgressIndicator()
    Text("Optional receiving agent: " + state.recipientLabel.ifBlank { "None" })
    state.agents.forEach { a -> TextButton(onClick = { setup.selectAgent(a) }) { Text(a.label) } }
    TextButton(onClick = { setup.selectAgent(null) }) { Text("No receiving agent") }
    if (state.manualRecipient) {
        Field(
            "Canonical agent npub",
            state.recipient,
            { setup.manualRecipient(it, state.recipientLabel) },
        )
        Field("Agent label", state.recipientLabel, { setup.manualRecipient(state.recipient, it) })
    }
    Field("Custom prompt", prompt, { prompt = it }, multiline = true)
    Row {
        Checkbox(automatic, { automatic = it })
        Text("Automatically upload future recordings")
    }
    Text(
        "Existing recordings require Upload. Automatic delivery retains the destination selected at save time. Setup does not join or create channels."
    )
    Action("Save NStack setup", app.identity.unlocked && !state.busy) {
        app.action {
            app.transfers.save(setup.destination(prompt, automatic))
            app.notice.value =
                "NStack setup saved. Automatic delivery applies only to future recordings."
        }
    }
}
