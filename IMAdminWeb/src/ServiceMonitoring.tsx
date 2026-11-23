import { useCallback, useEffect, useRef, useState } from "react";
import {
  Alert,
  Button,
  Card,
  Descriptions,
  Empty,
  Space,
  Spin,
  Tag,
  Typography,
} from "antd";
import { api } from "./api";

const { Title, Text, Paragraph } = Typography;
type Health = "healthy" | "unhealthy" | "unavailable" | "not_deployed";
type Service = {
  id: string;
  name: string;
  status: Health;
  detail: string;
  checkedAt?: string;
  lastSuccessAt?: string;
  latencyMilliseconds?: number;
  ownerCount?: number;
  inFlightOperations?: number;
};
export type MonitoringSnapshot = {
  mode: "local_demo" | "deployment";
  sampledAt: string;
  startedAt: string;
  services: Service[];
  pendingDisables?: string;
  oldestPendingAt?: string;
  pendingSampledAt?: string;
};
const labels: Record<Health, string> = {
  healthy: "正常",
  unhealthy: "异常",
  unavailable: "采集失败",
  not_deployed: "未部署",
};
const colors: Record<Health, string> = {
  healthy: "green",
  unhealthy: "red",
  unavailable: "orange",
  not_deployed: "default",
};
const formatDate = (value?: string) =>
  value ? new Date(value).toLocaleString("zh-CN", { hour12: false }) : "—";
function duration(seconds: number) {
  const value = Math.max(0, Math.floor(seconds));
  if (value < 60) return `${value} 秒`;
  if (value < 3600) return `${Math.floor(value / 60)} 分 ${value % 60} 秒`;
  return `${Math.floor(value / 3600)} 小时 ${Math.floor((value % 3600) / 60)} 分`;
}

export function ServiceMonitoring() {
  const [snapshot, setSnapshot] = useState<MonitoringSnapshot>();
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);
  const [clock, setClock] = useState(Date.now());
  const [hidden, setHidden] = useState(document.hidden);
  const mounted = useRef(false);
  const active = useRef<AbortController | null>(null);
  const refresh = useCallback(async () => {
    if (active.current) return;
    const controller = new AbortController();
    active.current = controller;
    setLoading(true);
    const timeout = window.setTimeout(() => controller.abort(), 8000);
    try {
      const value = await api<MonitoringSnapshot>(
        "/monitoring",
        undefined,
        controller.signal,
      );
      if (mounted.current) {
        setSnapshot(value);
        setFailed(false);
        setClock(Date.now());
      }
    } catch {
      if (mounted.current) setFailed(true);
    } finally {
      window.clearTimeout(timeout);
      active.current = null;
      if (mounted.current) setLoading(false);
    }
  }, []);
  useEffect(() => {
    mounted.current = true;
    void refresh();
    const poll = window.setInterval(() => {
      if (!document.hidden) void refresh();
    }, 15000);
    const tick = window.setInterval(() => setClock(Date.now()), 1000);
    const visibility = () => {
      setHidden(document.hidden);
      if (!document.hidden) void refresh();
    };
    document.addEventListener("visibilitychange", visibility);
    return () => {
      mounted.current = false;
      active.current?.abort();
      window.clearInterval(poll);
      window.clearInterval(tick);
      document.removeEventListener("visibilitychange", visibility);
    };
  }, [refresh]);
  const tooOld = !!snapshot && clock - Date.parse(snapshot.sampledAt) > 30000;
  const stale = failed || tooOld;
  const currentServices =
    snapshot?.services.filter((service) => service.status !== "not_deployed") ??
    [];
  const healthy = currentServices.filter(
    (service) => service.status === "healthy",
  ).length;
  const pendingAvailable = !stale && snapshot?.pendingDisables !== undefined;
  const policy = snapshot?.services.find((service) => service.id === "policy");
  const mode = snapshot?.mode === "local_demo";
  return (
    <section aria-label="服务监控">
      <div className="page-heading">
        <div>
          <Text className="eyebrow">SERVICE HEALTH</Text>
          <Title level={2}>服务监控</Title>
          <Paragraph type="secondary">
            查看当前服务可用性与待处理操作，及时发现异常。
          </Paragraph>
        </div>
        <Button
          aria-label="刷新监控"
          loading={loading}
          disabled={loading}
          onClick={() => void refresh()}
        >
          刷新监控
        </Button>
      </div>
      <div className="monitor-meta">
        <Space wrap>
          <Tag>
            {snapshot ? (mode ? "本地演示环境" : "部署环境") : "等待环境信息"}
          </Tag>
          <Text type="secondary">
            {hidden ? "页面不可见，自动刷新已暂停" : "每 15 秒自动刷新"}
          </Text>
        </Space>
        <Text type="secondary">
          最近采集：{formatDate(snapshot?.sampledAt)}
        </Text>
      </div>
      {stale && (
        <Alert
          className="block-gap"
          showIcon
          type="warning"
          title={failed ? "无法获取最新监控数据" : "监控数据已过期"}
          description="当前状态无法确认。下面保留上次采集时间，历史结果不代表服务仍然正常；连接恢复后会自动重新检查。"
        />
      )}
      {!snapshot ? (
        loading ? (
          <div className="monitor-loading">
            <Spin />
            <Text>正在检查服务状态…</Text>
          </div>
        ) : (
          <Empty description="尚未取得监控数据，请刷新重试" />
        )
      ) : (
        <>
          <div className="monitor-stats">
            <Card>
              <Text type="secondary">服务可用性</Text>
              <div className="monitor-number">
                {stale ? "未知" : `${healthy} / ${currentServices.length}`}
              </div>
              <Text type="secondary">
                {stale ? "等待新的检查结果" : "已接入检查的服务正常"}
              </Text>
            </Card>
            <Card>
              <Text type="secondary">监控运行时间</Text>
              <div className="monitor-number">
                {stale
                  ? "—"
                  : duration(
                      (Date.parse(snapshot.sampledAt) -
                        Date.parse(snapshot.startedAt)) /
                        1000,
                    )}
              </div>
              <Text type="secondary">截至最近一次成功采集</Text>
            </Card>
            <Card>
              <Text type="secondary">待确认的禁用操作</Text>
              <div className="monitor-number" data-testid="pending-count">
                {pendingAvailable ? snapshot.pendingDisables : "—"}
              </div>
              <Text type="secondary">
                {pendingAvailable
                  ? "需要查询结果或接续原操作"
                  : "数量未知，未作为零处理"}
              </Text>
            </Card>
          </div>
          {pendingAvailable && snapshot.pendingDisables !== "0" && (
            <Alert
              className="block-gap"
              type="warning"
              showIcon
              title={`有 ${snapshot.pendingDisables} 项禁用操作等待确认`}
              description={
                <Space wrap>
                  <Text>最早登记：{formatDate(snapshot.oldestPendingAt)}</Text>
                  <a href="#audit">前往操作审计</a>
                </Space>
              }
            />
          )}
          <div className="monitor-services">
            {snapshot.services.map((service) => {
              const expired =
                service.status !== "not_deployed" &&
                (stale ||
                  (!!service.checkedAt &&
                    clock - Date.parse(service.checkedAt) > 30000));
              return (
                <Card
                  key={service.id}
                  data-testid={`service-${service.id}`}
                  title={service.name}
                  extra={
                    <Tag color={expired ? "orange" : colors[service.status]}>
                      {expired ? "状态待确认" : labels[service.status]}
                    </Tag>
                  }
                >
                  <Paragraph type="secondary">{service.detail}</Paragraph>
                  <Descriptions
                    size="small"
                    column={1}
                    items={[
                      {
                        key: "checked",
                        label: "本次检查",
                        children: formatDate(service.checkedAt),
                      },
                      {
                        key: "last",
                        label: "最近正常",
                        children: formatDate(service.lastSuccessAt),
                      },
                      {
                        key: "latency",
                        label: "检查耗时",
                        children:
                          !expired && service.latencyMilliseconds !== undefined
                            ? `${service.latencyMilliseconds.toFixed(1)} ms`
                            : "—",
                      },
                    ]}
                  />
                  {service.id === "policy" &&
                    service.ownerCount !== undefined && (
                      <div className="monitor-policy">
                        <Text type="secondary">
                          策略实例：{expired ? "—" : policy?.ownerCount}
                          　进行中操作：
                          {expired ? "—" : policy?.inFlightOperations}
                        </Text>
                      </div>
                    )}
                </Card>
              );
            })}
          </div>
          <Paragraph type="secondary" className="footer-note">
            {mode
              ? "本地检查覆盖管理 API、PostgreSQL 和进程内策略目录；账户服务、消息网关及远程 Actor 集群未启动。"
              : "远程检查覆盖账户鉴权入口、网关协议握手、策略目录及 Actor 分片多数派。"}{" "}
            此页不执行业务写入。管理服务停止时，页面只能报告采集失败；持续告警需要独立监控服务。
          </Paragraph>
        </>
      )}
    </section>
  );
}
