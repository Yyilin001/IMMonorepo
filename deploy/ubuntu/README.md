# Ubuntu single-node IMServer deployment

This deployment profile is for one small Ubuntu 24.04 server used for development, demo, or small internal testing.

It installs and runs:

- PostgreSQL on `127.0.0.1:5432`
- Redis on `127.0.0.1:6379`
- Kafka KRaft single node on `127.0.0.1:9092`
- IMServer split roles:
  - `nginx` public HTTP entry on `0.0.0.0:8080`
  - `gateway` HTTP on `127.0.0.1:18080` and TCP `9000`
  - `command-api` on `127.0.0.1:8081`
  - `query-api` on `127.0.0.1:8082`
  - `outbox-relay`
  - `stream-consumer`
- Nginx on port `80`

OpenSearch is disabled by default:

```env
IM_SEARCH_DRIVER=database
```

Kafka is enabled by default:

```env
IM_EVENT_STREAM_DRIVER=kafka
IM_KAFKA_BROKERS=127.0.0.1:9092
IM_KAFKA_SECURITY_PROTOCOL=plaintext
```

## Install

Clone the repo on the server, then run:

```bash
cd /opt/IMMonorepo
sudo bash deploy/ubuntu/00_install_dependencies.sh
sudo bash deploy/ubuntu/10_setup_postgres.sh
sudo bash deploy/ubuntu/20_setup_redis.sh
sudo bash deploy/ubuntu/30_setup_kafka.sh
sudo bash deploy/ubuntu/40_build_imserver.sh
sudo bash deploy/ubuntu/50_install_systemd_units.sh
sudo bash deploy/ubuntu/60_install_nginx.sh
```

Start services:

```bash
sudo systemctl start imserver-command-api
sudo systemctl start imserver-gateway imserver-query-api imserver-outbox-relay imserver-stream-consumer
sudo bash deploy/ubuntu/70_status.sh
```

## Environment

The generated environment file is:

```text
/etc/imserver/common.env
```

The default profile uses:

```env
APP_ENV=development
MEDIA_STORAGE_PROVIDER=local
```

This is intentional for a small test server because production mode requires S3-compatible media storage. Before switching to production, edit `/etc/imserver/common.env`:

```env
APP_ENV=production
MEDIA_STORAGE_PROVIDER=s3compatible
MEDIA_STORAGE_S3_ENDPOINT=...
MEDIA_STORAGE_S3_BUCKET=...
MEDIA_STORAGE_S3_ACCESS_KEY_ID=...
MEDIA_STORAGE_S3_SECRET_ACCESS_KEY=...
```

Then restart:

```bash
sudo systemctl restart imserver-gateway imserver-command-api imserver-query-api imserver-outbox-relay imserver-stream-consumer
```

## Ports

Open these security group ports:

- `80/tcp` for HTTP API through Nginx
- `9000/tcp` for IM TCP connections
- `22/tcp` for SSH

Keep these local only:

- PostgreSQL `5432`
- Redis `6379`
- Kafka `9092`
- internal APIs `8081`, `8082`

For the iOS app, point the HTTP base URL at:

```text
http://<server-public-ip>
```

Point the TCP host/port at:

```text
<server-public-ip>:9000
```

## Test accounts

Development mode seeds these accounts:

- `demo@example.com / password1234`
- `alice@example.com / password1234`
- `bob@example.com / password1234`
- `carol@example.com / password1234`
- `dave@example.com / password1234`
