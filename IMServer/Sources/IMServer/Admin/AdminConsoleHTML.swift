enum AdminConsoleHTML {
    static let page = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>IM 管理后台</title>
      <style>
        :root { color-scheme: light; --bg:#f6f7f9; --panel:#fff; --text:#17202a; --muted:#667085; --line:#d9dee7; --primary:#0a84ff; --danger:#c7362f; --ok:#137a3a; }
        * { box-sizing: border-box; }
        body { margin:0; background:var(--bg); color:var(--text); font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
        header { height:56px; display:flex; align-items:center; justify-content:space-between; padding:0 24px; background:var(--panel); border-bottom:1px solid var(--line); }
        h1 { margin:0; font-size:18px; font-weight:700; }
        main { max-width:1200px; margin:0 auto; padding:20px 24px 40px; }
        .auth { display:flex; gap:8px; align-items:center; }
        .principal { color:var(--muted); font-size:12px; white-space:nowrap; }
        input, select, textarea { border:1px solid var(--line); border-radius:6px; padding:8px 10px; background:#fff; color:var(--text); min-height:36px; }
        input[type=password] { width:280px; }
        button { border:1px solid var(--line); border-radius:6px; min-height:36px; padding:0 12px; background:#fff; cursor:pointer; }
        button.primary { border-color:var(--primary); background:var(--primary); color:#fff; }
        button.danger { border-color:var(--danger); color:var(--danger); }
        nav { display:flex; gap:8px; margin-bottom:16px; }
        nav button.active { background:#17202a; color:#fff; border-color:#17202a; }
        section { display:none; }
        section.active { display:block; }
        .grid { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:12px; margin-bottom:16px; }
        .metric { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:16px; }
        .metric strong { display:block; font-size:26px; line-height:1.1; margin-top:4px; }
        .bar { display:flex; gap:8px; align-items:center; margin:12px 0; flex-wrap:wrap; }
        table { width:100%; border-collapse:collapse; background:var(--panel); border:1px solid var(--line); border-radius:8px; overflow:hidden; }
        th, td { padding:10px 12px; border-bottom:1px solid var(--line); text-align:left; vertical-align:top; }
        th { background:#eef1f5; font-weight:700; color:#344054; }
        tr:last-child td { border-bottom:0; }
        .muted { color:var(--muted); }
        .status { display:inline-flex; border-radius:999px; padding:2px 8px; font-size:12px; background:#edf2ff; color:#21468b; }
        .status.disabled, .status.rejected { background:#fff1f0; color:var(--danger); }
        .status.resolved, .status.active { background:#ecfdf3; color:var(--ok); }
        .error { margin:12px 0; padding:10px 12px; border:1px solid #ffccc7; background:#fff1f0; color:#a8071a; border-radius:8px; display:none; }
        dialog { width:min(640px,calc(100% - 32px)); border:1px solid var(--line); border-radius:8px; padding:0; color:var(--text); box-shadow:0 16px 48px rgba(16,24,40,.2); }
        dialog::backdrop { background:rgba(16,24,40,.35); }
        .dialog-body { padding:20px; display:grid; gap:12px; }
        .dialog-header, .dialog-actions { display:flex; align-items:center; justify-content:space-between; gap:8px; }
        .dialog-header h2 { margin:0; font-size:16px; }
        .evidence-list { margin:0; padding-left:18px; display:grid; gap:6px; max-height:180px; overflow:auto; }
        .evidence-list a { color:var(--primary); overflow-wrap:anywhere; }
        @media (max-width: 760px) { header { height:auto; align-items:stretch; flex-direction:column; gap:12px; padding:16px; } main { padding:16px; } .grid { grid-template-columns:1fr 1fr; } input[type=password] { width:100%; } .auth { flex-direction:column; align-items:stretch; } table { font-size:12px; } th, td { padding:8px; } }
      </style>
    </head>
    <body>
      <header>
        <h1>IM 管理后台</h1>
        <div class="auth">
          <select id="credentialMode" aria-label="认证方式"><option value="accessToken">管理员 Access Token</option><option value="sharedSecret">应急密钥</option></select>
          <input id="adminCredential" type="password" placeholder="管理员 Access Token" autocomplete="off" autocapitalize="off" spellcheck="false">
          <input id="adminActor" type="text" placeholder="应急操作人" value="admin">
          <button class="primary" onclick="saveSecret()">连接</button>
          <span id="principal" class="principal">未连接</span>
        </div>
      </header>
      <main>
        <div id="error" class="error"></div>
        <nav>
          <button class="active" onclick="showTab('overview', this)">概览</button>
          <button onclick="showTab('users', this)">用户</button>
          <button onclick="showTab('conversations', this)">会话</button>
          <button onclick="showTab('reports', this)">举报</button>
          <button onclick="showTab('audit', this)">审计</button>
        </nav>

        <section id="overview" class="active" data-permission="overview.read">
          <div class="grid">
            <div class="metric"><span>用户总数</span><strong id="metricUsers">-</strong></div>
            <div class="metric"><span>活跃用户</span><strong id="metricActiveUsers">-</strong></div>
            <div class="metric"><span>在线 Session</span><strong id="metricSessions">-</strong></div>
            <div class="metric"><span>待处理举报</span><strong id="metricReports">-</strong></div>
          </div>
        </section>

        <section id="users" data-permission="users.read">
          <div class="bar">
            <input id="userQuery" placeholder="邮箱、昵称或用户 ID">
            <select id="userStatus"><option value="">全部状态</option><option value="active">active</option><option value="disabled">disabled</option></select>
            <button onclick="loadUsers()">刷新</button>
          </div>
          <table><thead><tr><th>用户</th><th>状态</th><th>创建时间</th><th>操作</th></tr></thead><tbody id="usersBody"></tbody></table>
        </section>

        <section id="conversations" data-permission="conversations.inspect">
          <div class="bar">
            <input id="conversationID" placeholder="会话 ID" autocomplete="off" spellcheck="false">
            <button class="primary" onclick="inspectConversation()">检查会话</button>
          </div>
          <div id="conversationInspection" class="muted">输入会话 ID 后查看元数据与成员状态。</div>
          <div id="conversationMessages"></div>
        </section>

        <section id="reports" data-permission="reports.read">
          <div class="bar">
            <select id="reportQueueScope"><option value="unassigned">未分配待办</option><option value="mine">我的待办</option><option value="all">全部活跃</option><option value="history">全部历史</option></select>
            <select id="reportStatus"><option value="">全部状态</option><option value="pending">pending</option><option value="reviewing">reviewing</option><option value="resolved">resolved</option><option value="rejected">rejected</option></select>
            <button onclick="loadReports()">刷新</button>
          </div>
          <div id="reportQueueSummary" class="muted"></div>
          <table><thead><tr><th>举报</th><th>目标</th><th>状态</th><th>操作</th></tr></thead><tbody id="reportsBody"></tbody></table>
        </section>

        <section id="audit" data-permission="audit.read">
          <div class="bar"><input id="auditAction" placeholder="动作"><input id="auditActor" placeholder="操作者"><input id="auditTargetID" placeholder="目标 ID"><input id="auditRequestID" placeholder="请求 ID"><button onclick="loadAudit()">筛选</button></div>
          <table><thead><tr><th>时间</th><th>操作者</th><th>动作</th><th>目标</th></tr></thead><tbody id="auditBody"></tbody></table>
        </section>
      </main>
      <dialog id="evidenceDialog" aria-labelledby="evidenceDialogTitle">
        <div class="dialog-body">
          <div class="dialog-header"><h2 id="evidenceDialogTitle">审核证据</h2><button type="button" onclick="closeEvidenceDialog()" aria-label="关闭">关闭</button></div>
          <ul id="evidenceList" class="evidence-list"></ul>
          <div id="evidenceForm">
            <div class="bar"><input id="evidenceURL" type="url" placeholder="https://evidence.example.com/..." autocomplete="off"><input id="evidenceLabel" type="text" maxlength="120" placeholder="证据标签"></div>
            <div class="dialog-actions"><span></span><button id="evidenceSave" class="primary" type="button" onclick="addReportEvidence()">添加证据</button></div>
          </div>
        </div>
      </dialog>
      <dialog id="userSecurityDialog" aria-labelledby="userSecurityDialogTitle">
        <div class="dialog-body">
          <div class="dialog-header"><h2 id="userSecurityDialogTitle">用户安全概览</h2><button type="button" onclick="closeUserSecurityDialog()" aria-label="关闭">关闭</button></div>
          <div id="userSecurityContent" class="muted">加载中</div>
        </div>
      </dialog>
      <script>
        const state = { tab: 'overview', principal: null, evidenceReportID: null, governanceCommandID: null, governanceStatus: '' };
        const evidenceDialog = document.getElementById('evidenceDialog');
        const userSecurityDialog = document.getElementById('userSecurityDialog');
        credentialMode.value = sessionStorage.getItem('im.admin.credential-mode') || 'accessToken';
        sessionStorage.removeItem('im.admin.credential');
        adminActor.value = sessionStorage.getItem('im.admin.actor') || 'admin';
        function syncCredentialPlaceholder() { adminCredential.placeholder = credentialMode.value === 'sharedSecret' ? 'IM_ADMIN_SHARED_SECRET' : '管理员 Access Token'; }
        credentialMode.addEventListener('change', syncCredentialPlaceholder);
        syncCredentialPlaceholder();
        function saveSecret() { sessionStorage.setItem('im.admin.credential-mode', credentialMode.value); sessionStorage.setItem('im.admin.actor', adminActor.value || 'admin'); connect(); }
        function showError(message) { error.textContent = message || ''; error.style.display = message ? 'block' : 'none'; }
        function headers() { const value = adminCredential.value.trim(); const headers = { 'Content-Type': 'application/json' }; if (credentialMode.value === 'sharedSecret') { headers['X-IM-Admin-Secret'] = value; headers['X-IM-Admin-Actor'] = adminActor.value || 'admin'; } else { headers.Authorization = 'Bearer ' + value; } return headers; }
        function idempotencyKey() { return typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : `web-${Date.now()}-${Math.random().toString(36).slice(2)}`; }
        async function api(path, options = {}) { const requestHeaders = { ...headers(), ...(options.headers || {}) }; const method = (options.method || 'GET').toUpperCase(); if ((method === 'POST' || method === 'PATCH' || method === 'PUT' || method === 'DELETE') && !requestHeaders['Idempotency-Key']) requestHeaders['Idempotency-Key'] = idempotencyKey(); const res = await fetch(path, { ...options, headers: requestHeaders }); if (!res.ok) throw new Error(await res.text() || res.statusText); return res.json(); }
        function hasPermission(permission) { return !!state.principal && state.principal.permissions.includes(permission); }
        function applyPermissions() { document.querySelectorAll('section[data-permission]').forEach(section => { const allowed = hasPermission(section.dataset.permission); section.hidden = !allowed; const button = document.querySelector(`nav button[onclick*="'${section.id}'"]`); if (button) button.hidden = !allowed; }); const mineOption = reportQueueScope.querySelector('option[value="mine"]'); mineOption.hidden = !state.principal?.userID; if (!state.principal?.userID && reportQueueScope.value === 'mine') reportQueueScope.value = 'unassigned'; const first = Array.from(document.querySelectorAll('section[data-permission]')).find(section => !section.hidden); if (first && document.getElementById(state.tab).hidden) { state.tab = first.id; } document.querySelectorAll('section').forEach(s => s.classList.toggle('active', s.id === state.tab)); }
        async function connect() { showError(''); try { state.principal = await api('/admin/api/me'); principal.textContent = state.principal.actor + ' · ' + state.principal.role; applyPermissions(); await refresh(); } catch (e) { state.principal = null; principal.textContent = '未连接'; applyPermissions(); showError(e.message); } }
        function showTab(id, button) { if (!hasPermission(document.getElementById(id).dataset.permission)) return; state.tab = id; document.querySelectorAll('section').forEach(s => s.classList.toggle('active', s.id === id)); document.querySelectorAll('nav button').forEach(b => b.classList.toggle('active', b === button)); refresh(); }
        async function refresh() { showError(''); try { if (state.tab === 'overview') await loadOverview(); if (state.tab === 'users') await loadUsers(); if (state.tab === 'reports') await loadReports(); if (state.tab === 'audit') await loadAudit(); } catch (e) { showError(e.message); } }
        async function loadOverview() { const data = await api('/admin/api/overview'); metricUsers.textContent = data.users.total; metricActiveUsers.textContent = data.users.active; metricSessions.textContent = data.activeSessions; metricReports.textContent = data.reports.pending + data.reports.reviewing; }
        async function loadUsers() { const params = new URLSearchParams(); if (userQuery.value) params.set('query', userQuery.value); if (userStatus.value) params.set('status', userStatus.value); const data = await api('/admin/api/users?' + params); usersBody.innerHTML = data.items.map(u => `<tr><td><strong>${escapeHtml(u.email)}</strong><div class="muted">${u.id}</div></td><td><span class="status ${u.status}">${u.status}</span><div class="muted">${escapeHtml(u.adminRole || 'user')}</div></td><td>${formatDate(u.createdAt)}</td><td>${hasPermission('users.inspect_security') ? `<button onclick="openUserSecurityDialog('${u.id}')">安全</button> ` : ''}${hasPermission('users.write_status') ? (u.status === 'disabled' ? `<button onclick="setUserStatus('${u.id}','active')">恢复</button>` : `<button class="danger" onclick="setUserStatus('${u.id}','disabled')">封禁</button>`) : ''} ${hasPermission('users.write_role') ? `<select onchange="setUserRole('${u.id}',this.value)"><option value="">普通用户</option><option value="support" ${u.adminRole === 'support' ? 'selected' : ''}>support</option><option value="moderator" ${u.adminRole === 'moderator' ? 'selected' : ''}>moderator</option><option value="super_admin" ${u.adminRole === 'super_admin' ? 'selected' : ''}>super_admin</option></select>` : ''}</td></tr>`).join(''); }
        function userSecurityRows(data) { const sessions = data.sessions.length ? data.sessions.map(s => `<li>${escapeHtml(s.deviceName || s.deviceID || '未命名设备')}<div class="muted">${escapeHtml([s.platform, s.appVersion].filter(Boolean).join(' · ') || '未知平台')} · 最近活跃 ${formatDate(s.lastSeenAt)} · ${s.revokedAt ? '已撤销' : '有效'}</div></li>`).join('') : '<li class="muted">无会话</li>'; const devices = data.pushDevices.length ? data.pushDevices.map(d => `<li>${escapeHtml(d.platform)} · …${escapeHtml(d.tokenSuffix)}<div class="muted">${d.isActive ? '有效' : '已停用'} · 更新于 ${formatDate(d.updatedAt)}</div></li>`).join('') : '<li class="muted">无推送设备</li>'; return `<strong>${escapeHtml(data.user.email)}</strong><div class="muted">会话不展示刷新凭据；推送设备只展示 token 尾部。</div><h3>会话</h3><ul class="evidence-list">${sessions}</ul><h3>推送设备</h3><ul class="evidence-list">${devices}</ul>`; }
        async function openUserSecurityDialog(userID) { userSecurityContent.textContent = '加载中'; userSecurityDialog.showModal(); try { const data = await api('/admin/api/users/' + userID + '/security'); userSecurityContent.innerHTML = userSecurityRows(data); } catch (e) { closeUserSecurityDialog(); showError(e.message); } }
        function closeUserSecurityDialog() { userSecurityDialog.close(); }
        async function setUserStatus(id, status) { if (!confirm(status === 'disabled' ? '确认封禁该用户并撤销其全部登录态？' : '确认恢复该用户？')) return; await api('/admin/api/users/' + id + '/status', { method:'PATCH', body: JSON.stringify({ status, note:'web-admin' }) }); await loadUsers(); if (hasPermission('overview.read')) await loadOverview(); }
        async function setUserRole(id, adminRole) { await api('/admin/api/users/' + id + '/admin-role', { method:'PATCH', body: JSON.stringify({ adminRole: adminRole || null, note:'web-admin' }) }); await loadUsers(); }
        function conversationMemberRows(members, canRemoveMembers) { return members.length ? members.map(member => { const remove = canRemoveMembers && hasPermission('conversations.write_governance') && member.role !== 'owner' ? `<button class="danger" onclick="removeGroupMember('${member.userID}')">移除</button>` : ''; return `<tr><td><strong>${escapeHtml(member.displayName || member.email)}</strong><div class="muted">${escapeHtml(member.email)} · ${escapeHtml(member.userID)}</div></td><td>${escapeHtml(member.role)}</td><td>${escapeHtml(member.userStatus)}</td><td>${member.lastReadSequence} / ${member.visibleFromSequence}</td><td>${remove}</td></tr>`; }).join('') : '<tr><td colspan="5" class="muted">无成员</td></tr>'; }
        function governanceControls(conversation) { if (!hasPermission('conversations.write_governance') || conversation.kind !== 'group') return ''; const dissolved = conversation.groupLifecycleState === 'dissolved'; const frozen = conversation.groupLifecycleState === 'frozen'; const muteLabel = conversation.muteAll ? '解除全员禁言' : '全员禁言'; const mute = dissolved ? '' : `<button onclick="setGroupMuteAll(${conversation.muteAll ? 'false' : 'true'})">${muteLabel}</button>`; const lifecycle = dissolved ? '<span class="muted">群已解散，保留历史记录。</span>' : `<button class="${frozen ? '' : 'danger'}" onclick="setGroupLifecycle('${frozen ? 'active' : 'frozen'}')">${frozen ? '解冻群' : '冻结群'}</button><button class="danger" onclick="setGroupLifecycle('dissolved')">解散群</button>`; const status = state.governanceCommandID ? `<span class="muted">${escapeHtml(state.governanceStatus || ('命令 ' + state.governanceCommandID))}</span><button onclick="refreshGovernanceCommand()">刷新状态</button>` : ''; return `<div class="bar">${mute}${lifecycle}${status}</div>`; }
        function renderConversationInspection(data) { const c = data.conversation; const latest = data.latestMessage ? `最近消息 #${data.latestMessage.timelineSequence} · ${escapeHtml(data.latestMessage.kind)} · ${formatDate(data.latestMessage.createdAt)}` : '暂无消息'; const messageControl = hasPermission('messages.inspect') ? `<button onclick="loadConversationMessages()">查看最近消息</button>` : '<span class="muted">消息正文仅限超级管理员查看。</span>'; conversationInspection.innerHTML = `<div class="bar"><strong>${escapeHtml(c.title || '未命名会话')}</strong><span class="status">${escapeHtml(c.kind)}</span><span class="muted">${escapeHtml(c.id)}</span></div><div class="muted">成员 ${data.memberTotal} · 最后序列 ${c.lastMessageSequence} · ${latest}</div><div class="bar">${messageControl}</div>${governanceControls(c)}<table><thead><tr><th>成员</th><th>群角色</th><th>账号状态</th><th>已读 / 可见序列</th><th>操作</th></tr></thead><tbody>${conversationMemberRows(data.members, c.kind === 'group')}</tbody></table>`; conversationMessages.innerHTML = ''; }
        async function inspectConversation() { const id = conversationID.value.trim(); if (!id) { showError('请输入会话 ID。'); return; } showError(''); conversationInspection.textContent = '加载中'; conversationMessages.innerHTML = ''; try { const data = await api('/admin/api/conversations/' + encodeURIComponent(id)); if (state.conversationID && state.conversationID !== data.conversation.id) { state.governanceCommandID = null; state.governanceStatus = ''; } state.conversationID = data.conversation.id; renderConversationInspection(data); } catch (e) { conversationInspection.textContent = '未加载会话。'; showError(e.message); } }
        async function submitGovernanceCommand(body) { if (!state.conversationID) return; const command = await api('/admin/api/conversations/' + encodeURIComponent(state.conversationID) + '/governance-commands', { method:'POST', body: JSON.stringify(body) }); state.governanceCommandID = command.id; state.governanceStatus = '命令已受理: ' + command.status; await inspectConversation(); }
        async function setGroupMuteAll(muteAll) { const reason = prompt(muteAll ? '输入全员禁言原因' : '输入解除全员禁言原因'); if (!reason || !reason.trim()) return; try { await submitGovernanceCommand({ action:'group.mute_all.set', muteAll, reason:reason.trim() }); } catch (e) { showError(e.message); } }
        async function setGroupLifecycle(groupLifecycleState) { const destructive = groupLifecycleState === 'frozen' || groupLifecycleState === 'dissolved'; const promptText = groupLifecycleState === 'dissolved' ? '输入解散群原因' : groupLifecycleState === 'frozen' ? '输入冻结群原因' : '输入解冻群原因'; const reason = prompt(promptText); if (!reason || !reason.trim()) return; if (groupLifecycleState === 'dissolved' && !confirm('解散不可恢复：成员关系、消息和媒体保留为只读历史，不能重新激活。确认继续？')) return; if (groupLifecycleState === 'frozen' && !confirm('冻结后成员只能查看历史，不能发送消息或修改群资料。确认继续？')) return; try { await submitGovernanceCommand({ action:'group.lifecycle.set', groupLifecycleState, confirmed:destructive, reason:reason.trim() }); } catch (e) { showError(e.message); } }
        async function removeGroupMember(memberUserID) { const reason = prompt('输入移除成员原因'); if (!reason || !reason.trim()) return; if (!confirm('确认移除该群成员？')) return; try { await submitGovernanceCommand({ action:'group.member.remove', memberUserID, confirmed:true, reason:reason.trim() }); } catch (e) { showError(e.message); } }
        async function refreshGovernanceCommand() { if (!state.conversationID || !state.governanceCommandID) return; try { const command = await api('/admin/api/conversations/' + encodeURIComponent(state.conversationID) + '/governance-commands/' + encodeURIComponent(state.governanceCommandID)); state.governanceStatus = '命令状态: ' + command.status + (command.lastErrorCode ? ' (' + command.lastErrorCode + ')' : ''); await inspectConversation(); } catch (e) { showError(e.message); } }
        function messageRows(items) { return items.length ? items.map(message => `<tr><td>${message.timelineSequence}</td><td>${escapeHtml(message.senderEmail)}<div class="muted">${escapeHtml(message.senderUserID)}</div></td><td>${escapeHtml(JSON.stringify(message.content))}</td><td>${formatDate(message.createdAt)}</td></tr>`).join('') : '<tr><td colspan="4" class="muted">暂无消息</td></tr>'; }
        async function loadConversationMessages(beforeSequence) { if (!state.conversationID) return; showError(''); conversationMessages.textContent = '加载消息中'; try { const params = new URLSearchParams(); if (beforeSequence) params.set('beforeSequence', beforeSequence); const data = await api('/admin/api/conversations/' + encodeURIComponent(state.conversationID) + '/messages?' + params); const more = data.hasMore ? `<button onclick="loadConversationMessages(${data.nextBeforeSequence})">加载更早消息</button>` : ''; conversationMessages.innerHTML = `<h3>消息内容</h3><table><thead><tr><th>序列</th><th>发送者</th><th>内容</th><th>时间</th></tr></thead><tbody>${messageRows(data.items)}</tbody></table><div class="bar">${more}</div>`; } catch (e) { conversationMessages.textContent = ''; showError(e.message); } }
        function reportContext(report) { const inspection = hasPermission('conversations.inspect') && report.conversationID ? `<button onclick="openReportConversation('${report.conversationID}')">检查会话</button>` : ''; const snapshot = report.messageSnapshotJSON ? `<details><summary>消息快照</summary><pre>${escapeHtml(report.messageSnapshotJSON)}</pre></details>` : ''; return `${inspection}${snapshot}`; }
        async function openReportConversation(id) { if (!hasPermission('conversations.inspect')) return; conversationID.value = id; const button = Array.from(document.querySelectorAll('nav button')).find(item => item.textContent.trim() === '会话'); showTab('conversations', button); await inspectConversation(); }
        function reportAssignment(report) { return report.assignedReviewerActor ? `<div class="muted">审核人: ${escapeHtml(report.assignedReviewerActor)}</div>` : `<div class="muted">未分配审核人</div>`; }
        function reportActions(report) { const evidence = `<button onclick="openEvidenceDialog('${report.id}')">证据</button> `; if (!hasPermission('reports.write')) return evidence; const terminal = report.status === 'resolved' || report.status === 'rejected'; const canClaim = !!state.principal.userID && !report.assignedReviewerUserID && !terminal; return `${evidence}${canClaim ? `<button onclick="claimReport('${report.id}')">领取</button> ` : ''}${terminal ? '' : `<button onclick="setReportStatus('${report.id}','reviewing')">审阅中</button> <button onclick="setReportStatus('${report.id}','resolved','action_taken')">通过</button> <button onclick="setReportStatus('${report.id}','rejected','no_violation')">驳回</button>`}`; }
        function renderReports(items) { reportsBody.innerHTML = items.map(r => `<tr><td><strong>${escapeHtml(r.reason)}</strong><div class="muted">${escapeHtml(r.detail || '')}</div>${reportContext(r)}</td><td>${r.targetType}<div class="muted">${r.targetID}</div></td><td><span class="status ${r.status}">${r.status}</span>${reportAssignment(r)}</td><td>${reportActions(r)}</td></tr>`).join(''); }
        function formatAge(seconds) { if (seconds == null) return '-'; if (seconds < 60) return seconds + ' 秒'; if (seconds < 3600) return Math.floor(seconds / 60) + ' 分钟'; return Math.floor(seconds / 3600) + ' 小时'; }
        async function loadReports() { const scope = reportQueueScope.value; const params = new URLSearchParams(); if (reportStatus.value) params.set('status', reportStatus.value); if (scope === 'history') { const data = await api('/admin/api/reports?' + params); reportQueueSummary.textContent = ''; renderReports(data.items); return; } params.set('scope', scope); const data = await api('/admin/api/reports/queue?' + params); reportQueueSummary.textContent = `待处理 ${data.summary.pendingCount} · 审阅中 ${data.summary.reviewingCount} · 未分配 ${data.summary.unassignedActiveCount} · 最早待处理 ${formatAge(data.summary.oldestPendingAgeSeconds)}`; renderReports(data.items.map(item => item.report)); }
        async function claimReport(id) { await api('/admin/api/reports/' + id + '/reviewer', { method:'PATCH', body: JSON.stringify({ reviewerUserID: state.principal.userID }) }); await loadReports(); }
        async function setReportStatus(id, status, resolutionCategory) { if (!confirm('确认将举报标记为 ' + status + '？')) return; await api('/admin/api/reports/' + id, { method:'PATCH', body: JSON.stringify({ status, resolutionCategory, handledNote:'web-admin' }) }); await loadReports(); if (hasPermission('overview.read')) await loadOverview(); }
        async function openEvidenceDialog(reportID) { state.evidenceReportID = reportID; evidenceURL.value = ''; evidenceLabel.value = ''; evidenceSave.hidden = !hasPermission('reports.write'); evidenceList.innerHTML = '<li class="muted">加载中</li>'; evidenceDialog.showModal(); try { const data = await api('/admin/api/reports/' + reportID + '/evidence'); evidenceList.innerHTML = data.items.length ? data.items.map(e => `<li><a href="${escapeHtml(e.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(e.label || e.url)}</a><div class="muted">${escapeHtml(e.submittedByActor)} · ${formatDate(e.createdAt)}</div></li>`).join('') : '<li class="muted">暂无证据</li>'; } catch (e) { closeEvidenceDialog(); showError(e.message); } }
        function closeEvidenceDialog() { evidenceDialog.close(); state.evidenceReportID = null; }
        async function addReportEvidence() { const url = evidenceURL.value.trim(); if (!url || !state.evidenceReportID) return; await api('/admin/api/reports/' + state.evidenceReportID + '/evidence', { method:'POST', body: JSON.stringify({ url, label: evidenceLabel.value.trim() || null }) }); await openEvidenceDialog(state.evidenceReportID); }
        async function loadAudit() { const params = new URLSearchParams(); if (auditAction.value.trim()) params.set('action', auditAction.value.trim()); if (auditActor.value.trim()) params.set('actor', auditActor.value.trim()); if (auditTargetID.value.trim()) params.set('targetID', auditTargetID.value.trim()); if (auditRequestID.value.trim()) params.set('requestID', auditRequestID.value.trim()); const data = await api('/admin/api/audit-events?' + params); auditBody.innerHTML = data.items.map(e => `<tr><td>${formatDate(e.createdAt)}</td><td>${escapeHtml(e.actor)}</td><td>${escapeHtml(e.action)}</td><td>${escapeHtml((e.targetType || '') + ' ' + (e.targetID || ''))}</td></tr>`).join(''); }
        function formatDate(value) { return value ? new Date(value).toLocaleString() : '-'; }
        function escapeHtml(value) { return String(value).replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch])); }
        refresh();
      </script>
    </body>
    </html>
    """
}
