package com.xmtx.im.client

/** Bounded per-service hysteresis matching V2QualityObserver. Times are monotonic milliseconds. */
class NetworkQualityObserver(private val serviceLimit:Int=64) {
    init {require(serviceLimit>0)}
    enum class Sample { Success, Timeout, TransportFailure, ServiceCooldown, LocalProcessing }
    enum class Quality { Normal, Degraded }
    private class State {
        val samples=ArrayDeque<Boolean>()
        var windowStarted:Long?=null
        var lastSampleAt:Long?=null
        var windowSampleCount=0
        var badWindows=0
        var healthyWindows=0
        var quality=Quality.Normal
    }
    private val services=mutableMapOf<String,State>()
    @Synchronized fun quality(service:String)=services[service]?.quality ?: Quality.Normal
    @Synchronized fun record(sample:Sample,service:String,nowMillis:Long):Quality {
        if(nowMillis<0 || sample !in setOf(Sample.Success,Sample.Timeout)) return quality(service)
        val state=services[service] ?: if(services.size<serviceLimit) State().also {services[service]=it} else return Quality.Normal
        if(state.lastSampleAt?.let {nowMillis<it}==true) return state.quality
        state.windowStarted?.let {start->
            val elapsed=nowMillis-start
            if(elapsed>=10_000) {
                if(elapsed<20_000 && state.windowSampleCount>=5 && state.samples.size>=5) {
                    val ratio=state.samples.count {it}.toDouble()/state.samples.size
                    when {
                        ratio>=0.3->{state.badWindows=minOf(2,state.badWindows+1);state.healthyWindows=0}
                        ratio<0.1->{state.healthyWindows=minOf(3,state.healthyWindows+1);state.badWindows=0}
                        else->{state.badWindows=0;state.healthyWindows=0}
                    }
                    if(state.badWindows>=2) state.quality=Quality.Degraded
                    if(state.healthyWindows>=3) state.quality=Quality.Normal
                } else {state.badWindows=0;state.healthyWindows=0}
                if(elapsed>=20_000) state.samples.clear()
                state.windowSampleCount=0;state.windowStarted=nowMillis
            }
        }
        if(state.windowStarted==null) state.windowStarted=nowMillis
        state.lastSampleAt=nowMillis
        state.windowSampleCount=minOf(20,state.windowSampleCount+1)
        state.samples.addLast(sample==Sample.Timeout)
        if(state.samples.size>20) state.samples.removeFirst()
        return state.quality
    }
}
