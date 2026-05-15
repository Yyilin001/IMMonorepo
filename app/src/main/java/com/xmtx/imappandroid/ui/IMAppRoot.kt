package com.xmtx.imappandroid.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.xmtx.imappandroid.di.AppContainer
import com.xmtx.imappandroid.session.IMSessionGateway
import com.xmtx.imappandroid.viewmodel.AuthPhase
import com.xmtx.imappandroid.viewmodel.AuthUiState
import com.xmtx.imappandroid.viewmodel.AuthViewModel
import com.xmtx.imappandroid.viewmodel.ConversationDetailUiState
import com.xmtx.imappandroid.viewmodel.ConversationDetailViewModel
import com.xmtx.imappandroid.viewmodel.ConversationListUiState
import com.xmtx.imappandroid.viewmodel.ConversationListViewModel
import com.xmtx.imappandroid.viewmodel.ConversationManagementUiState
import com.xmtx.imappandroid.viewmodel.ConversationManagementViewModel
import com.xmtx.imappandroid.viewmodel.ContactsUiState
import com.xmtx.imappandroid.viewmodel.ContactsViewModel
import com.xmtx.imclientkit.auth.AuthUser
import com.xmtx.imclientkit.features.im.IMConnectionStatus
import com.xmtx.imclientkit.features.im.IMConversation
import com.xmtx.imclientkit.features.im.IMMessageDeliveryState

@Composable
fun IMAppRoot(container: AppContainer) {
    val gateway = container.sessionGateway
    val authViewModel: AuthViewModel = viewModel(
        factory = viewModelFactory {
            initializer { AuthViewModel(gateway) }
        },
    )
    val authState by authViewModel.state.collectAsState()

    when (val phase = authState.phase) {
        AuthPhase.Launching -> LoadingScreen()
        is AuthPhase.SignedOut -> LoginScreen(
            state = authState,
            message = phase.message ?: authState.actionMessage,
            onEmailChange = authViewModel::updateEmail,
            onPasswordChange = authViewModel::updatePassword,
            onLogin = authViewModel::login,
            onRegister = authViewModel::register,
        )
        is AuthPhase.SignedIn -> SignedInScreen(
            user = phase.user,
            gateway = gateway,
            onSignOut = authViewModel::signOut,
        )
    }
}

@Composable
private fun LoadingScreen() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator()
    }
}

@Composable
private fun LoginScreen(
    state: AuthUiState,
    message: String?,
    onEmailChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onLogin: () -> Unit,
    onRegister: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text("IM Android", fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(24.dp))
        OutlinedTextField(
            value = state.email,
            onValueChange = onEmailChange,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            label = { Text("Email") },
        )
        Spacer(Modifier.height(12.dp))
        OutlinedTextField(
            value = state.password,
            onValueChange = onPasswordChange,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            label = { Text("Password") },
        )
        if (message != null) {
            Spacer(Modifier.height(12.dp))
            Text(message)
        }
        Spacer(Modifier.height(20.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                enabled = !state.isBusy,
                onClick = onLogin,
            ) {
                Text("Login")
            }
            OutlinedButton(
                enabled = !state.isBusy,
                onClick = onRegister,
            ) {
                Text("Register")
            }
        }
    }
}

@Composable
private fun SignedInScreen(
    user: AuthUser,
    gateway: IMSessionGateway,
    onSignOut: () -> Unit,
) {
    var selectedConversation by remember { mutableStateOf<IMConversation?>(null) }
    var showingContacts by remember { mutableStateOf(false) }
    var showingSettings by remember { mutableStateOf(false) }
    val listViewModel: ConversationListViewModel = viewModel(
        factory = viewModelFactory {
            initializer { ConversationListViewModel(gateway) }
        },
    )
    val detailViewModel: ConversationDetailViewModel = viewModel(
        factory = viewModelFactory {
            initializer { ConversationDetailViewModel(gateway) }
        },
    )
    val contactsViewModel: ContactsViewModel = viewModel(
        factory = viewModelFactory {
            initializer { ContactsViewModel(gateway) }
        },
    )
    val managementViewModel: ConversationManagementViewModel = viewModel(
        factory = viewModelFactory {
            initializer { ConversationManagementViewModel(gateway) }
        },
    )

    if (selectedConversation == null) {
        val listState by listViewModel.state.collectAsState()
        val contactsState by contactsViewModel.state.collectAsState()
        val managementState by managementViewModel.state.collectAsState()
        LaunchedEffect(user.id) {
            listViewModel.loadConversations()
            contactsViewModel.loadContacts()
        }
        if (showingContacts) {
            ContactsScreen(
                user = user,
                state = contactsState,
                managementState = managementState,
                onEmailChange = contactsViewModel::updateEmail,
                onMessageChange = contactsViewModel::updateMessage,
                onRemarkChange = contactsViewModel::updateRemark,
                onSendRequest = contactsViewModel::sendRequest,
                onAccept = contactsViewModel::accept,
                onDecline = contactsViewModel::decline,
                onTitleChange = managementViewModel::updateTitle,
                onMemberEmailsChange = managementViewModel::updateMemberEmails,
                onCreateGroup = managementViewModel::createGroup,
                onRefresh = contactsViewModel::loadContacts,
                onBack = { showingContacts = false },
            )
        } else {
            ConversationListScreen(
                user = user,
                state = listState,
                onRefresh = listViewModel::loadConversations,
                onContacts = { showingContacts = true },
                onSelect = {
                    selectedConversation = it
                    showingSettings = false
                },
                onSignOut = onSignOut,
            )
        }
    } else {
        val conversation = selectedConversation
        val detailState by detailViewModel.state.collectAsState()
        val managementState by managementViewModel.state.collectAsState()
        LaunchedEffect(conversation?.id) {
            conversation?.let {
                detailViewModel.openConversation(it.id)
                managementViewModel.loadMembers()
            }
        }
        ConversationDetailScreen(
            title = conversation?.displayTitle ?: "Conversation",
            state = detailState,
            managementState = managementState,
            showingSettings = showingSettings,
            onDraftChange = detailViewModel::updateDraft,
            onSend = detailViewModel::sendText,
            onTitleChange = managementViewModel::updateTitle,
            onMemberEmailsChange = managementViewModel::updateMemberEmails,
            onSaveTitle = managementViewModel::saveTitle,
            onAddMembers = managementViewModel::addMembers,
            onTogglePinned = managementViewModel::togglePinned,
            onToggleMuted = managementViewModel::toggleMuted,
            onClear = managementViewModel::clearConversation,
            onLeave = {
                managementViewModel.leaveConversation()
                selectedConversation = null
            },
            onDelete = {
                managementViewModel.deleteConversation()
                selectedConversation = null
            },
            onToggleSettings = { showingSettings = !showingSettings },
            onBack = { selectedConversation = null },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConversationListScreen(
    user: AuthUser,
    state: ConversationListUiState,
    onRefresh: () -> Unit,
    onContacts: () -> Unit,
    onSelect: (IMConversation) -> Unit,
    onSignOut: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(user.preferredDisplayName, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                actions = {
                    Text(
                        text = state.connectionStatus.label,
                        modifier = Modifier.padding(end = 8.dp),
                    )
                    TextButton(onClick = onContacts) { Text("Contacts") }
                    TextButton(onClick = onRefresh) { Text("Refresh") }
                    TextButton(onClick = onSignOut) { Text("Sign out") }
                },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            when {
                state.isLoading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                state.conversations.isEmpty() -> Text(
                    text = state.message ?: "No conversations.",
                    modifier = Modifier.align(Alignment.Center),
                )
                else -> LazyColumn {
                    items(state.conversations, key = { it.id }) { conversation ->
                        ListItem(
                            headlineContent = {
                                Text(conversation.displayTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            },
                            supportingContent = {
                                Text(
                                    conversation.lastMessagePreview,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            },
                            trailingContent = {
                                if (conversation.unreadCount > 0) {
                                    Text(conversation.unreadCount.toString(), fontWeight = FontWeight.Bold)
                                }
                            },
                            modifier = Modifier.clickable { onSelect(conversation) },
                        )
                        HorizontalDivider()
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ContactsScreen(
    user: AuthUser,
    state: ContactsUiState,
    managementState: ConversationManagementUiState,
    onEmailChange: (String) -> Unit,
    onMessageChange: (String) -> Unit,
    onRemarkChange: (String) -> Unit,
    onSendRequest: () -> Unit,
    onAccept: (String) -> Unit,
    onDecline: (String) -> Unit,
    onTitleChange: (String) -> Unit,
    onMemberEmailsChange: (String) -> Unit,
    onCreateGroup: () -> Unit,
    onRefresh: () -> Unit,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Contacts") },
                navigationIcon = { TextButton(onClick = onBack) { Text("Back") } },
                actions = { TextButton(onClick = onRefresh) { Text("Refresh") } },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            item {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Add contact", fontWeight = FontWeight.Bold)
                    OutlinedTextField(state.email, onEmailChange, Modifier.fillMaxWidth(), singleLine = true, label = { Text("Email") })
                    OutlinedTextField(state.messageText, onMessageChange, Modifier.fillMaxWidth(), singleLine = true, label = { Text("Message") })
                    OutlinedTextField(state.remark, onRemarkChange, Modifier.fillMaxWidth(), singleLine = true, label = { Text("Remark") })
                    Button(onClick = onSendRequest, enabled = state.email.isNotBlank()) { Text("Send request") }
                    HorizontalDivider()
                    Text("Create group", fontWeight = FontWeight.Bold)
                    OutlinedTextField(managementState.title, onTitleChange, Modifier.fillMaxWidth(), singleLine = true, label = { Text("Title") })
                    OutlinedTextField(managementState.memberEmails, onMemberEmailsChange, Modifier.fillMaxWidth(), label = { Text("Member emails") })
                    Button(onClick = onCreateGroup, enabled = managementState.memberEmails.isNotBlank()) { Text("Create") }
                    state.message?.let { Text(it) }
                    Text("Signed in as ${user.preferredDisplayName}")
                }
            }
            item { Text("Incoming requests", Modifier.padding(16.dp), fontWeight = FontWeight.Bold) }
            items(state.incomingRequests, key = { it.id }) { request ->
                ListItem(
                    headlineContent = { Text(request.peerDisplayName(user.id)) },
                    supportingContent = { Text(request.message ?: "Contact request") },
                    trailingContent = {
                        Row {
                            TextButton(onClick = { onAccept(request.id) }) { Text("Accept") }
                            TextButton(onClick = { onDecline(request.id) }) { Text("Decline") }
                        }
                    },
                )
                HorizontalDivider()
            }
            item { Text("Contacts", Modifier.padding(16.dp), fontWeight = FontWeight.Bold) }
            items(state.contacts, key = { it.id }) { contact ->
                ListItem(
                    headlineContent = { Text(contact.preferredDisplayName) },
                    supportingContent = { Text(contact.email) },
                )
                HorizontalDivider()
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConversationDetailScreen(
    title: String,
    state: ConversationDetailUiState,
    managementState: ConversationManagementUiState,
    showingSettings: Boolean,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onTitleChange: (String) -> Unit,
    onMemberEmailsChange: (String) -> Unit,
    onSaveTitle: () -> Unit,
    onAddMembers: () -> Unit,
    onTogglePinned: () -> Unit,
    onToggleMuted: () -> Unit,
    onClear: () -> Unit,
    onLeave: () -> Unit,
    onDelete: () -> Unit,
    onToggleSettings: () -> Unit,
    onBack: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text("Back") }
                },
                actions = {
                    TextButton(onClick = onToggleSettings) { Text("Manage") }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            if (showingSettings) {
                ConversationManagementPanel(
                    state = managementState,
                    onTitleChange = onTitleChange,
                    onMemberEmailsChange = onMemberEmailsChange,
                    onSaveTitle = onSaveTitle,
                    onAddMembers = onAddMembers,
                    onTogglePinned = onTogglePinned,
                    onToggleMuted = onToggleMuted,
                    onClear = onClear,
                    onLeave = onLeave,
                    onDelete = onDelete,
                )
                HorizontalDivider()
            }
            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                when {
                    state.isLoading -> CircularProgressIndicator(Modifier.align(Alignment.Center))
                    state.messages.isEmpty() -> Text(
                        text = state.message ?: "No messages.",
                        modifier = Modifier.align(Alignment.Center),
                    )
                    else -> LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        reverseLayout = false,
                    ) {
                        items(state.messages, key = { it.id }) { message ->
                            Column(Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                                Text(
                                    text = "#${message.serverSequence ?: "-"} ${message.deliveryState.label}",
                                    fontWeight = FontWeight.Bold,
                                )
                                Text(message.previewText)
                            }
                            HorizontalDivider()
                        }
                    }
                }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = state.draftText,
                    onValueChange = onDraftChange,
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    label = { Text("Message") },
                )
                Button(onClick = onSend, enabled = state.draftText.isNotBlank()) {
                    Text("Send")
                }
            }
        }
    }
}

@Composable
private fun ConversationManagementPanel(
    state: ConversationManagementUiState,
    onTitleChange: (String) -> Unit,
    onMemberEmailsChange: (String) -> Unit,
    onSaveTitle: () -> Unit,
    onAddMembers: () -> Unit,
    onTogglePinned: () -> Unit,
    onToggleMuted: () -> Unit,
    onClear: () -> Unit,
    onLeave: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(state.title, onTitleChange, Modifier.fillMaxWidth(), singleLine = true, label = { Text("Title") })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = onSaveTitle) { Text("Save") }
            OutlinedButton(onClick = onTogglePinned) { Text(if (state.selectedConversation?.summary?.isPinned == true) "Unpin" else "Pin") }
            OutlinedButton(onClick = onToggleMuted) { Text(if (state.selectedConversation?.summary?.isMuted == true) "Unmute" else "Mute") }
        }
        OutlinedTextField(state.memberEmails, onMemberEmailsChange, Modifier.fillMaxWidth(), label = { Text("Member emails") })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = onAddMembers, enabled = state.memberEmails.isNotBlank()) { Text("Add") }
            OutlinedButton(onClick = onClear) { Text("Clear") }
            OutlinedButton(onClick = onLeave) { Text("Leave") }
            OutlinedButton(onClick = onDelete) { Text("Delete") }
        }
        val members = state.selectedConversation?.members.orEmpty()
        if (members.isNotEmpty()) {
            Text(members.joinToString { it.preferredDisplayName }, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        state.statusMessage?.let { Text(it) }
    }
}

private val IMConnectionStatus.label: String
    get() = when (this) {
        IMConnectionStatus.Disconnected -> "offline"
        IMConnectionStatus.Connecting -> "connecting"
        IMConnectionStatus.Connected -> "online"
        IMConnectionStatus.Failed -> "reconnecting"
    }

private val IMMessageDeliveryState.label: String
    get() = when (this) {
        IMMessageDeliveryState.Queued -> "queued"
        IMMessageDeliveryState.Sending -> "sending"
        IMMessageDeliveryState.Sent -> "sent"
        IMMessageDeliveryState.Received -> "received"
        IMMessageDeliveryState.Unknown -> "unknown"
        IMMessageDeliveryState.Failed -> "failed"
    }
