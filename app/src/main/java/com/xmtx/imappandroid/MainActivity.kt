package com.xmtx.imappandroid

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.xmtx.imappandroid.di.AppContainer
import com.xmtx.imappandroid.ui.IMAppRoot
import com.xmtx.imappandroid.ui.theme.IMAppAndroidTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val container = AppContainer(applicationContext)
        setContent {
            IMAppAndroidTheme {
                IMAppRoot(container = container)
            }
        }
    }
}
