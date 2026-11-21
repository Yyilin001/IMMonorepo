import { expect, test, type Page } from "@playwright/test";

const userID = "00000000-0000-0000-0000-000000000001";
const user = {
  userID,
  publicHandle: "alice",
  displayName: "测试用户 Alice",
  state: "active",
  accountKind: "regular",
  createdAt: "2026-11-01T08:00:00Z",
  activeDevices: 2,
};
async function fixture(
  page: Page,
  role: "operator" | "viewer" = "operator",
  loseResponse = false,
) {
  let loggedIn = false;
  let disabled = false;
  let disableCount = 0;
  let operationID: string | undefined;
  const identity = {
    username: "ops.primary",
    role,
    expiresAt: new Date(Date.now() + 1800000).toISOString(),
  };
  const audit = () => ({
    sequence: "1",
    operationID,
    principal: "admin:ops.primary",
    action: "account_disable",
    targetUserID: userID,
    reason: "policy_enforcement",
    outcome: disableCount === 1 && loseResponse ? "pending" : "disabled",
    occurredAt: "2026-11-12T00:00:00Z",
    ...(disableCount > 1 || !loseResponse
      ? { completedAt: "2026-11-12T00:00:01Z" }
      : {}),
  });
  await page.route("**/admin/api/**", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname.replace("/admin/api", "");
    expect(request.headers()["x-imv2-admin"]).toBe("1");
    const reply = (body: unknown, status = 200) =>
      route.fulfill({
        status,
        contentType: "application/json",
        body: JSON.stringify(body),
      });
    if (path === "/login") {
      loggedIn = true;
      return reply(identity);
    }
    if (!loggedIn) return reply({ code: "unauthorized" }, 401);
    if (path === "/session") return reply(identity);
    if (path === "/logout") {
      loggedIn = false;
      return route.fulfill({ status: 204 });
    }
    if (path === `/users/${userID}/disable`) {
      expect(role).toBe("operator");
      const body = request.postDataJSON();
      if (operationID) expect(body.operationID).toBe(operationID);
      operationID = body.operationID;
      disabled = true;
      disableCount++;
      if (loseResponse && disableCount === 1)
        return reply({ code: "unavailable" }, 503);
      return reply(audit());
    }
    if (path.startsWith("/audit/"))
      return operationID ? reply(audit()) : reply({ code: "not_found" }, 404);
    if (path === "/audit") return reply(operationID ? [audit()] : []);
    const row = {
      ...user,
      ...(disabled
        ? {
            disabledAt: "2026-11-12T00:00:00Z",
            state: "suspended",
            activeDevices: 0,
          }
        : {}),
    };
    if (path === `/users/${userID}`) return reply(row);
    if (path === "/users")
      return reply(url.searchParams.get("q") === "不存在" ? [] : [row]);
    return reply({ code: "not_found" }, 404);
  });
}
async function login(page: Page) {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "管理员登录" })).toBeVisible();
  await page.getByLabel("管理员账号", { exact: true }).fill("ops.primary");
  await page.getByLabel("密码", { exact: true }).fill("browser-test-password");
  await page.getByRole("button", { name: "登录工作台" }).click();
  await expect(page.getByRole("heading", { name: "用户管理" })).toBeVisible();
  await expect(
    page.getByRole("button", { name: "测试用户 Alice" }),
  ).toBeVisible();
}
async function disable(page: Page) {
  await page.getByRole("button", { name: "禁用", exact: true }).click();
  const modal = page.getByRole("dialog");
  await expect(modal.getByRole("button", { name: "确认禁用" })).toBeDisabled();
  await modal.getByLabel("输入公开账号「alice」确认").fill("alice");
  await modal.getByRole("button", { name: "确认禁用" }).click();
}

test("登录、搜索、详情、禁用、审计和退出", async ({ page }) => {
  await fixture(page);
  await login(page);
  await page.screenshot({path: "test-results/admin-users-preview.png", fullPage: true});
  await page.getByLabel("搜索用户").fill("不存在");
  await page.getByRole("button", { name: "查询", exact: true }).click();
  await expect(page.getByText("没有找到用户，请调整查询条件")).toBeVisible();
  await page.getByLabel("搜索用户").fill("alice");
  await page.getByRole("button", { name: "查询", exact: true }).click();
  await page.getByRole("button", { name: "详情", exact: true }).click();
  await expect(page.getByText("用户详情", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "关闭" }).click();
  await disable(page);
  await expect(
    page.getByRole("button", { name: "禁用", exact: true }),
  ).toBeDisabled();
  await page.getByRole("menuitem", { name: "操作审计" }).click();
  await expect(
    page.getByRole("cell", { name: "admin:ops.primary", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("cell", { name: "已禁用", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "退出", exact: true }).click();
  await expect(page.getByRole("heading", { name: "管理员登录" })).toBeVisible();
});

test("响应丢失后刷新并重试，保留同一个操作编号", async ({ page }) => {
  await fixture(page, "operator", true);
  await login(page);
  await disable(page);
  await expect(page.getByText("有一项禁用操作需要确认结果")).toBeVisible();
  await page.reload();
  await expect(page.getByText("有一项禁用操作需要确认结果")).toBeVisible();
  await page.getByRole("button", { name: "查询结果", exact: true }).click();
  await expect(
    page.getByText(
      "操作结果尚未确认。可以重试原操作；系统会使用同一个操作编号。",
    ),
  ).toBeVisible();
  await page.getByRole("button", { name: "重试原操作", exact: true }).click();
  await expect(page.getByText("有一项禁用操作需要确认结果")).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "禁用", exact: true }),
  ).toBeDisabled();
});

test("只读角色无禁用入口，小屏下仍可查看用户和审计", async ({ page }) => {
  await page.setViewportSize({ width: 768, height: 900 });
  await fixture(page, "viewer");
  await login(page);
  await expect(
    page.getByRole("button", { name: "禁用", exact: true }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: "详情", exact: true }).click();
  await expect(page.getByRole("button", { name: "禁用此账户" })).toHaveCount(0);
  await page.getByRole("button", { name: "查看相关审计" }).click();
  await expect(page.getByRole("heading", { name: "操作审计" })).toBeVisible();
});
