package com.xmtx.im

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.result.contract.ActivityResultContracts

/** Grant only the camera output URI for this external activity's lifetime. */
internal class AvatarCameraContract : ActivityResultContracts.TakePicture() {
    override fun createIntent(context: Context,input: Uri): Intent=super.createIntent(context,input).apply {
        clipData=ClipData.newRawUri("拍摄照片",input)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    }
}
