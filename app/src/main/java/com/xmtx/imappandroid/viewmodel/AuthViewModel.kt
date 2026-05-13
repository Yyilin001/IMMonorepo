package com.xmtx.imappandroid.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.auth.RestoreResult
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

sealed interface AuthPhase {
    data object Launching : AuthPhase
    data class SignedOut(val message: String? = null) : AuthPhase
    data class SignedIn(val user: AuthUser) : AuthPhase
}

data class AuthUiState(
    val phase: AuthPhase = AuthPhase.Launching,
    val email: String = "",
    val password: String = "",
    val isBusy: Boolean = false,
    val actionMessage: String? = null,
)

class AuthViewModel(
    private val gateway: IMSessionGateway,
) : ViewModel() {
    private val mutableState = MutableStateFlow(AuthUiState())
    val state: StateFlow<AuthUiState> = mutableState

    init {
        restoreSession()
    }

    fun updateEmail(email: String) {
        mutableState.update { it.copy(email = email, actionMessage = null) }
    }

    fun updatePassword(password: String) {
        mutableState.update { it.copy(password = password, actionMessage = null) }
    }

    fun login() {
        authenticate(register = false)
    }

    fun register() {
        authenticate(register = true)
    }

    fun signOut() {
        viewModelScope.launch {
            gateway.clearSession()
            mutableState.value = AuthUiState(phase = AuthPhase.SignedOut())
        }
    }

    private fun restoreSession() {
        viewModelScope.launch {
            mutableState.update { it.copy(phase = AuthPhase.Launching) }
            when (val result = gateway.restoreSession()) {
                is RestoreResult.Authenticated -> {
                    mutableState.update { it.copy(phase = AuthPhase.SignedIn(result.user), actionMessage = null) }
                }
                is RestoreResult.SignedOut -> {
                    mutableState.update { it.copy(phase = AuthPhase.SignedOut(result.message), actionMessage = result.message) }
                }
            }
        }
    }

    private fun authenticate(register: Boolean) {
        val email = state.value.email.trim()
        val password = state.value.password
        if (email.isEmpty() || password.isEmpty()) {
            mutableState.update { it.copy(actionMessage = "Email and password are required.") }
            return
        }

        viewModelScope.launch {
            mutableState.update { it.copy(isBusy = true, actionMessage = null) }
            runCatching {
                if (register) gateway.register(email, password) else gateway.login(email, password)
            }.onSuccess { user ->
                mutableState.update {
                    it.copy(
                        phase = AuthPhase.SignedIn(user),
                        isBusy = false,
                        password = "",
                        actionMessage = null,
                    )
                }
            }.onFailure { error ->
                mutableState.update {
                    it.copy(
                        phase = AuthPhase.SignedOut(error.message),
                        isBusy = false,
                        actionMessage = error.message ?: "Authentication failed.",
                    )
                }
            }
        }
    }
}
