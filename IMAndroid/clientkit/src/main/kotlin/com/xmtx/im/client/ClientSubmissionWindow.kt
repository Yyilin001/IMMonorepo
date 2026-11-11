package com.xmtx.im.client

/** Same five-second clock-skew allowance as Swift. Only newly minted local deadlines use it. */
object ClientSubmissionWindow {
    fun milliseconds(maximum: Long): Long { require(maximum > 5_000); return maximum - 5_000 }
    const val COMMAND_MILLISECONDS = 595_000L
    const val CONFIRMATION_MILLISECONDS = 115_000L
}
