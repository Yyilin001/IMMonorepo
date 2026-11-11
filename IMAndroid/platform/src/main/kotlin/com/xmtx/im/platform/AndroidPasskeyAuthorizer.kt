package com.xmtx.im.platform

import android.app.Activity
import android.content.MutableContextWrapper
import androidx.credentials.*
import androidx.credentials.exceptions.*
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex

/** Activity-scoped Credential Manager bridge. Call from a lifecycle-owned coroutine and discard on recreation. */
class AndroidPasskeyAuthorizer private constructor(private val activity:Activity,
    private val obtain:suspend (MutableContextWrapper,GetCredentialRequest)->GetCredentialResponse):PasskeyAuthorizing {
    constructor(activity:Activity):this(activity,{context,request->
        CredentialManager.create(context.applicationContext).getCredential(context,request)
    })
    private val mutex=Mutex()
    override suspend fun authorize(request:PasskeyAssertionRequest):PasskeyAssertionResult=withContext(Dispatchers.Main.immediate) {
        if(activity.isFinishing || activity.isDestroyed || !mutex.tryLock()) throw PasskeyFailure(PasskeyFailureReason.Unavailable)
        try {
            currentCoroutineContext().ensureActive()
            // The origin remains null: Credential Manager binds the Android app signing identity.
            val options=GetCredentialRequest(listOf(GetPublicKeyCredentialOption(request.webAuthnRequestJson())))
            val result=try {obtain(MutableContextWrapper(activity),options)}
            catch(_:GetCredentialCancellationException) {throw CancellationException("通行密钥授权已取消")}
            catch(_:NoCredentialException) {throw PasskeyFailure(PasskeyFailureReason.NoCredential)}
            catch(_:GetCredentialException) {throw PasskeyFailure(PasskeyFailureReason.Unavailable)}
            currentCoroutineContext().ensureActive()
            if(activity.isFinishing || activity.isDestroyed) throw CancellationException("通行密钥界面已关闭")
            val credential=result.credential as? PublicKeyCredential ?: throw PasskeyFailure(PasskeyFailureReason.InvalidResponse)
            PasskeyAssertionResult.fromWebAuthnJson(credential.authenticationResponseJson,request)
        } finally {mutex.unlock()}
    }
    internal companion object {
        fun testing(activity:Activity,obtain:suspend (MutableContextWrapper,GetCredentialRequest)->GetCredentialResponse)=AndroidPasskeyAuthorizer(activity,obtain)
    }
}
