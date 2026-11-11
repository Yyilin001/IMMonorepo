package com.xmtx.im

/** Aggregate app-owned cleanup state. Never contains credentials, targets or operation identities. */
enum class CredentialRecoveryUi { Empty, AwaitingRegistration, Pending, Paused, Unavailable, Checking }

internal fun credentialRecoveryNamespace(credentialsName: String, endpoint: String) = "$credentialsName\n$endpoint"
