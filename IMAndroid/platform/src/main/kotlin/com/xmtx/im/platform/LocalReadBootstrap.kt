package com.xmtx.im.platform

import com.xmtx.im.client.LocalAccountIdentity
import com.xmtx.im.client.LocalDatabaseIdentity
import com.xmtx.im.client.LocalInstallationBinding

/** Process-local evidence for an existing projection. Not a display lease or remote authorization.
 * Only its original bootstrapper can revalidate/open it; never serialize or restore this object.
 */
class LocalReadBootstrap internal constructor(
    val identity: LocalAccountIdentity,
    val databaseIdentity: LocalDatabaseIdentity,
    internal val binding: LocalInstallationBinding,
    internal val owner: Any,
)
