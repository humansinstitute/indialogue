package com.wingmanbefree.indialogue

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun PrimaryRecordingButton(label: String, enabled: Boolean = true, action: () -> Unit) {
    Button(onClick = action, enabled = enabled, modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp),
        shape = RoundedCornerShape(50.dp), colors = ButtonDefaults.buttonColors(containerColor = Color(0xffff383c))) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ControlIcon(if (label == "New recording") "record" else "upload", Modifier.size(24.dp))
            Text(label, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
fun GroupedSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, Modifier.padding(start = 16.dp, top = 16.dp), style = MaterialTheme.typography.labelLarge, color = Color.Gray)
        Column(Modifier.fillMaxWidth().background(Color.White, RoundedCornerShape(12.dp)), content = content)
    }
}

@Composable
fun ConversationView(app: DialogueApp, visible: Boolean, permission: ((Boolean) -> Unit) -> Unit) {
    val controller = app.replies
    val foreground by app.foreground.collectAsState()
    val identity by app.identity.generation.collectAsState()
    val revision by app.revision.collectAsState()
    val jobs = remember(revision, identity) { controller.latest() }
    val scope = rememberCoroutineScope()
    var expanded by rememberSaveable { mutableStateOf(false) }
    val latest = replyPollingTarget(app.transfers.jobs.filter { app.identity.unlocked && it.destination.signer == app.identity.npub() }, jobs.map(::conversationKey).toSet())
    LaunchedEffect(latest?.id, latest?.state, visible, foreground, identity, expanded) {
        if (latest != null && visible && foreground && expanded) {
            while (true) {
                controller.refresh(latest, autoPlay = true)
                delay(20_000)
            }
        }
    }
    DisposableEffect(visible, foreground) {
        onDispose { controller.stop() }
    }
    if (jobs.isEmpty()) return
    Column(Modifier.fillMaxWidth().background(Color(0xfff2f2f7), RoundedCornerShape(16.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { expanded = !expanded; if (!expanded) controller.stop() }, modifier = Modifier.weight(1f)) {
                Text("Conversation ${if (expanded) "⌄" else "›"}", color = Color.Black, fontWeight = FontWeight.Bold)
            }
            TextButton(onClick = { scope.launch { jobs.forEach { controller.refresh(it) } } }, enabled = !controller.refreshing) { Text("Refresh") }
        }
        if (expanded) jobs.forEach { job ->
            val reply = controller.replies[controller.key(job)]
            val response = reply?.let { r -> responseTransfer(app.transfers.jobs, r.id) }
            val pendingRecording = reply?.let { r -> pendingResponse(app.recordings.value, app.transfers.jobs, r.id) }
            val responded = response?.state == "sent"
            val status = when {
                pendingRecording != null -> "Response pending · ${pendingRecording.speech}"
                response != null && !responded -> if (response.state == "failed") "Response failed · Retry" else "Response pending · ${response.state}"
                responded -> "Responded"
                reply != null -> if (controller.playing == reply.id) "Stop" else "Listen"
                job.state == "sent" -> "Sent · Waiting for reply"
                job.state == "failed" -> "Not sent · Retry"
                else -> "Not sent · Send"
            }
            val age = ((System.currentTimeMillis() - (app.recordings.value.firstOrNull { it.id == job.recordingId }?.created ?: System.currentTimeMillis())) / 1000).coerceAtLeast(0)
            Text(if (age < 60) "$age sec." else "${age / 60} min.", style = MaterialTheme.typography.bodySmall, color = Color.Gray)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = {
                    when {
                        response != null && response.state == "failed" -> app.retryUpload(response)
                        canSendConversation(job) -> app.retryUpload(job)
                        reply != null && !responded -> controller.listen(job, reply)
                    }
                }, enabled = (reply != null && !responded && response == null && pendingRecording == null) || canSendConversation(job) || response?.state == "failed",
                    modifier = Modifier.weight(1f).heightIn(min = 56.dp).semantics { contentDescription = status; stateDescription = status }, shape = RoundedCornerShape(10.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = if (reply != null) Color(0xff34a853) else Color.Gray,
                        disabledContainerColor = if (responded) Color(0xff34a853) else Color(0xffff9500), disabledContentColor = Color.White)) {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        ControlIcon(if (reply != null && controller.playing == reply.id) "stop" else "play", Modifier.size(28.dp))
                        Text(if (responded) "✓" else if (job.state == "sent" && reply == null) "◷" else if (job.state == "failed" || response?.state == "failed") "!" else "", Modifier.align(Alignment.BottomEnd), style = MaterialTheme.typography.labelSmall)
                    }
                }
                val route = controller.responseRoute(job, reply)
                Button(onClick = { permission { if (it && route != null) app.startCapture(route) else app.notice.value = "Microphone permission required to respond." } },
                    enabled = route != null && response == null && pendingRecording == null,
                    modifier = Modifier.weight(1f).heightIn(min = 56.dp).semantics { contentDescription = "Record response" }, shape = RoundedCornerShape(10.dp)) { ControlIcon("microphone", Modifier.size(28.dp)) }
            }
            var show by rememberSaveable(job.id) { mutableStateOf(false) }
            if (reply != null) {
                TextButton(onClick = { show = !show }) { Text(if (show) "Hide reply text" else "Show reply text") }
                if (show) Text(reply.body)
            }
            if (pendingRecording != null && pendingRecording.state != "recording") {
                Action("Send saved response audio") { app.upload(pendingRecording.id, audioOnly = true) }
            }
            job.notice?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
        if (controller.notice.isNotBlank()) Text(controller.notice, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
fun ControlIcon(kind: String, modifier: Modifier = Modifier, color: Color = Color.White) {
    Canvas(modifier) {
        val w = size.width; val h = size.height
        when (kind) {
            "play" -> drawPath(Path().apply { moveTo(w * .25f, h * .1f); lineTo(w * .85f, h * .5f); lineTo(w * .25f, h * .9f); close() }, color)
            "stop" -> drawRect(color, Offset(w * .2f, h * .2f), Size(w * .6f, h * .6f))
            "record" -> { drawCircle(color, w * .44f, style = Stroke(w * .09f)); drawCircle(color, w * .19f) }
            "microphone" -> {
                drawRoundRect(color, Offset(w * .38f, h * .06f), Size(w * .24f, h * .55f), androidx.compose.ui.geometry.CornerRadius(w * .12f))
                drawArc(color, 0f, 180f, false, Offset(w * .22f, h * .25f), Size(w * .56f, h * .5f), style = Stroke(w * .07f))
                drawLine(color, Offset(w * .5f, h * .72f), Offset(w * .5f, h * .94f), w * .07f)
                drawLine(color, Offset(w * .32f, h * .94f), Offset(w * .68f, h * .94f), w * .07f)
            }
            else -> { drawCircle(color, w * .44f, style = Stroke(w * .07f)); drawLine(color, Offset(w * .5f, h * .75f), Offset(w * .5f, h * .25f), w * .08f); drawLine(color, Offset(w * .3f, h * .45f), Offset(w * .5f, h * .25f), w * .08f); drawLine(color, Offset(w * .7f, h * .45f), Offset(w * .5f, h * .25f), w * .08f) }
        }
    }
}

@Composable
fun SettingsGroup(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().background(Color.White, RoundedCornerShape(16.dp)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
}
