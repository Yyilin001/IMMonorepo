package com.xmtx.im

import android.content.Context
import com.xmtx.im.client.DeviceId
import com.xmtx.im.client.UserId
import com.xmtx.im.platform.LocalStoreBootstrapper
import kotlinx.coroutines.runBlocking

/** Fixtures later adopted by AppViewModel must use the production installation binding. */
internal fun openBoundFixtureStore(context: Context, user: UserId, device: DeviceId) =
    runBlocking { LocalStoreBootstrapper(context).open(user, device) }
