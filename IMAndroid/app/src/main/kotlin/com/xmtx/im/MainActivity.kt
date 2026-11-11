package com.xmtx.im

import android.os.Bundle
import android.content.Intent
import androidx.lifecycle.ViewModelProvider
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A restored task must not replay the system's original bearer Intent.
        receiveInvitation(intent, savedInstanceState == null)
        enableEdgeToEdge()
        setContent {
            val model: AppViewModel = viewModel()
            ApplicationContent(model)
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receiveInvitation(intent, true)
    }

    private fun receiveInvitation(incoming: Intent?, accept: Boolean) {
        val url = if (accept && incoming?.action == Intent.ACTION_VIEW) incoming.dataString else null
        // Retain neither external extras nor the bearer URL in Activity-owned saved/recreation state.
        setIntent(Intent(incoming ?: Intent(this, MainActivity::class.java)).apply {
            data = null
            clipData = null
            selector = null
            replaceExtras(null as Bundle?)
            if (action == Intent.ACTION_VIEW) action = Intent.ACTION_MAIN
        })
        if (url != null) ViewModelProvider(this)[AppViewModel::class.java].invitationInbox.offer(url)
    }
}

@Composable internal fun ApplicationContent(model: AppViewModel) {
    val colors = if (isSystemInDarkTheme()) darkColorScheme(primary = Color(0xFF86CDB6)) else lightColorScheme(
        primary = Color(0xFF176B52), onPrimary = Color.White, primaryContainer = Color(0xFFD8EDE5),
        background = Color(0xFFF8FAF8), secondaryContainer = Color(0xFFD8EDE5), surface = Color(0xFFF8FAF8), surfaceContainer = Color(0xFFF0F4F1), secondary = Color(0xFF56645D))
    MaterialTheme(colorScheme = colors) {
        val state by model.state.collectAsStateWithLifecycle()
        val owner = LocalLifecycleOwner.current
        DisposableEffect(owner, model) {
            val observer = LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_START) model.foreground(true)
                if (event == Lifecycle.Event.ON_STOP) model.foreground(false)
            }
            owner.lifecycle.addObserver(observer)
            model.foreground(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
            onDispose { owner.lifecycle.removeObserver(observer); model.foreground(false) }
        }
        IMApp(state, model)
    }
}
