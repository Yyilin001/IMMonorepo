package com.xmtx.im

import android.os.Bundle
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel

/** The App has a single business owner: Kotlin UI -> shared Swift SDK. */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        discardExternalBearer(intent)
        enableEdgeToEdge()
        setContent {
            val model: SharedAppViewModel = viewModel()
            SharedApplicationContent(model)
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        discardExternalBearer(intent)
    }
    private fun discardExternalBearer(incoming: Intent?) {
        setIntent(Intent(incoming ?: Intent(this, MainActivity::class.java)).apply {
            data = null; clipData = null; selector = null; replaceExtras(null as Bundle?)
            if (action == Intent.ACTION_VIEW) action = Intent.ACTION_MAIN
        })
    }
}
