#!/usr/bin/env python3
"""本机管理后台演示：独立 PostgreSQL、真实管理接口与 Vite，保留数据并支持停止。"""
import argparse
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / "IMV2/local-admin"
PG = Path(os.environ.get("IMV2_ADMIN_TEST_PG_BIN", "/opt/homebrew/opt/postgresql@16/bin"))
BINARY = ROOT / "IMV2Server/.build/debug/IMV2AdminServerApp"


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def read_json(name):
    return json.loads((STATE / name).read_text())


def write_json(name, value):
    path = STATE / name
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    path.chmod(0o600)


def owns_process(pid, expected):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    return result.returncode == 0 and expected in result.stdout


def stop():
    if not (STATE / "processes.json").exists():
        print("本地演示没有已登记的服务。")
        return
    for item in read_json("processes.json").values():
        if owns_process(item["pid"], item["expected"]):
            os.kill(item["pid"], signal.SIGTERM)
    for _ in range(60):
        if not any(owns_process(x["pid"], x["expected"]) for x in read_json("processes.json").values()):
            break
        time.sleep(0.2)
    else:
        raise RuntimeError("管理进程尚未排空；保留数据库供其完成，不强制终止。")
    subprocess.run([str(PG / "pg_ctl"), "-D", str(STATE / "pgdata"), "-m", "fast", "stop"], check=False)
    print("服务已停止，测试账户和审计数据保留。")


def check_port(port):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", port))


def wait_url(url, expected_status, process):
    for _ in range(120):
        if process.poll() is not None:
            raise RuntimeError("服务提前退出，请查看 IMV2/local-admin 下的日志。")
        try:
            request = urllib.request.Request(url, headers={"X-IMV2-Admin": "1"})
            with urllib.request.urlopen(request, timeout=1) as response:
                if response.status == expected_status:
                    return
        except urllib.error.HTTPError as error:
            if error.code == expected_status:
                return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.5)
    raise RuntimeError("等待服务就绪超时。")


def start(skip_build):
    STATE.mkdir(parents=True, exist_ok=True)
    STATE.chmod(0o700)
    if (STATE / "processes.json").exists():
        if any(owns_process(x["pid"], x["expected"]) for x in read_json("processes.json").values()):
            print("服务已运行或部分运行；需要重启时先执行 stop。")
            return
    check_port(5173)
    check_port(9446)
    if not skip_build:
        run(["swift", "build", "--package-path", ROOT / "IMV2Server", "--product", "IMV2AdminServerApp", "--jobs", "4"])
    if not (ROOT / "IMAdminWeb/node_modules/vite/bin/vite.js").exists():
        run(["npm", "ci"], cwd=ROOT / "IMAdminWeb")
    if not (STATE / "database.json").exists():
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        write_json("database.json", {"port": port, "database": "im_v2_admin_local"})
    config = read_json("database.json")
    port = config["port"]
    with (STATE / "setup.log").open("a") as log:
        if not (STATE / "pgdata/PG_VERSION").exists():
            run([PG / "initdb", "-D", STATE / "pgdata", "--auth=trust", "--no-locale", "--encoding=UTF8"], stdout=log, stderr=log)
        running = subprocess.run([str(PG / "pg_ctl"), "-D", str(STATE / "pgdata"), "status"], capture_output=True).returncode == 0
        if not running:
            check_port(port)
            run([PG / "pg_ctl", "-D", STATE / "pgdata", "-l", STATE / "postgres.log", "-o", f"-h 127.0.0.1 -p {port} -k /tmp", "start"], stdout=log, stderr=log)
        base = [PG / "psql", "-h", "127.0.0.1", "-p", str(port), "-v", "ON_ERROR_STOP=1"]
        exists = run(base + ["-d", "postgres", "-Atc", "SELECT 1 FROM pg_database WHERE datname='im_v2_admin_local'"], capture_output=True, text=True).stdout.strip()
        if exists != "1":
            run([PG / "createdb", "-h", "127.0.0.1", "-p", str(port), "im_v2_admin_local"], stdout=log, stderr=log)
        psql = base + ["-d", "im_v2_admin_local"]
        for schema, filename in [("im_v2", "schema.sql"), ("im_admin", "admin-schema.sql")]:
            exists = run(psql + ["-Atc", f"SELECT to_regnamespace('{schema}') IS NOT NULL"], capture_output=True, text=True).stdout.strip()
            if exists != "t":
                run(psql + ["-f", ROOT / "IMV2/sql" / filename], stdout=log, stderr=log)
        run(psql, input="""
            INSERT INTO im_v2.public_user_profiles(user_id, public_handle, display_name, created_at, updated_at)
            VALUES ('00000000-0000-0000-0000-000000ad0001','demo_alice','演示用户 · Alice',now(),now()),
                   ('00000000-0000-0000-0000-000000ad0002','demo_bob','演示用户 · Bob',now(),now()),
                   ('00000000-0000-0000-0000-000000ad0003','demo_verify','流程验证用户',now(),now())
            ON CONFLICT DO NOTHING;
            INSERT INTO im_v2.auth_devices(user_id,device_id,display_name,platform,created_at,last_active_at)
            VALUES ('00000000-0000-0000-0000-000000ad0001','00000000-0000-0000-0000-000000dd0001','演示 iPhone','iOS',now(),now()),
                   ('00000000-0000-0000-0000-000000ad0002','00000000-0000-0000-0000-000000dd0002','演示 Android','Android',now(),now()),
                   ('00000000-0000-0000-0000-000000ad0003','00000000-0000-0000-0000-000000dd0003','流程验证设备','test',now(),now())
            ON CONFLICT DO NOTHING;
            """, text=True, stdout=log, stderr=log)
    if not (STATE / "accounts.json").exists():
        password = "Local-" + secrets.token_urlsafe(18)
        digest = run([BINARY, "--hash-password"], input=password + "\n", capture_output=True, text=True).stdout.strip()
        write_json("accounts.json", [{"username": "local.admin", "passwordHash": digest, "role": "operator"}])
        write_json("credentials.json", {"username": "local.admin", "password": password, "url": "http://127.0.0.1:5173"})
    environment = dict(os.environ, IMV2_ADMIN_LOCAL_DEMO="1",
        IMV2_ADMIN_LOCAL_DATABASE_URL=f"postgres://{os.environ['USER']}@127.0.0.1:{port}/im_v2_admin_local?sslmode=disable",
        IM_V2_ADMIN_ACCOUNTS_FILE=str(STATE / "accounts.json"))
    processes = {}
    with (STATE / "admin.log").open("a") as log:
        admin = subprocess.Popen([str(BINARY), "--local-demo"], env=environment, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    processes["admin"] = {"pid": admin.pid, "expected": "IMV2AdminServerApp --local-demo"}
    write_json("processes.json", processes)
    wait_url("http://127.0.0.1:9446/admin/api/session", 401, admin)
    vite_path = ROOT / "IMAdminWeb/node_modules/vite/bin/vite.js"
    with (STATE / "web.log").open("a") as log:
        web = subprocess.Popen(["node", str(vite_path), "--host", "127.0.0.1"], cwd=ROOT / "IMAdminWeb", stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    processes["web"] = {"pid": web.pid, "expected": str(vite_path)}
    write_json("processes.json", processes)
    wait_url("http://127.0.0.1:5173", 200, web)
    print("管理后台已启动：http://127.0.0.1:5173")
    print("管理员凭据保存于 IMV2/local-admin/credentials.json（仅当前用户可读）。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["start", "stop"])
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    if args.action == "start":
        start(args.skip_build)
    else:
        stop()
