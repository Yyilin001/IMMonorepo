package com.xmtx.im.client

import okhttp3.*
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy

/** Preserves the caller's listener, including cache/failure callbacks. Never retains event arguments. */
internal class HTTPMetricsListener(private val delegate:EventListener,private val measurement:HTTPMeasurement):EventListener() {
    override fun callStart(call: Call) {
        delegate.callStart(call)
    }
    override fun proxySelectStart(call: Call, url: HttpUrl) {
        delegate.proxySelectStart(call, url)
    }
    override fun proxySelectEnd(call: Call, url: HttpUrl, proxies: List<Proxy>) {
        delegate.proxySelectEnd(call, url, proxies)
    }
    override fun dnsStart(call: Call, domainName: String) {
        measurement.begin(HTTPMeasurement.Phase.DNS)
        delegate.dnsStart(call, domainName)
    }
    override fun dnsEnd(call: Call, domainName: String, inetAddressList: List<InetAddress>) {
        measurement.end(HTTPMeasurement.Phase.DNS)
        delegate.dnsEnd(call, domainName, inetAddressList)
    }
    override fun connectStart(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy) {
        measurement.begin(HTTPMeasurement.Phase.Connect)
        delegate.connectStart(call, inetSocketAddress, proxy)
    }
    override fun secureConnectStart(call: Call) {
        measurement.begin(HTTPMeasurement.Phase.TLS)
        delegate.secureConnectStart(call)
    }
    override fun secureConnectEnd(call: Call, handshake: Handshake?) {
        measurement.end(HTTPMeasurement.Phase.TLS)
        delegate.secureConnectEnd(call, handshake)
    }
    override fun connectEnd(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy, protocol: Protocol?) {
        measurement.end(HTTPMeasurement.Phase.Connect)
        delegate.connectEnd(call, inetSocketAddress, proxy, protocol)
    }
    override fun connectFailed(call: Call, inetSocketAddress: InetSocketAddress, proxy: Proxy, protocol: Protocol?, ioe: IOException) {
        delegate.connectFailed(call, inetSocketAddress, proxy, protocol, ioe)
    }
    override fun connectionAcquired(call: Call, connection: Connection) {
        measurement.connected(connection.protocol())
        delegate.connectionAcquired(call, connection)
    }
    override fun connectionReleased(call: Call, connection: Connection) {
        delegate.connectionReleased(call, connection)
    }
    override fun requestHeadersStart(call: Call) {
        measurement.begin(HTTPMeasurement.Phase.Request)
        delegate.requestHeadersStart(call)
    }
    override fun requestHeadersEnd(call: Call, request: Request) {
        if(request.body==null) measurement.end(HTTPMeasurement.Phase.Request)
        delegate.requestHeadersEnd(call, request)
    }
    override fun requestBodyStart(call: Call) {
        delegate.requestBodyStart(call)
    }
    override fun requestBodyEnd(call: Call, byteCount: Long) {
        measurement.end(HTTPMeasurement.Phase.Request)
        delegate.requestBodyEnd(call, byteCount)
    }
    override fun requestFailed(call: Call, ioe: IOException) {
        delegate.requestFailed(call, ioe)
    }
    override fun responseHeadersStart(call: Call) {
        measurement.begin(HTTPMeasurement.Phase.Response)
        delegate.responseHeadersStart(call)
    }
    override fun responseHeadersEnd(call: Call, response: Response) {
        measurement.headers(response.code)
        delegate.responseHeadersEnd(call, response)
    }
    override fun responseBodyStart(call: Call) {
        delegate.responseBodyStart(call)
    }
    override fun responseBodyEnd(call: Call, byteCount: Long) {
        measurement.end(HTTPMeasurement.Phase.Response)
        delegate.responseBodyEnd(call, byteCount)
    }
    override fun responseFailed(call: Call, ioe: IOException) {
        delegate.responseFailed(call, ioe)
    }
    override fun callEnd(call: Call) {
        delegate.callEnd(call)
    }
    override fun callFailed(call: Call, ioe: IOException) {
        delegate.callFailed(call, ioe)
    }
    override fun canceled(call: Call) {
        delegate.canceled(call)
    }
    override fun satisfactionFailure(call: Call, response: Response) {
        delegate.satisfactionFailure(call, response)
    }
    override fun cacheHit(call: Call, response: Response) {
        delegate.cacheHit(call, response)
    }
    override fun cacheMiss(call: Call) {
        delegate.cacheMiss(call)
    }
    override fun cacheConditionalHit(call: Call, cachedResponse: Response) {
        delegate.cacheConditionalHit(call, cachedResponse)
    }
}
