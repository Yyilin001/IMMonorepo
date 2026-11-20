import { expect, test } from "@playwright/test";
import type { MonitoringSnapshot } from "../src/ServiceMonitoring";
function sample(): MonitoringSnapshot {
  const now = new Date().toISOString();
  return {
    mode: "local_demo",
    sampledAt: now,
    startedAt: new Date(Date.now() - 120000).toISOString(),
    pendingDisables: "0",
    pendingSampledAt: now,
    services: [
      ...[
        { id: "admin", name: "管理 API" },
        { id: "postgres", name: "PostgreSQL" },
        { id: "policy", name: "Policy Owner" },
      ].map((value) => ({
        ...value,
        status: "healthy" as const,
        detail: "真实检查完成",
        checkedAt: now,
        lastSuccessAt: now,
        latencyMilliseconds: 1.5,
      })),
      ...[
        { id: "account", name: "账户服务" },
        { id: "gateway", name: "消息网关" },
        { id: "actors", name: "远程 Actor 集群" },
      ].map((value) => ({
        ...value,
        status: "not_deployed" as const,
        detail: "本地演示未启动该服务",
      })),
    ],
  };
}
test("监控真实状态映射、采集失败不显示历史绿色、恢复后重新显示结果", async ({
  page,
}) => {
  let fail = false;
  await page.route("**/admin/api/**", (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith("/session"))
      return route.fulfill({
        json: {
          username: "reader",
          role: "viewer",
          expiresAt: new Date(Date.now() + 1800000).toISOString(),
        },
      });
    if (path.endsWith("/monitoring"))
      return fail
        ? route.fulfill({ status: 503, json: { code: "unavailable" } })
        : route.fulfill({ json: sample() });
    return route.fulfill({ status: 404 });
  });
  await page.goto("/#monitoring");
  await expect(
    page.getByRole("heading", { name: "服务监控", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByTestId("service-postgres").getByText("正常", { exact: true }),
  ).toBeVisible();
  await expect(page.getByText("未部署", { exact: true })).toHaveCount(3);
  await expect(page.getByTestId("pending-count")).toHaveText("0");
  fail = true;
  await page.getByRole("button", { name: "刷新监控", exact: true }).click();
  await expect(
    page.getByText("无法获取最新监控数据", { exact: true }),
  ).toBeVisible();
  await expect(page.getByTestId("pending-count")).toHaveText("—");
  await expect(
    page
      .getByTestId("service-postgres")
      .getByText("状态待确认", { exact: true }),
  ).toBeVisible();
  await expect(page.getByText("正常", { exact: true })).toHaveCount(0);
  fail = false;
  await page.getByRole("button", { name: "刷新监控", exact: true }).click();
  await expect(
    page.getByTestId("service-postgres").getByText("正常", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("无法获取最新监控数据", { exact: true }),
  ).toHaveCount(0);
});

test("过期快照和未知积压不会显示为健康或零", async ({ page }) => {
  const value = sample();
  value.sampledAt = new Date(Date.now() - 60000).toISOString();
  delete value.pendingDisables;
  await page.route("**/admin/api/**", (route) =>
    route.fulfill({
      json: new URL(route.request().url()).pathname.endsWith("/session")
        ? {
            username: "reader",
            role: "viewer",
            expiresAt: new Date(Date.now() + 1800000).toISOString(),
          }
        : value,
    }),
  );
  await page.goto("/#monitoring");
  await expect(page.getByText("监控数据已过期", { exact: true })).toBeVisible();
  await expect(page.getByTestId("pending-count")).toHaveText("—");
  await expect(page.getByText("正常", { exact: true })).toHaveCount(0);
  await expect(page.getByText("未部署", { exact: true })).toHaveCount(3);
});
