package com.xmtx.imclientkit.persistence

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStoreFile
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import java.io.IOException
import java.util.UUID

interface DeviceIdentityStore {
    suspend fun currentDeviceID(): String
    suspend fun resetDeviceID()
}

class DataStoreDeviceIdentityStore(
    private val dataStore: DataStore<Preferences>,
) : DeviceIdentityStore {
    constructor(context: Context) : this(
        PreferenceDataStoreFactory.create(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
            produceFile = { context.preferencesDataStoreFile("imclientkit_device_identity.preferences_pb") },
        ),
    )

    override suspend fun currentDeviceID(): String {
        val existing = dataStore.data
            .catch { error ->
                if (error is IOException) emit(emptyPreferences()) else throw error
            }
            .map { preferences -> preferences[DEVICE_ID]?.takeIf { it.isNotBlank() } }
            .first()
        if (existing != null) return existing

        val generated = UUID.randomUUID().toString()
        dataStore.edit { preferences ->
            preferences[DEVICE_ID] = generated
        }
        return generated
    }

    override suspend fun resetDeviceID() {
        dataStore.edit { preferences ->
            preferences.remove(DEVICE_ID)
        }
    }

    private companion object {
        val DEVICE_ID = stringPreferencesKey("device_id")
    }
}

class InMemoryDeviceIdentityStore(
    initialDeviceID: String? = null,
) : DeviceIdentityStore {
    private var deviceID = initialDeviceID

    override suspend fun currentDeviceID(): String {
        val existing = deviceID
        if (!existing.isNullOrBlank()) return existing
        val generated = UUID.randomUUID().toString()
        deviceID = generated
        return generated
    }

    override suspend fun resetDeviceID() {
        deviceID = null
    }
}

