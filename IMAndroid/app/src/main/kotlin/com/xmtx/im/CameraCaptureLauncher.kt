package com.xmtx.im

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

/** CAMERA is declared for scanning, so external ACTION_IMAGE_CAPTURE also needs its permission. */
@Composable internal fun rememberCameraCaptureLauncher(result: (Boolean) -> Unit): (Uri) -> Unit {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val latestResult by rememberUpdatedState(result)
    var waiting by remember { mutableStateOf<Uri?>(null) }
    val capture = rememberLauncherForActivityResult(AvatarCameraContract()) { latestResult(it) }
    fun launch(uri: Uri) {
        if (!owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) { latestResult(false); return }
        try { capture.launch(uri) } catch (_: Exception) { latestResult(false) }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val uri = waiting ?: return@rememberLauncherForActivityResult
        waiting = null
        if (granted) launch(uri)
        else {
            latestResult(false)
            if(!granted) Toast.makeText(context,"未获得相机权限，可在系统设置中允许访问或选择已有图片",Toast.LENGTH_LONG).show()
        }
    }
    DisposableEffect(owner) {
        fun abandon() { if(waiting!=null) { waiting=null;latestResult(false) } }
        val observer=LifecycleEventObserver { _,event -> if(event==Lifecycle.Event.ON_STOP) abandon() }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer);abandon() }
    }
    return { uri ->
        if(ContextCompat.checkSelfPermission(context,Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED) launch(uri)
        else if(waiting==null) {
            waiting=uri
            try { permission.launch(Manifest.permission.CAMERA) } catch (_: Exception) { waiting=null;latestResult(false) }
        }
    }
}
