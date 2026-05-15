package com.xmtx.imclientkit.persistence

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStoreFile
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.networking.JsonConfiguration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.IOException
import androidx.datastore.preferences.core.PreferenceDataStoreFactory

data class TokenSnapshot(
    val accessToken: String,
    val refreshToken: String,
)

interface TokenStore {
    suspend fun load(): TokenSnapshot?
    suspend fun save(snapshot: TokenSnapshot)
    suspend fun clear()
}

interface UserSessionCache {
    suspend fun load(): AuthUser?
    suspend fun save(user: AuthUser)
    suspend fun clear()
}

class DataStoreTokenStore(
    private val dataStore: DataStore<Preferences>,
) : TokenStore {
    constructor(context: Context) : this(
        PreferenceDataStoreFactory.create(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
            produceFile = { context.preferencesDataStoreFile("imclientkit_tokens.preferences_pb") },
        ),
    )

    override suspend fun load(): TokenSnapshot? =
        dataStore.data
            .catch { error ->
                if (error is IOException) emit(emptyPreferences()) else throw error
            }
            .map { preferences ->
                val accessToken = preferences[ACCESS_TOKEN]
                val refreshToken = preferences[REFRESH_TOKEN]
                if (accessToken.isNullOrBlank() || refreshToken.isNullOrBlank()) {
                    null
                } else {
                    TokenSnapshot(accessToken, refreshToken)
                }
            }
            .first()

    override suspend fun save(snapshot: TokenSnapshot) {
        dataStore.edit { preferences ->
            preferences[ACCESS_TOKEN] = snapshot.accessToken
            preferences[REFRESH_TOKEN] = snapshot.refreshToken
        }
    }

    override suspend fun clear() {
        dataStore.edit { preferences ->
            preferences.remove(ACCESS_TOKEN)
            preferences.remove(REFRESH_TOKEN)
        }
    }

    private companion object {
        val ACCESS_TOKEN = stringPreferencesKey("access_token")
        val REFRESH_TOKEN = stringPreferencesKey("refresh_token")
    }
}

class DataStoreUserSessionCache(
    private val dataStore: DataStore<Preferences>,
    private val json: Json = JsonConfiguration.default,
) : UserSessionCache {
    constructor(context: Context) : this(
        PreferenceDataStoreFactory.create(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
            produceFile = { context.preferencesDataStoreFile("imclientkit_user.preferences_pb") },
        ),
    )

    override suspend fun load(): AuthUser? =
        dataStore.data
            .catch { error ->
                if (error is IOException) emit(emptyPreferences()) else throw error
            }
            .map { preferences ->
                preferences[USER_JSON]?.let { encoded ->
                    runCatching { json.decodeFromString<AuthUser>(encoded) }.getOrNull()
                }
            }
            .first()

    override suspend fun save(user: AuthUser) {
        dataStore.edit { preferences ->
            preferences[USER_JSON] = json.encodeToString(user)
        }
    }

    override suspend fun clear() {
        dataStore.edit { preferences ->
            preferences.remove(USER_JSON)
        }
    }

    private companion object {
        val USER_JSON = stringPreferencesKey("user_json")
    }
}

class InMemoryTokenStore(
    initialSnapshot: TokenSnapshot? = null,
) : TokenStore {
    private var snapshot: TokenSnapshot? = initialSnapshot

    override suspend fun load(): TokenSnapshot? = snapshot

    override suspend fun save(snapshot: TokenSnapshot) {
        this.snapshot = snapshot
    }

    override suspend fun clear() {
        snapshot = null
    }
}

class InMemoryUserSessionCache(
    initialUser: AuthUser? = null,
) : UserSessionCache {
    private var user: AuthUser? = initialUser

    override suspend fun load(): AuthUser? = user

    override suspend fun save(user: AuthUser) {
        this.user = user
    }

    override suspend fun clear() {
        user = null
    }
}
