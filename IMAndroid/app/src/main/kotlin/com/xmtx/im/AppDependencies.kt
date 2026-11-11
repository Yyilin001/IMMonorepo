package com.xmtx.im

import com.xmtx.im.client.AvatarReadGrant
import com.xmtx.im.client.AvatarDownloadedBytes
import com.xmtx.im.client.AvatarDownloader
import com.xmtx.im.client.AccountClient
import com.xmtx.im.client.AccountNetworkActivity
import com.xmtx.im.client.RealtimeConnection
import com.xmtx.im.client.MediaDownloadTarget
import com.xmtx.im.client.ResourceUploadBytes
import com.xmtx.im.platform.ManagedResourceFiles
import com.xmtx.im.platform.ManagedResourceUploadBytes
import java.io.File
import java.net.URI

/** Account composition boundary. Test certificates and alternate ports are supplied only by test callers. */
internal class AppDependencies(
    val account: (String)->AccountClient={AccountClient(it)},
    val networkActivity: ()->AccountNetworkActivity={AccountNetworkActivity()},
    val realtime: (String)->RealtimeConnection={RealtimeConnection(URI(it).host,7443,authorPresentations=true)},
    val backgroundRealtime: (String)->RealtimeConnection={RealtimeConnection(URI(it).host,7443)},
    val preferencesName: String="endpoint",
    val credentialsName: String="credentials",
    val download: (suspend (MediaDownloadTarget,File)->Unit)?=null,
    val avatarDownload: suspend (AvatarReadGrant)->AvatarDownloadedBytes=AvatarDownloader()::download,
    val uploadBytes: (ManagedResourceFiles)->ResourceUploadBytes={ManagedResourceUploadBytes(it)},
    val installationBindings: (android.app.Application)->com.xmtx.im.client.InstallationBindingStore = { com.xmtx.im.platform.KeystoreInstallationBindingStore(it) },
    val credentialStore: (android.app.Application,String)->com.xmtx.im.client.SecretStore = { app,name -> com.xmtx.im.platform.KeystoreCredentialStore(app,name) },
)
