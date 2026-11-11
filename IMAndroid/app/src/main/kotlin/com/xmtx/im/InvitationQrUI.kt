package com.xmtx.im

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.xmtx.im.client.InvitationQr
import com.xmtx.im.client.InvitationSecret
import com.xmtx.im.platform.InvitationCameraSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable internal fun InvitationQrImage(secret: InvitationSecret, id: String) {
    val qr by produceState<InvitationQr?>(null,secret) {
        value = withContext(Dispatchers.Default) { InvitationQr.create(secret) }
    }
    qr?.let { code ->
        Canvas(Modifier.size(220.dp).background(Color.White).testTag("invite-qr/$id")
            .semantics { contentDescription = "群邀请二维码" }) {
            val scale = (minOf(size.width,size.height)/code.size).toInt().coerceAtLeast(1).toFloat()
            val left = ((size.width-code.size*scale)/2).toInt().toFloat()
            val top = ((size.height-code.size*scale)/2).toInt().toFloat()
            for (y in 0 until code.size) for (x in 0 until code.size) if(code.rows[y][x]=='1') {
                drawRect(Color.Black, Offset(left+x*scale,top+y*scale), Size(scale,scale))
            }
        }
    }
}

@Composable internal fun InvitationScanner(onDismiss: () -> Unit, found: (InvitationSecret) -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val latestDismiss by rememberUpdatedState(onDismiss)
    val latestFound by rememberUpdatedState(found)
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED) }
    var error by remember { mutableStateOf<String?>(null) }
    var alive by remember { mutableStateOf(true) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        if (alive) { granted = allowed; error = if(allowed) null else "未获得相机权限，可在系统设置中允许相机访问，或返回粘贴邀请链接。" }
    }
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event -> if(event==Lifecycle.Event.ON_STOP) { alive=false;latestDismiss() } }
        owner.lifecycle.addObserver(observer)
        onDispose { alive=false;owner.lifecycle.removeObserver(observer) }
    }
    Dialog(onDismissRequest=onDismiss) {
        Surface(shape=MaterialTheme.shapes.large) {
            Column(Modifier.padding(20.dp).testTag("invitation-scanner"),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                Text("扫描群邀请",style=MaterialTheme.typography.titleLarge)
                Text("将群邀请二维码放入画面，识别后可查看群信息。")
                if (granted && error==null) {
                    val view = remember { PreviewView(context).apply { implementationMode=PreviewView.ImplementationMode.COMPATIBLE } }
                    AndroidView(factory={view},modifier=Modifier.fillMaxWidth().height(280.dp).testTag("invitation-camera-preview"))
                    DisposableEffect(view,owner) {
                        val session = InvitationCameraSession(context,owner,view,
                            found={ if(alive) latestFound(it) }, unavailable={ if(alive) error="相机暂不可用，请返回后重试或粘贴邀请链接。" })
                        onDispose { session.close() }
                    }
                } else if(!granted) {
                    Text("扫描需要相机权限，画面仅在设备上识别。")
                    Button(onClick={ permission.launch(Manifest.permission.CAMERA) }) { Text("允许使用相机") }
                }
                error?.let { Text(it,color=MaterialTheme.colorScheme.error) }
                TextButton(onClick=onDismiss) { Text("返回粘贴链接") }
            }
        }
    }
}
