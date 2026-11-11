package com.xmtx.im.client

import kotlinx.serialization.json.*

/** Persisted only with an actual drained HTTP task; legacy/recovered results may have no observation. */
data class ResourceBackgroundTransferObservation(val bodyBytesSent:Long,val bodyBytesReceived:Long,val statusCode:Int?,
    val failed:Boolean,val cancelled:Boolean) {
    init {require(bodyBytesSent>=0 && bodyBytesReceived>=0);require(statusCode==null || statusCode in 100..599)}
    fun payload()=buildJsonObject {
        put("sent",bodyBytesSent);put("received",bodyBytesReceived);statusCode?.let {put("status",it)}
        put("failed",failed);put("cancelled",cancelled)
    }
    companion object {
        fun from(metric:ResourceTransferMetric)=ResourceBackgroundTransferObservation(metric.bodyBytesSent,metric.bodyBytesReceived,metric.statusCode,metric.failed,metric.cancelled)
        fun decode(value:JsonObject)=ResourceBackgroundTransferObservation(value.getValue("sent").jsonPrimitive.long,value.getValue("received").jsonPrimitive.long,
            value["status"]?.jsonPrimitive?.int,value.getValue("failed").jsonPrimitive.boolean,value.getValue("cancelled").jsonPrimitive.boolean)
    }
}
/** No cross-process duration/retry inference and no payload-size substitution for missing body counters. */
data class ResourceBackgroundTransferMetric(val bodyBytesSent:Long?,val bodyBytesReceived:Long?,val statusCode:Int?,
    val completionObserved:Boolean,val transportFailed:Boolean?,val cancelled:Boolean?,val cancellationToPermitReleaseNanos:Long?) {
    init {require(bodyBytesSent==null || bodyBytesSent>=0);require(bodyBytesReceived==null || bodyBytesReceived>=0)
        require(statusCode==null || statusCode in 100..599);require(cancellationToPermitReleaseNanos==null || cancellationToPermitReleaseNanos>=0)
        require(completionObserved || bodyBytesSent==null && bodyBytesReceived==null && statusCode==null && transportFailed==null && cancelled==null)}
    companion object {
        fun from(observation:ResourceBackgroundTransferObservation?,cancellationToPermitReleaseNanos:Long?=null)=ResourceBackgroundTransferMetric(
            observation?.bodyBytesSent,observation?.bodyBytesReceived,observation?.statusCode,observation!=null,observation?.failed,observation?.cancelled,
            cancellationToPermitReleaseNanos?.takeIf {it>=0})
    }
}
