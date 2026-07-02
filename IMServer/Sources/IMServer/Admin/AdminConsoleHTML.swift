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
        @media (max-width: 760px) { header { height:auto; align-items:stretch; flex-direction:column; gap:12px; padding:16px; } main { padding:16px; } .grid { grid-template-columns:1fr 1fr; } input[type=password] { width:100%; } .auth { flex-direction:column; align-items:stretch; } table { font-size:12px; } th, td { padding:8px; } }
      </style>
    </head>
    <body>
      <header>
        <h1>IM 管理后台</h1>
        <div class="auth">
          <input id="adminSecret" type="password" placeholder="Admin Secret">
          <input id="adminActor" type="text" placeholder="操作者" value="admin">
          <button class="primary" onclick="saveSecret()">连接</button>
        </div>
      </header>
      <main>
        <div id="error" class="error"></div>
        <nav>
          <button class="active" onclick="showTab('overview', this)">概览</button>
          <button onclick="showTab('users', this)">用户</button>
          <button onclick="showTab('reports', this)">举报</button>
          <button onclick="showTab('audit', this)">审计</button>
        </nav>

        <section id="overview" class="active">
          <div class="grid">
            <div class="metric"><span>用户总数</span><strong id="metricUsers">-</strong></div>
            <div class="metric"><span>活跃用户</span><strong id="metricActiveUsers">-</strong></div>
            <div class="metric"><span>在线 Session</span><strong id="metricSessions">-</strong></div>
            <div class="metric"><span>待处理举报</span><strong id="metricReports">-</strong></div>
          </div>
        </section>

        <section id="users">
          <div class="bar">
            <input id="userQuery" placeholder="邮箱、昵称或用户 ID">
            <select id="userStatus"><option value="">全部状态</option><option value="active">active</option><option value="disabled">disabled</option></select>
            <button onclick="loadUsers()">刷新</button>
          </div>
          <table><thead><tr><th>用户</th><th>状态</th><th>创建时间</th><th>操作</th></tr></thead><tbody id="usersBody"></tbody></table>
        </section>

        <section id="reports">
          <div class="bar">
            <select id="reportStatus"><option value="">全部状态</option><option value="pending">pending</option><option value="reviewing">reviewing</option><option value="resolved">resolved</option><option value="rejected">rejected</option></select>
            <button onclick="loadReports()">刷新</button>
          </div>
          <table><thead><tr><th>举报</th><th>目标</th><th>状态</th><th>操作</th></tr></thead><tbody id="reportsBody"></tbody></table>
        </section>

        <section id="audit">
          <div class="bar"><button onclick="loadAudit()">刷新</button></div>
          <table><thead><tr><th>时间</th><th>操作者</th><th>动作</th><th>目标</th></tr></thead><tbody id="auditBody"></tbody></table>
        </section>
      </main>
      <script>
        const state = { tab: 'overview' };
        adminSecret.value = sessionStorage.getItem('im.admin.secret') || '';
        adminActor.value = sessionStorage.getItem('im.admin.actor') || 'admin';
        function saveSecret() { sessionStorage.setItem('im.admin.secret', adminSecret.value); sessionStorage.setItem('im.admin.actor', adminActor.value || 'admin'); refresh(); }
        function showError(message) { error.textContent = message || ''; error.style.display = message ? 'block' : 'none'; }
        function headers() { return { 'X-IM-Admin-Secret': adminSecret.value, 'X-IM-Admin-Actor': adminActor.value || 'admin', 'Content-Type': 'application/json' }; }
        async function api(path, options = {}) { const res = await fetch(path, { ...options, headers: { ...headers(), ...(options.headers || {}) } }); if (!res.ok) throw new Error(await res.text() || res.statusText); return res.json(); }
        function showTab(id, button) { state.tab = id; document.querySelectorAll('section').forEach(s => s.classList.toggle('active', s.id === id)); document.querySelectorAll('nav button').forEach(b => b.classList.toggle('active', b === button)); refresh(); }
        async function refresh() { showError(''); try { if (state.tab === 'overview') await loadOverview(); if (state.tab === 'users') await loadUsers(); if (state.tab === 'reports') await loadReports(); if (state.tab === 'audit') await loadAudit(); } catch (e) { showError(e.message); } }
        async function loadOverview() { const data = await api('/admin/api/overview'); metricUsers.textContent = data.users.total; metricActiveUsers.textContent = data.users.active; metricSessions.textContent = data.activeSessions; metricReports.textContent = data.reports.pending + data.reports.reviewing; }
        async function loadUsers() { const params = new URLSearchParams(); if (userQuery.value) params.set('query', userQuery.value); if (userStatus.value) params.set('status', userStatus.value); const data = await api('/admin/api/users?' + params); usersBody.innerHTML = data.items.map(u => `<tr><td><strong>${escapeHtml(u.email)}</strong><div class="muted">${u.id}</div></td><td><span class="status ${u.status}">${u.status}</span></td><td>${formatDate(u.createdAt)}</td><td>${u.status === 'disabled' ? `<button onclick="setUserStatus('${u.id}','active')">恢复</button>` : `<button class="danger" onclick="setUserStatus('${u.id}','disabled')">封禁</button>`}</td></tr>`).join(''); }
        async function setUserStatus(id, status) { await api('/admin/api/users/' + id + '/status', { method:'PATCH', body: JSON.stringify({ status, note:'web-admin' }) }); await loadUsers(); await loadOverview(); }
        async function loadReports() { const params = new URLSearchParams(); if (reportStatus.value) params.set('status', reportStatus.value); const data = await api('/admin/api/reports?' + params); reportsBody.innerHTML = data.items.map(r => `<tr><td><strong>${escapeHtml(r.reason)}</strong><div class="muted">${escapeHtml(r.detail || '')}</div></td><td>${r.targetType}<div class="muted">${r.targetID}</div></td><td><span class="status ${r.status}">${r.status}</span></td><td><button onclick="setReportStatus('${r.id}','reviewing')">审阅中</button> <button onclick="setReportStatus('${r.id}','resolved')">通过</button> <button onclick="setReportStatus('${r.id}','rejected')">驳回</button></td></tr>`).join(''); }
        async function setReportStatus(id, status) { await api('/admin/api/reports/' + id, { method:'PATCH', body: JSON.stringify({ status, handledNote:'web-admin' }) }); await loadReports(); await loadOverview(); }
        async function loadAudit() { const data = await api('/admin/api/audit-events'); auditBody.innerHTML = data.items.map(e => `<tr><td>${formatDate(e.createdAt)}</td><td>${escapeHtml(e.actor)}</td><td>${escapeHtml(e.action)}</td><td>${escapeHtml((e.targetType || '') + ' ' + (e.targetID || ''))}</td></tr>`).join(''); }
        function formatDate(value) { return value ? new Date(value).toLocaleString() : '-'; }
        function escapeHtml(value) { return String(value).replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch])); }
        refresh();
      </script>
    </body>
    </html>
    """
}
