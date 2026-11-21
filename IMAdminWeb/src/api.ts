export type Identity = {
  username: string;
  role: "viewer" | "operator";
  expiresAt: string;
};
export type User = {
  userID: string;
  publicHandle: string;
  displayName: string;
  state: string;
  accountKind: string;
  createdAt: string;
  disabledAt?: string;
  activeDevices: number;
};
export type Reason =
  "user_requested" | "credential_compromise" | "policy_enforcement";
export type Audit = {
  sequence: string;
  operationID: string;
  principal?: string;
  action: string;
  targetUserID?: string;
  reason?: Reason;
  outcome: string;
  occurredAt: string;
  completedAt?: string;
};
export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
  ) {
    super(code);
  }
}
const messages: Record<string, string> = {
  unauthorized: "账号或密码不正确，或登录状态已失效。",
  forbidden: "当前账号没有执行此操作的权限。",
  invalid_input: "输入格式不正确，请检查后重试。",
  not_found: "未找到对应记录。",
  operation_conflict: "操作编号与既有记录冲突，请查看操作审计。",
  rate_limited: "登录尝试过于频繁，请在一分钟后重试。",
  unavailable:
    "服务暂时不可用。已提交操作的结果可能尚未确认，请查询审计或重试原操作。",
};
export function errorMessage(error: unknown) {
  return error instanceof ApiError
    ? (messages[error.code] ?? "请求未完成，请稍后重试。")
    : "网络连接中断，请检查连接后重试。";
}
export async function api<T>(
  path: string,
  body?: unknown,
  signal?: AbortSignal,
): Promise<T> {
  const response = await fetch(`/admin/api${path}`, {
    method: body === undefined ? "GET" : "POST",
    credentials: "same-origin",
    cache: "no-store",
    headers: {
      "X-IMV2-Admin": "1",
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: signal ?? AbortSignal.timeout(20_000),
  });
  if (!response.ok) {
    const data = await response.json().catch(() => ({ code: "unavailable" }));
    if (response.status === 401 && path !== "/login")
      window.dispatchEvent(new Event("admin-session-expired"));
    throw new ApiError(response.status, data.code ?? "unavailable");
  }
  return response.status === 204 ? (undefined as T) : response.json();
}
