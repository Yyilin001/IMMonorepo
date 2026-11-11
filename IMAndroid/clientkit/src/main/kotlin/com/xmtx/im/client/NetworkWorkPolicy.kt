package com.xmtx.im.client

/** Pure retry decisions, matching Swift V2NetworkWorkPolicy. This value never retries or stores work. */
data class NetworkWorkPolicy(val maximumAttempts:Int,val totalBudgetMillis:Long,val transmissionBudgetMillis:Long) {
    init {require(maximumAttempts>0 && totalBudgetMillis>0 && transmissionBudgetMillis>0)}
    /** Retry-After is a floor; jitter is added after it, and must fit strictly inside the original budget. */
    fun nextAttempt(nowMillis:Long,startedAtMillis:Long,attemptsCompleted:Int,randomUnit:Double,serverRetryNotBeforeMillis:Long?=null):Long? {
        if(attemptsCompleted>=maximumAttempts) return null
        val deadline=if(startedAtMillis>Long.MAX_VALUE-totalBudgetMillis) Long.MAX_VALUE else startedAtMillis+totalBudgetMillis
        val base=maxOf(nowMillis,serverRetryNotBeforeMillis ?: nowMillis)
        if(base>=deadline) return null
        val remaining=(deadline-base).let {if(it<0) Long.MAX_VALUE else it}
        val ceiling=minOf(30_000L,500L shl (attemptsCompleted.toLong()-1).coerceIn(0,16).toInt())
        val window=minOf(ceiling,remaining)
        val random=if(randomUnit.isNaN()) 0.0 else randomUnit.coerceIn(0.0,1.0)
        val next=base+(window*random).toLong()
        return next.takeIf {it<deadline}
    }
    companion object {
        val InteractiveRead=NetworkWorkPolicy(2,10_000,10_000)
        val CommandRecovery=NetworkWorkPolicy(5,60_000,15_000)
        fun acceptedResultPollDelayMillis(attempt:Int,serverDelayMillis:Long?=null)=
            maxOf(longArrayOf(2000,5000,10_000,30_000)[attempt.coerceIn(0,3)],serverDelayMillis ?: 0)
        fun resourceProcessingPollDelayMillis(attempt:Int,serverDelayMillis:Long?=null)=
            maxOf(longArrayOf(500,500,500,500,750,1000,2000,5000,10_000,30_000)[attempt.coerceIn(0,9)],serverDelayMillis ?: 0)
    }
}
