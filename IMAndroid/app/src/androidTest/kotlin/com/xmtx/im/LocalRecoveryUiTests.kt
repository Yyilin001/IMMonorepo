package com.xmtx.im

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import com.xmtx.im.client.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class LocalRecoveryUiTests {
    @get:Rule val compose = createComposeRule()
    @Test fun unavailableDeviceProtectionOnlyOffersRetryAndLogout() {
        compose.setContent { MaterialTheme { LocalStoreUnavailableScreen(LocalStoreFailure.Reason.BindingUnavailable,
            LocalRecoveryUi(), {}, {}, { error("must not recover") }, {}, {}) } }
        compose.onNodeWithText("保留副本并重新同步").assertDoesNotExist()
        compose.onNodeWithText("重试打开").assertIsEnabled()
        compose.onNodeWithText("退出当前账号").assertIsEnabled()
    }
    @Test fun confirmationDoesNotSurviveSavedStateRestoration() {
        var recovery by mutableStateOf(LocalRecoveryUi(preview = LocalStoreRecoverySummary(4096, true)))
        var confirmations = 0
        val restore = StateRestorationTester(compose)
        restore.setContent { MaterialTheme { LocalStoreUnavailableScreen(LocalStoreFailure.Reason.BindingMismatch,
            recovery, {}, {}, {}, { confirmations++ }, { recovery = LocalRecoveryUi() }) } }
        compose.onNodeWithText("确认恢复").assertIsDisplayed()
        restore.emulateSavedInstanceStateRestore()
        compose.onNodeWithText("确认恢复").assertDoesNotExist()
        assertEquals(0, confirmations); assertNull(recovery.preview)
    }
    @Test fun malformedBindingRequiresReviewBeforeRecoveryAndExplainsReplacement() {
        var prepared = 0; var confirmed = 0
        var recovery by mutableStateOf(LocalRecoveryUi())
        compose.setContent { MaterialTheme { LocalStoreUnavailableScreen(LocalStoreFailure.Reason.BindingMalformed,
            recovery, {}, {}, { prepared++; recovery = LocalRecoveryUi(preview = LocalStoreRecoverySummary(0, false, true)) },
            { confirmed++ }, { recovery = LocalRecoveryUi() }) } }
        compose.onNodeWithText("保留副本并重新同步").performClick()
        assertEquals(1, prepared); assertEquals(0, confirmed)
        compose.onNodeWithText("将重建设备保护信息。", substring = true).assertIsDisplayed()
        compose.onNodeWithText("取消").performClick(); assertEquals(0, confirmed)
        compose.onNodeWithText("确认恢复").assertDoesNotExist()
    }

    @Test fun interruptedArchiveExplainsReuseAndRequiresAnotherConfirmation() {
        var recovery by mutableStateOf(LocalRecoveryUi())
        var confirmed = 0
        compose.setContent { MaterialTheme { LocalStoreUnavailableScreen(LocalStoreFailure.Reason.BindingInvalidated,
            recovery, {}, {}, { recovery = LocalRecoveryUi(preview = LocalStoreRecoverySummary(4096, true, true, true)) },
            { confirmed++; recovery = LocalRecoveryUi() }, { recovery = LocalRecoveryUi() }) } }
        compose.onNodeWithText("保留副本并重新同步").performClick()
        compose.onNodeWithText("将继续之前未完成的归档，已保留的副本会继续使用。", substring = true).assertIsDisplayed()
        compose.onNodeWithText("将重建设备保护信息。", substring = true).assertIsDisplayed()
        assertEquals(0, confirmed)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.openFileOutput("interrupted-recovery-dialog.png", 0).use {
            compose.onNode(isDialog()).captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        compose.onNodeWithText("确认恢复").performClick()
        assertEquals(1, confirmed)
    }

}
