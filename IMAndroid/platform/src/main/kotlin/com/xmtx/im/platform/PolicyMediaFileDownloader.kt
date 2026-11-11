package com.xmtx.im.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.ConnectionPool
import okhttp3.Dispatcher
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.File
import java.util.concurrent.TimeUnit

/** A download uses individually bound sockets/DNS; never changes the process default network. */
class PolicyMediaFileDownloader private constructor(private val preferences:suspend ()->ResourceDownloadNetworkPreferences,
    private val route:(String)->DownloadNetworkRoute?,private val base:OkHttpClient?) {
    constructor(context:Context,settings:ResourceDownloadNetworkSettings,http:OkHttpClient?=null):this(
        settings::downloadNetworkPreferences,androidDownloadRoute(context.applicationContext),http)
    internal constructor(preferences:suspend ()->ResourceDownloadNetworkPreferences,route:(String)->DownloadNetworkRoute?):this(preferences,route,null)
    suspend fun download(target:MediaDownloadTarget,destination:File)=withContext(Dispatchers.IO) {
        target.requireValid()
        val preferences=preferences()
        val automatic=currentCoroutineContext()[AutomaticResourceDownload]?.descriptor
        if(automatic!=null) {
            if(automatic.byteCount!=target.plan.expectedBytes || automatic.checksum!=target.plan.checksum) throw MediaReadFailure(MediaReadFailureReason.Integrity)
            if(!preferences.automaticDownloads.allows(automatic.contentType,automatic.byteCount)) throw ResourceDownloadPolicyRestricted()
        }
        val policy=preferences.constraints(automatic=automatic!=null)
        val selected=route(target.plan.url.toHttpUrl().host) ?: throw ResourceTransferFailure()
        if(!policy.allows(selected.state)) throw ResourceDownloadPolicyRestricted()
        currentCoroutineContext().ensureActive();target.requireValid()
        // Separate pools prevent reusing an unbound socket or a socket from another network.
        val client=selected.bind((base?.newBuilder() ?: OkHttpClient.Builder())
            .dispatcher(Dispatcher()).connectionPool(ConnectionPool(0,1,TimeUnit.SECONDS))).build()
        try {MediaFileDownloader(client).download(target,destination)}
        finally {client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
    }
}
internal class DownloadNetworkRoute(val state:ResourceDownloadNetworkState,val bind:(OkHttpClient.Builder)->OkHttpClient.Builder)
private fun androidDownloadRoute(context:Context):(String)->DownloadNetworkRoute? = {host->
    boundDownloadRoute(context,host,context.getSystemService(ConnectivityManager::class.java).activeNetwork)
}
/** The system worker passes JobParameters.network; null never falls back to the process default. */
internal fun boundDownloadRoute(context:Context,host:String,network:android.net.Network?):DownloadNetworkRoute? {
    val manager=context.getSystemService(ConnectivityManager::class.java)
    return run {
        // Loopback never traverses a billed network, and remains useful for local deployments without Internet.
        if(host in setOf("localhost","127.0.0.1","::1")) DownloadNetworkRoute(ResourceDownloadNetworkState(false,false,false)) {builder->
            builder.proxy(java.net.Proxy.NO_PROXY).dns(object:okhttp3.Dns {
                override fun lookup(hostname:String)=listOf(when(hostname) {
                    "localhost","127.0.0.1"->java.net.InetAddress.getByAddress(byteArrayOf(127,0,0,1))
                    "::1"->java.net.InetAddress.getByAddress(ByteArray(16).apply {this[15]=1})
                    else->throw java.net.UnknownHostException()
                })
            })
        }
        else network?.let {network->manager.getNetworkCapabilities(network)?.let {capabilities->
            if(!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) null
            else {
                val cellular=when {
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)->true
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)->false
                    else->null
                }
                val metered=!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                val constrained=metered && manager.restrictBackgroundStatus==ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
                DownloadNetworkRoute(ResourceDownloadNetworkState(cellular,metered,constrained)) {builder->
                    builder.socketFactory(network.socketFactory).dns(object:okhttp3.Dns {override fun lookup(hostname:String)=network.getAllByName(hostname).toList()})
                }
            }
        }}
    }
}

/** Automatic work never uses metered, cellular, opaque, or system-constrained networks. */
internal fun automaticDownloadNetworkAllowed(context:Context):Boolean =
    androidDownloadRoute(context.applicationContext)("automatic-network-probe.invalid")?.state
        ?.let {ResourceDownloadNetworkConstraints(false,false,false).allows(it)}==true

/** Presentation fact only; admission still rechecks the actual route before I/O. */
internal fun automaticDownloadWaitingReason(context:Context):ResourceTransferWaitingReason=
    if(androidDownloadRoute(context.applicationContext)("automatic-network-probe.invalid")==null) ResourceTransferWaitingReason.Network else ResourceTransferWaitingReason.NetworkPolicy
