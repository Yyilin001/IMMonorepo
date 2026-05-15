package com.xmtx.imappandroid

import com.xmtx.imappandroid.viewmodel.AuthPhase
import com.xmtx.imappandroid.viewmodel.AuthViewModel
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.auth.RestoreResult
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class AuthViewModelTests {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun restoreSessionMovesToSignedIn() = runTest {
        val user = AuthUser("user-1", "a@example.com")
        val gateway = FakeSessionGateway(restoreResult = RestoreResult.Authenticated(user))
        val viewModel = AuthViewModel(
            gateway,
        )

        assertEquals(AuthPhase.SignedIn(user), viewModel.state.value.phase)
        assertEquals("user-1", gateway.startedRuntimeUserID)
    }

    @Test
    fun loginSuccessMovesToSignedIn() = runTest {
        val user = AuthUser("user-1", "a@example.com", displayName = "Alice")
        val gateway = FakeSessionGateway(loginResult = Result.success(user))
        val viewModel = AuthViewModel(
            gateway,
        )

        viewModel.updateEmail("a@example.com")
        viewModel.updatePassword("secret")
        viewModel.login()

        assertEquals(AuthPhase.SignedIn(user), viewModel.state.value.phase)
        assertEquals("", viewModel.state.value.password)
        assertEquals("user-1", gateway.startedRuntimeUserID)
    }

    @Test
    fun loginFailureMovesToSignedOutWithMessage() = runTest {
        val viewModel = AuthViewModel(
            FakeSessionGateway(loginResult = Result.failure(IllegalStateException("bad credentials"))),
        )

        viewModel.updateEmail("a@example.com")
        viewModel.updatePassword("bad")
        viewModel.login()

        val phase = viewModel.state.value.phase
        assertTrue(phase is AuthPhase.SignedOut)
        assertEquals("bad credentials", viewModel.state.value.actionMessage)
    }
}
