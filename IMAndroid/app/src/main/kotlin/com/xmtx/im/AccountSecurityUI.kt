package com.xmtx.im

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.xmtx.im.client.*
import kotlinx.coroutines.*

internal enum class PasswordFeedback { Editing, Completed, Failed, Unknown }
internal fun passwordUncertainty(action: PasswordAction) = if(action == PasswordAction.RecoveryCode)
    "恢复码可能已经启用。请保留刚才保存的副本，稍后用同一码重试；不要因请求中断而丢弃它。"
else "密码可能已经更新。请先用刚提交的新密码登录核验；若新密码被明确拒绝，再尝试原密码。关闭页面或取消请求不会撤回已经生效的修改。"
internal fun passwordFailure(error: PasswordLifecycleFailure) = when(error.reason) {
    PasswordLifecycleFailure.Reason.InvalidPassword -> "密码须为 12–1024 个 UTF-8 字节，不能包含空字符。"
    PasswordLifecycleFailure.Reason.InvalidRecoveryCode -> "恢复码须为保存时的 64 位小写十六进制字符，请检查是否完整。"
    PasswordLifecycleFailure.Reason.AuthenticationRejected -> "账号、当前密码或恢复码不正确，或已被更换。若上次请求中断，请先尝试用新密码登录。"
    PasswordLifecycleFailure.Reason.InvalidInput -> "请检查账号和恢复码格式；新密码不能与当前密码相同。"
    PasswordLifecycleFailure.Reason.RateLimited -> error.retryAfterSeconds?.let { "尝试过于频繁，请在 $it 秒后重试。" } ?: "尝试过于频繁，请稍后重试。"
}

/** Secrets intentionally use remember, never Saveable or ViewModel state. Only safe feedback survives rotation. */
@Composable internal fun AccountSecurityPage(active: Boolean, demo: Boolean = false, initialAction: PasswordAction = PasswordAction.Change,
    generateCode: () -> String, perform: suspend (PasswordAction, String, String?, String?, String?) -> Unit) {
    var action by rememberSaveable { mutableStateOf(initialAction) }
    var account by rememberSaveable { mutableStateOf("") }
    var current by remember { mutableStateOf("") }
    var next by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var savedCode by remember { mutableStateOf(false) }
    var useSavedCode by remember { mutableStateOf(false) }
    var feedback by rememberSaveable { mutableStateOf(PasswordFeedback.Editing) }
    var feedbackText by rememberSaveable { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var operation by remember { mutableStateOf<Job?>(null) }
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    fun clearSecrets() { current = ""; next = ""; confirmation = ""; code = ""; savedCode = false }
    DisposableEffect(lifecycle, active) {
        val observer = LifecycleEventObserver { _, event ->
            if(event == Lifecycle.Event.ON_STOP) { operation?.cancel(); clearSecrets() }
        }
        lifecycle.addObserver(observer)
        if(!active) { operation?.cancel(); clearSecrets() }
        onDispose { lifecycle.removeObserver(observer); operation?.cancel(); clearSecrets() }
    }
    BackHandler(busy) { /* A physical request may already have committed; keep the result visible. */ }
    val canSubmit = active && !busy && feedback != PasswordFeedback.Completed && account.isNotBlank() &&
        (action == PasswordAction.Recover || PasswordLifecycleClient.validPassword(current)) &&
        (action == PasswordAction.RecoveryCode || PasswordLifecycleClient.validPassword(next) && next == confirmation) &&
        (action == PasswordAction.Change || PasswordLifecycleClient.validRecoveryCode(code)) &&
        (action != PasswordAction.RecoveryCode || savedCode)
    LazyColumn(Modifier.fillMaxSize().imePadding().testTag("security-form"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if(demo) item { Text("离线演示 · 不会修改真实账号") }
        item { Text("安全操作", style = MaterialTheme.typography.titleMedium) }
        item { Column(Modifier.selectableGroup()) {
            PasswordAction.entries.forEach { option ->
                Row(Modifier.fillMaxWidth().selectable(selected = option == action, enabled = !busy, role = Role.RadioButton, onClick = {
                    if(option != action) {
                        action = option; clearSecrets(); useSavedCode = false
                        if(feedback != PasswordFeedback.Unknown) { feedback = PasswordFeedback.Editing; feedbackText = "" }
                    }
                }).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(selected = option == action, onClick = null, enabled = !busy)
                    Text(when(option) { PasswordAction.Change -> "修改密码"; PasswordAction.RecoveryCode -> "设置恢复码"; PasswordAction.Recover -> "找回账号" }, Modifier.padding(start = 12.dp))
                }
            }
        } }
        item { Text("请在仍记得密码时设置离线恢复码。密码和恢复码都丢失后，将无法找回账号。", style = MaterialTheme.typography.bodySmall) }
        item { OutlinedTextField(account, { account = it }, label = { Text("登录账号") }, singleLine = true, enabled = !busy, modifier = Modifier.fillMaxWidth().testTag("security-account")) }
        if(action != PasswordAction.Recover) item { SecuritySecretField(current, { current = it }, "当前密码", "security-current", !busy) }
        if(action != PasswordAction.RecoveryCode) {
            item { SecuritySecretField(next, { next = it }, "新密码", "security-next", !busy) }
            item { SecuritySecretField(confirmation, { confirmation = it }, "确认新密码", "security-confirmation", !busy) }
            item { Text("密码更新后所有设备都会退出登录，现有恢复码也会失效。", style = MaterialTheme.typography.bodySmall) }
        }
        if(action == PasswordAction.Recover) item { SecuritySecretField(code, { code = it }, "已保存的恢复码", "security-code", !busy) }
        if(action == PasswordAction.RecoveryCode) {
            item { Text("恢复码可以重置密码。请保存到安全的密码管理器或离线介质，不要分享给他人。启用新码后旧码失效。") }
            if(code.isEmpty() && !useSavedCode && feedback != PasswordFeedback.Unknown && feedback != PasswordFeedback.Completed) {
                item { Button(onClick = { try { code = generateCode(); savedCode = false; feedback = PasswordFeedback.Editing; feedbackText = "" } catch(_: Exception) { feedback = PasswordFeedback.Failed; feedbackText = "无法生成恢复码，请稍后重试。" } }, enabled = !busy) { Text("生成恢复码") } }
                item { TextButton(onClick = { useSavedCode = true }, enabled = !busy) { Text("使用已保存的恢复码重试") } }
            } else if(useSavedCode || code.isEmpty()) item { SecuritySecretField(code, { code = it; savedCode = false }, "已保存的恢复码", "security-code", !busy) }
            else item { SelectionContainer { Text(code, fontFamily = FontFamily.Monospace, modifier = Modifier.testTag("security-generated-code")) } }
            item { Row { Checkbox(savedCode, { savedCode = it }, enabled = !busy && PasswordLifecycleClient.validRecoveryCode(code), modifier = Modifier.testTag("security-saved")); Text("我已在应用外安全保存恢复码", Modifier.padding(top = 12.dp)) } }
            item { Text("离开页面、进入后台或旋转屏幕后，本页中的密码与恢复码会清除。", style = MaterialTheme.typography.bodySmall) }
        }
        item { Button(onClick = {
            if(!canSubmit) return@Button
            val submittedAction = action; val submittedAccount = account
            val submittedCurrent = current.takeIf { action != PasswordAction.Recover }
            val submittedNext = next.takeIf { action != PasswordAction.RecoveryCode }
            val submittedCode = code.takeIf { action != PasswordAction.Change }
            current = ""; next = ""; confirmation = ""; if(action != PasswordAction.RecoveryCode) code = ""
            // Save only uncertainty BEFORE starting a request, so recreation cannot imply failure or repeat it.
            feedback = PasswordFeedback.Unknown; feedbackText = passwordUncertainty(submittedAction); busy = true
            operation = scope.launch {
                try {
                    perform(submittedAction, submittedAccount, submittedCurrent, submittedNext, submittedCode)
                    currentCoroutineContext().ensureActive()
                    feedback = PasswordFeedback.Completed
                    feedbackText = if(submittedAction == PasswordAction.RecoveryCode) "恢复码已启用。请保留已保存的副本；旧恢复码已失效。"
                        else "密码已更新，全部设备已退出登录。请使用新密码登录，并重新设置恢复码。"
                } catch(e: CancellationException) { throw e }
                catch(e: PasswordLifecycleFailure) { feedback = PasswordFeedback.Failed; feedbackText = passwordFailure(e) }
                catch(e: Exception) { feedback = PasswordFeedback.Unknown; feedbackText = passwordUncertainty(submittedAction) }
                finally { busy = false; operation = null }
            }
        }, enabled = canSubmit, modifier = Modifier.testTag("security-submit")) { Text(if(action == PasswordAction.RecoveryCode) "启用恢复码" else "更新密码") } }
        if(busy) item { LinearProgressIndicator(Modifier.fillMaxWidth()); Text("正在处理…") }
        if(!busy && feedback != PasswordFeedback.Editing) item {
            Column { if(feedback == PasswordFeedback.Unknown) Text("结果尚未确认", style = MaterialTheme.typography.titleMedium)
                Text(feedbackText, modifier = Modifier.testTag("security-feedback")) }
        }
    }
}
@Composable private fun SecuritySecretField(value: String, change: (String) -> Unit, label: String, tag: String, enabled: Boolean) {
    OutlinedTextField(value, change, label = { Text(label) }, singleLine = true, enabled = enabled,
        visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth().testTag(tag))
}
