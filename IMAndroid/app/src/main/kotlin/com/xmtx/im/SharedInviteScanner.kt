package com.xmtx.im

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

@Composable internal fun SharedInviteScanner(state: SharedAppState, model: SharedAppViewModel) {
    val context = LocalContext.current
    val media = remember { SharedImageController(context.applicationContext) }
    val image by media.state.collectAsState()
    val currentGeneration by rememberUpdatedState(state.generation)
    var launchedGeneration by remember { mutableStateOf<Long?>(null) }
    var feedback by remember { mutableStateOf<String?>(null) }
    val camera = rememberLauncherForActivityResult(ScanContract()) { result ->
        if (launchedGeneration == currentGeneration) result.contents?.let { model.previewInvite(it) }
        launchedGeneration = null
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted && launchedGeneration == currentGeneration) camera.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("扫描群邀请二维码").setBeepEnabled(false).setBarcodeImageEnabled(false))
        else { launchedGeneration = null; feedback = "相机权限未开启，可选择二维码图片" }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        val generation = launchedGeneration
        if (generation == currentGeneration && uri != null) media.scan(uri) { if (generation == currentGeneration) model.previewInvite(it) }
        launchedGeneration = null
    }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event -> if (event == androidx.lifecycle.Lifecycle.Event.ON_STOP) media.clear() }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer); media.close() }
    }
    Column {
        Button({ launchedGeneration = currentGeneration; feedback = null; permission.launch(android.Manifest.permission.CAMERA) }, enabled = !state.busy && !image.busy, modifier = Modifier.testTag("shared_scan_camera")) { Text("扫描邀请二维码") }
        TextButton({ launchedGeneration = currentGeneration; picker.launch("image/*") }, enabled = !state.busy && !image.busy, modifier = Modifier.testTag("shared_scan_image")) { Text("识别二维码图片") }
        (feedback ?: image.error)?.let { Text(it) }
    }
}
