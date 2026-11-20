import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Alert,
  App as AntApp,
  Button,
  Card,
  ConfigProvider,
  Descriptions,
  Drawer,
  Empty,
  Form,
  Input,
  Layout,
  Menu,
  Modal,
  Select,
  Space,
  Spin,
  Table,
  Tag,
  Typography,
} from "antd";
import zhCN from "antd/locale/zh_CN";
import {
  api,
  ApiError,
  errorMessage,
  type Audit,
  type Identity,
  type Reason,
  type User,
} from "./api";
import "./style.css";
import { ServiceMonitoring } from "./ServiceMonitoring";

const { Text, Title, Paragraph } = Typography;
const reasonLabels: Record<Reason, string> = {
  user_requested: "用户本人请求",
  credential_compromise: "凭据疑似泄漏",
  policy_enforcement: "违反平台规则",
};
const actionLabels: Record<string, string> = {
  login: "管理员登录",
  logout: "管理员退出",
  users_search: "用户查询",
  user_view: "查看用户",
  account_disable: "禁用账户",
};
const outcomeLabels: Record<string, string> = {
  succeeded: "已完成",
  rejected: "登录被拒绝",
  forbidden: "无操作权限",
  pending: "结果待确认",
  disabled: "已禁用",
  already_disabled: "此前已禁用",
};
const date = (value?: string) =>
  value ? new Date(value).toLocaleString("zh-CN", { hour12: false }) : "—";
const status = (user: User) =>
  user.disabledAt ? (
    <Tag color="red">已禁用</Tag>
  ) : (
    <Tag color={user.state === "active" ? "green" : "default"}>
      {(
        {
          active: "正常",
          hidden: "隐藏",
          suspended: "已暂停",
          deleted: "已删除",
        } as Record<string, string>
      )[user.state] ?? user.state}
    </Tag>
  );

type Pending = {
  operationID: string;
  userID: string;
  reason: Reason;
  principal: string;
};
function readPending(): Pending | null {
  try {
    const value = JSON.parse(
      sessionStorage.getItem("im-admin-pending-disable") ?? "null",
    );
    const uuid = /^[a-f0-9-]{36}$/i;
    return value &&
      uuid.test(value.operationID) &&
      uuid.test(value.userID) &&
      reasonLabels[value.reason as Reason] &&
      typeof value.principal === "string"
      ? value
      : null;
  } catch {
    return null;
  }
}
function remember(value: Pending | null) {
  if (value)
    sessionStorage.setItem("im-admin-pending-disable", JSON.stringify(value));
  else sessionStorage.removeItem("im-admin-pending-disable");
}

function Login({ onLogin }: { onLogin: (identity: Identity) => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  return (
    <main className="login-page">
      <div className="login-intro">
        <div className="brand-mark">IM</div>
        <Text className="eyebrow">管理中心</Text>
        <Title>
          让每一次操作
          <br />
          都有据可查。
        </Title>
        <Paragraph>
          账户查询、访问管理与操作审计，
          <br />
          在一个工作台中完成。
        </Paragraph>
      </div>
      <Card className="login-card">
        <Title level={3}>管理员登录</Title>
        <Paragraph type="secondary">使用独立的管理员账号进入工作台</Paragraph>
        {error && (
          <Alert type="error" showIcon title={error} className="block-gap" />
        )}
        <Form
          layout="vertical"
          onFinish={async (values: { username: string; password: string }) => {
            setBusy(true);
            setError("");
            try {
              onLogin(await api<Identity>("/login", values));
            } catch (error) {
              setError(errorMessage(error));
            } finally {
              setBusy(false);
            }
          }}
        >
          <Form.Item
            label="管理员账号"
            name="username"
            rules={[{ required: true, message: "请输入管理员账号" }]}
          >
            <Input
              autoComplete="username"
              autoFocus
              maxLength={64}
              placeholder="输入管理员账号"
            />
          </Form.Item>
          <Form.Item
            label="密码"
            name="password"
            rules={[{ required: true, message: "请输入密码" }]}
          >
            <Input.Password
              autoComplete="current-password"
              maxLength={1024}
              placeholder="输入密码"
            />
          </Form.Item>
          <Button
            type="primary"
            htmlType="submit"
            loading={busy}
            block
            size="large"
          >
            登录工作台
          </Button>
        </Form>
        <Text type="secondary" className="login-note">
          管理员账号与 IM 用户账号独立，登录及操作均留有审计记录。
        </Text>
      </Card>
    </main>
  );
}

function Workspace({
  identity,
  onLogout,
}: {
  identity: Identity;
  onLogout: () => void;
}) {
  const { message } = AntApp.useApp();
  const [section, setSection] = useState(() =>
    ["monitoring", "audit"].includes(location.hash.slice(1))
      ? location.hash.slice(1)
      : "users",
  );
  useEffect(() => {
    const change = () =>
      setSection(
        ["monitoring", "audit"].includes(location.hash.slice(1))
          ? location.hash.slice(1)
          : "users",
      );
    window.addEventListener("hashchange", change);
    return () => window.removeEventListener("hashchange", change);
  }, []);
  const [users, setUsers] = useState<User[]>([]);
  const [query, setQuery] = useState("");
  const [after, setAfter] = useState<string>();
  const [history, setHistory] = useState<(string | undefined)[]>([]);
  const [audits, setAudits] = useState<Audit[]>([]);
  const [before, setBefore] = useState<string>();
  const [auditHistory, setAuditHistory] = useState<(string | undefined)[]>([]);
  const [auditTarget, setAuditTarget] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [selected, setSelected] = useState<User>();
  const [confirmation, setConfirmation] = useState<User>();
  const [reason, setReason] = useState<Reason>("policy_enforcement");
  const [confirmHandle, setConfirmHandle] = useState("");
  const [pending, setPending] = useState<Pending | null>(readPending);
  const [operating, setOperating] = useState(false);
  const [operationError, setOperationError] = useState("");
  const [refresh, setRefresh] = useState(0);
  const requestGeneration = useRef(0);
  const detailGeneration = useRef(0);
  const ownPending =
    pending?.principal === `admin:${identity.username}` ? pending : null;

  useEffect(() => {
    const generation = ++requestGeneration.current;
    if (section === "monitoring") return;
    setLoading(true);
    setError("");
    const path =
      section === "users"
        ? `/users?${new URLSearchParams({ q: query, limit: "25", ...(after ? { after } : {}) })}`
        : `/audit?${new URLSearchParams({ limit: "25", ...(before ? { before } : {}), ...(auditTarget ? { userID: auditTarget } : {}) })}`;
    (async () => {
      try {
        if (section === "users") {
          const rows = await api<User[]>(path);
          if (generation === requestGeneration.current) setUsers(rows);
        } else {
          const rows = await api<Audit[]>(path);
          if (generation === requestGeneration.current) setAudits(rows);
        }
      } catch (error) {
        if (generation === requestGeneration.current)
          setError(errorMessage(error));
      } finally {
        if (generation === requestGeneration.current) setLoading(false);
      }
    })();
    return () => {
      requestGeneration.current++;
    };
  }, [section, query, after, before, auditTarget, refresh]);

  async function showUser(id: string) {
    const generation = ++detailGeneration.current;
    try {
      const user = await api<User>(`/users/${id}`);
      if (generation === detailGeneration.current) setSelected(user);
    } catch (error) {
      void message.error(errorMessage(error));
    }
  }
  function finishOperation(result: Audit) {
    if (result.outcome === "pending") {
      setOperationError(
        "操作结果尚未确认。可以重试原操作；系统会使用同一个操作编号。",
      );
      return;
    }
    remember(null);
    setPending(null);
    setOperationError("");
    setRefresh((value) => value + 1);
    void message.success(outcomeLabels[result.outcome] ?? result.outcome);
    if (selected && selected.userID === result.targetUserID)
      void showUser(selected.userID);
  }
  async function submit(operation: Pending) {
    setOperating(true);
    setOperationError("");
    try {
      finishOperation(
        await api<Audit>(`/users/${operation.userID}/disable`, {
          operationID: operation.operationID,
          reason: operation.reason,
        }),
      );
    } catch (error) {
      setOperationError(errorMessage(error));
    } finally {
      setOperating(false);
    }
  }
  async function checkOperation() {
    if (!ownPending) return;
    setOperating(true);
    setOperationError("");
    try {
      finishOperation(await api<Audit>(`/audit/${ownPending.operationID}`));
    } catch (error) {
      setOperationError(
        error instanceof ApiError && error.status === 404
          ? "服务端尚未登记该操作。可重试原操作。"
          : errorMessage(error),
      );
    } finally {
      setOperating(false);
    }
  }
  function beginDisable() {
    if (!confirmation || ownPending) return;
    const operation: Pending = {
      operationID: crypto.randomUUID(),
      userID: confirmation.userID,
      reason,
      principal: `admin:${identity.username}`,
    };
    // 先记录操作编号，刷新页面或响应丢失也不创建第二次禁用意图。
    try {
      remember(operation);
    } catch {
      void message.error(
        "浏览器无法保存操作编号，请允许此站点使用会话存储后重试。",
      );
      return;
    }
    setPending(operation);
    setConfirmation(undefined);
    void submit(operation);
  }
  function openConfirmation(user: User) {
    setConfirmation(user);
    setReason("policy_enforcement");
    setConfirmHandle("");
  }
  function viewAudit(id: string) {
    setAuditTarget(id);
    setBefore(undefined);
    setAuditHistory([]);
    setSection("audit");
  }

  return (
    <Layout className="workspace">
      <Layout.Sider
        width={216}
        className="sidebar"
        breakpoint="lg"
        collapsedWidth={64}
      >
        <div className="sidebar-brand">
          <span className="brand-mark small">IM</span>
          <span className="brand-label">管理中心</span>
        </div>
        <div className="nav-label">工作台</div>
        <Menu
          selectedKeys={[section]}
          onClick={({ key }) => {
            location.hash = key;
            setSection(key);
          }}
          items={[
            {
              key: "monitoring",
              label: "服务监控",
              icon: <span aria-hidden>◉</span>,
            },
            {
              key: "users",
              label: "用户管理",
              icon: <span aria-hidden>◎</span>,
            },
            {
              key: "audit",
              label: "操作审计",
              icon: <span aria-hidden>≡</span>,
            },
          ]}
        />
        <div className="sidebar-foot">IM · 账户与访问管理</div>
      </Layout.Sider>
      <Layout>
        <Layout.Header className="topbar">
          <Text type="secondary">
            管理工作台 /{" "}
            {section === "monitoring"
              ? "服务监控"
              : section === "users"
                ? "用户管理"
                : "操作审计"}
          </Text>
          <Space>
            <Text>{identity.username}</Text>
            <Tag>{identity.role === "operator" ? "操作员" : "只读"}</Tag>
            <Button
              onClick={async () => {
                try {
                  await api("/logout", {});
                  onLogout();
                } catch (error) {
                  void message.error(errorMessage(error));
                }
              }}
            >
              退出
            </Button>
          </Space>
        </Layout.Header>
        <Layout.Content className="content">
          {section === "monitoring" ? (
            <ServiceMonitoring />
          ) : (
            <>
              <div className="page-heading">
                <div>
                  <Text className="eyebrow">
                    {section === "users" ? "ACCOUNTS" : "ACTIVITY LOG"}
                  </Text>
                  <Title level={2}>
                    {section === "users" ? "用户管理" : "操作审计"}
                  </Title>
                  <Paragraph type="secondary">
                    {section === "users"
                      ? "查询账户状态，查看详情并处理账户停用。"
                      : "追溯管理员的访问与操作，核对每一次处理结果。"}
                  </Paragraph>
                </div>
                <Button
                  onClick={() => setRefresh((value) => value + 1)}
                  loading={loading}
                >
                  刷新列表
                </Button>
              </div>
              {ownPending && (
                <Alert
                  className="block-gap"
                  type="warning"
                  showIcon
                  title="有一项禁用操作需要确认结果"
                  description={
                    <>
                      <div className="mono">{ownPending.operationID}</div>
                      <p>目标用户：{ownPending.userID}</p>
                      {operationError && <p role="alert">{operationError}</p>}
                      <Space wrap>
                        <Button
                          aria-label="查询结果"
                          loading={operating}
                          disabled={operating}
                          onClick={checkOperation}
                        >
                          查询结果
                        </Button>
                        <Button
                          loading={operating}
                          disabled={operating || identity.role !== "operator"}
                          aria-label="重试原操作"
                          onClick={() => void submit(ownPending)}
                        >
                          重试原操作
                        </Button>
                        <Button onClick={() => viewAudit(ownPending.userID)}>
                          查看审计
                        </Button>
                      </Space>
                    </>
                  }
                />
              )}
              {error && (
                <Alert
                  className="block-gap"
                  type="error"
                  showIcon
                  title={error}
                  action={
                    <Button onClick={() => setRefresh((v) => v + 1)}>
                      重试
                    </Button>
                  }
                />
              )}
              <Card className="data-card">
                {section === "users" ? (
                  <>
                    <div className="table-toolbar">
                      <Input.Search
                        aria-label="搜索用户"
                        placeholder="公开账号、用户 ID 或显示名称"
                        allowClear
                        enterButton="查询"
                        onSearch={(value) => {
                          setQuery(value.trim());
                          setAfter(undefined);
                          setHistory([]);
                        }}
                        style={{ maxWidth: 480 }}
                      />
                      <Text type="secondary">每页最多 25 条</Text>
                    </div>
                    <Table<User>
                      rowKey="userID"
                      dataSource={error ? [] : users}
                      loading={loading}
                      pagination={false}
                      scroll={{ x: 900 }}
                      locale={{
                        emptyText: (
                          <Empty description="没有找到用户，请调整查询条件" />
                        ),
                      }}
                      columns={[
                        {
                          title: "用户",
                          key: "name",
                          render: (_, user) => (
                            <div>
                              <Button
                                type="link"
                                className="name-button"
                                onClick={() => void showUser(user.userID)}
                              >
                                {user.displayName}
                              </Button>
                              <div className="secondary-handle">
                                @{user.publicHandle}
                              </div>
                            </div>
                          ),
                        },
                        {
                          title: "用户 ID",
                          dataIndex: "userID",
                          render: (value) => (
                            <Text className="mono" copyable>
                              {value}
                            </Text>
                          ),
                        },
                        {
                          title: "状态",
                          key: "state",
                          render: (_, user) => status(user),
                        },
                        { title: "有效设备", dataIndex: "activeDevices" },
                        {
                          title: "注册时间",
                          dataIndex: "createdAt",
                          render: date,
                        },
                        {
                          title: "操作",
                          key: "actions",
                          render: (_, user) => (
                            <Space>
                              <Button
                                type="link"
                                onClick={() => void showUser(user.userID)}
                              >
                                详情
                              </Button>
                              {identity.role === "operator" && (
                                <Button
                                  type="link"
                                  danger
                                  disabled={
                                    !!user.disabledAt ||
                                    !!ownPending ||
                                    operating
                                  }
                                  onClick={() => openConfirmation(user)}
                                >
                                  禁用
                                </Button>
                              )}
                            </Space>
                          ),
                        },
                      ]}
                    />
                    <div className="pagination">
                      <Button
                        disabled={!history.length || loading}
                        onClick={() => {
                          setAfter(history.at(-1));
                          setHistory(history.slice(0, -1));
                        }}
                      >
                        上一页
                      </Button>
                      <Text type="secondary">第 {history.length + 1} 页</Text>
                      <Button
                        disabled={users.length < 25 || loading || !!error}
                        onClick={() => {
                          setHistory([...history, after]);
                          setAfter(users.at(-1)?.userID);
                        }}
                      >
                        下一页
                      </Button>
                    </div>
                  </>
                ) : (
                  <>
                    <div className="table-toolbar">
                      <Input.Search
                        aria-label="按用户筛选审计"
                        key={auditTarget}
                        defaultValue={auditTarget}
                        placeholder="输入用户 ID 筛选，留空查看全部"
                        allowClear
                        enterButton="筛选"
                        onSearch={(value) => {
                          setAuditTarget(value.trim());
                          setBefore(undefined);
                          setAuditHistory([]);
                        }}
                        style={{ maxWidth: 480 }}
                      />
                      <Text type="secondary">时间从新到旧</Text>
                    </div>
                    <Table<Audit>
                      rowKey="sequence"
                      dataSource={error ? [] : audits}
                      loading={loading}
                      pagination={false}
                      scroll={{ x: 1000 }}
                      expandable={{
                        expandedRowRender: (row) => (
                          <Descriptions
                            size="small"
                            column={1}
                            items={[
                              {
                                key: "operation",
                                label: "操作编号",
                                children: (
                                  <Text copyable className="mono">
                                    {row.operationID}
                                  </Text>
                                ),
                              },
                              {
                                key: "reason",
                                label: "处理原因",
                                children: row.reason
                                  ? reasonLabels[row.reason]
                                  : "—",
                              },
                              {
                                key: "completed",
                                label: "完成时间",
                                children: date(row.completedAt),
                              },
                              {
                                key: "recovery",
                                label: "结果恢复",
                                children:
                                  row.outcome === "pending" &&
                                  row.reason &&
                                  row.targetUserID &&
                                  row.principal ===
                                    `admin:${identity.username}` &&
                                  identity.role === "operator" ? (
                                    <Button
                                      disabled={!!ownPending || operating}
                                      onClick={() => {
                                        const value = {
                                          operationID: row.operationID,
                                          userID: row.targetUserID!,
                                          reason: row.reason!,
                                          principal: row.principal!,
                                        };
                                        try {
                                          remember(value);
                                          setPending(value);
                                        } catch {
                                          void message.error(
                                            "无法保存操作编号",
                                          );
                                        }
                                      }}
                                    >
                                      接续原操作
                                    </Button>
                                  ) : (
                                    "—"
                                  ),
                              },
                            ]}
                          />
                        ),
                      }}
                      columns={[
                        {
                          title: "时间",
                          dataIndex: "occurredAt",
                          render: date,
                        },
                        {
                          title: "管理员",
                          dataIndex: "principal",
                          render: (value) => value ?? "未认证",
                        },
                        {
                          title: "操作",
                          dataIndex: "action",
                          render: (value) => actionLabels[value] ?? value,
                        },
                        {
                          title: "目标用户",
                          dataIndex: "targetUserID",
                          render: (value) =>
                            value ? (
                              <Text copyable className="mono">
                                {value}
                              </Text>
                            ) : (
                              "—"
                            ),
                        },
                        {
                          title: "结果",
                          dataIndex: "outcome",
                          render: (value) => (
                            <Tag
                              color={
                                value === "pending"
                                  ? "gold"
                                  : ["forbidden", "rejected"].includes(value)
                                    ? "red"
                                    : "green"
                              }
                            >
                              {outcomeLabels[value] ?? value}
                            </Tag>
                          ),
                        },
                      ]}
                    />
                    <div className="pagination">
                      <Button
                        disabled={!auditHistory.length || loading}
                        onClick={() => {
                          setBefore(auditHistory.at(-1));
                          setAuditHistory(auditHistory.slice(0, -1));
                        }}
                      >
                        上一页
                      </Button>
                      <Text type="secondary">
                        第 {auditHistory.length + 1} 页
                      </Text>
                      <Button
                        disabled={audits.length < 25 || loading || !!error}
                        onClick={() => {
                          setAuditHistory([...auditHistory, before]);
                          setBefore(audits.at(-1)?.sequence);
                        }}
                      >
                        下一页
                      </Button>
                    </div>
                  </>
                )}
              </Card>
              <Paragraph type="secondary" className="footer-note">
                当前账号：{identity.username} · 会话到期：
                {date(identity.expiresAt)}
              </Paragraph>
            </>
          )}
        </Layout.Content>
      </Layout>
      <Drawer
        title="用户详情"
        open={!!selected}
        onClose={() => {
          detailGeneration.current++;
          setSelected(undefined);
        }}
        size="large"
      >
        {selected && (
          <>
            <Title level={3}>{selected.displayName}</Title>
            <Paragraph type="secondary">@{selected.publicHandle}</Paragraph>
            <Descriptions
              column={1}
              items={[
                {
                  key: "id",
                  label: "用户 ID",
                  children: <Text copyable>{selected.userID}</Text>,
                },
                { key: "state", label: "状态", children: status(selected) },
                {
                  key: "kind",
                  label: "账户类型",
                  children:
                    (
                      {
                        regular: "普通用户",
                        system: "系统账户",
                        customer_support: "客服账户",
                      } as Record<string, string>
                    )[selected.accountKind] ?? selected.accountKind,
                },
                {
                  key: "devices",
                  label: "有效设备",
                  children: selected.activeDevices,
                },
                {
                  key: "created",
                  label: "注册时间",
                  children: date(selected.createdAt),
                },
                {
                  key: "disabled",
                  label: "禁用时间",
                  children: date(selected.disabledAt),
                },
              ]}
            />
            <Space className="block-gap" wrap>
              <Button
                onClick={() => {
                  viewAudit(selected.userID);
                  setSelected(undefined);
                }}
              >
                查看相关审计
              </Button>
              {identity.role === "operator" && (
                <Button
                  danger
                  disabled={!!selected.disabledAt || !!ownPending || operating}
                  onClick={() => openConfirmation(selected)}
                >
                  禁用此账户
                </Button>
              )}
            </Space>
          </>
        )}
      </Drawer>
      <Modal
        title="禁用账户"
        open={!!confirmation}
        onCancel={() => setConfirmation(undefined)}
        onOk={beginDisable}
        okText="确认禁用"
        cancelText="取消"
        okButtonProps={{
          danger: true,
          disabled:
            confirmHandle !== confirmation?.publicHandle || !!ownPending,
        }}
        destroyOnHidden
      >
        <Alert
          type="warning"
          showIcon
          title="此操作将停用账户并撤销所有设备凭据。当前版本不提供解封。"
        />
        <Paragraph className="block-gap">
          目标：<strong>{confirmation?.displayName}</strong>（@
          {confirmation?.publicHandle}）
        </Paragraph>
        <label htmlFor="disable-reason">处理原因</label>
        <Select
          id="disable-reason"
          value={reason}
          onChange={setReason}
          options={Object.entries(reasonLabels).map(([value, label]) => ({
            value,
            label,
          }))}
          style={{ width: "100%", margin: "8px 0 20px" }}
        />
        <label htmlFor="confirm-handle">
          输入公开账号「{confirmation?.publicHandle}」确认
        </label>
        <Input
          id="confirm-handle"
          value={confirmHandle}
          onChange={(event) => setConfirmHandle(event.target.value)}
          autoComplete="off"
          style={{ marginTop: 8 }}
        />
      </Modal>
    </Layout>
  );
}

function Root() {
  const [identity, setIdentity] = useState<Identity | null>(null);
  const [checking, setChecking] = useState(true);
  const [startupError, setStartupError] = useState("");
  async function check() {
    setChecking(true);
    setStartupError("");
    try {
      setIdentity(await api<Identity>("/session"));
    } catch (error) {
      if (!(error instanceof ApiError && error.status === 401))
        setStartupError(errorMessage(error));
    } finally {
      setChecking(false);
    }
  }
  useEffect(() => {
    void check();
    const expired = () => setIdentity(null);
    window.addEventListener("admin-session-expired", expired);
    return () => window.removeEventListener("admin-session-expired", expired);
  }, []);
  useEffect(() => {
    if (!identity) return;
    const timeout = setTimeout(
      () => setIdentity(null),
      Math.max(0, Date.parse(identity.expiresAt) - Date.now()),
    );
    return () => clearTimeout(timeout);
  }, [identity]);
  return (
    <ConfigProvider
      button={{ autoInsertSpace: false }}
      locale={zhCN}
      theme={{
        token: {
          colorPrimary: "#196c60",
          borderRadius: 8,
          fontFamily:
            'Inter, -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif',
        },
      }}
    >
      <AntApp>
        {checking ? (
          <main className="loading-page">
            <Spin size="large" />
            <Text>正在检查登录状态…</Text>
          </main>
        ) : startupError ? (
          <main className="loading-page">
            <Alert
              type="error"
              title="无法连接管理服务"
              description={startupError}
            />
            <Button onClick={() => void check()}>重新连接</Button>
          </main>
        ) : identity ? (
          <Workspace identity={identity} onLogout={() => setIdentity(null)} />
        ) : (
          <Login onLogin={setIdentity} />
        )}
      </AntApp>
    </ConfigProvider>
  );
}
createRoot(document.getElementById("root")!).render(<Root />);
