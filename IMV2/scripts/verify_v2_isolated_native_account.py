#!/usr/bin/env python3
"""Disposable native HTTPS/account/gateway smoke. Never reads .env or changes trust stores."""
import argparse, base64, http.client, http.server, json, os, re, secrets, signal, socket, ssl
import subprocess, tempfile, threading, time, urllib.error, urllib.request, uuid
from pathlib import Path
import yaml

REPO = Path(__file__).resolve().parents[2]
PG = Path('/opt/homebrew/opt/postgresql@16/bin')

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]

def run(args, **kwargs):
    return subprocess.run(list(map(str,args)), check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check',action='store_true',help='Check dependencies without starting processes or creating configuration.')
    parser.add_argument('--hold-seconds',type=int,default=0,help='Keep only this isolated stack alive for an additional test window (max 900s).')
    args=parser.parse_args()
    if not 0 <= args.hold_seconds <= 900: parser.error('hold must be 0...900 seconds')
    required=[PG/name for name in ['initdb','pg_ctl','createdb','psql']]
    required += [REPO/'IMV2Server/.build/debug'/name for name in ['IMV2AccountServerApp','IMV2ServerApp','IMV2LocalGatewayProbe']]
    missing=[str(path) for path in required if not path.is_file() or not os.access(path,os.X_OK)]
    if missing: parser.error('missing executable: '+', '.join(missing))
    if args.check:
        print('isolated native E2E prerequisites available; no services started or trust stores modified')
        return
    def interrupted(_signal,_frame): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,interrupted)
    os.umask(0o077)
    root=Path(tempfile.mkdtemp(prefix='imv2-native-e2e-'))
    processes=[]; logs=[]; pg_started=False; edge=None
    ports={key:port() for key in ['pg','account','edge','gateway','actor_gateway','actor_account','metrics']}
    if len(set(ports.values())) != len(ports): raise RuntimeError('port collision; rerun')
    print('isolated E2E root='+str(root),flush=True)
    try:
        run([PG/'initdb','-D',root/'pg','--auth=trust','--username=imv2_e2e','--no-locale'])
        run([PG/'pg_ctl','-D',root/'pg','-l',root/'postgres.log','-o',f'-h 127.0.0.1 -p {ports["pg"]} -k {root}','-w','start']); pg_started=True
        run([PG/'createdb','-h','127.0.0.1','-p',ports['pg'],'-U','imv2_e2e','imv2_e2e'])
        run([PG/'psql','-h','127.0.0.1','-p',ports['pg'],'-U','imv2_e2e','-d','imv2_e2e','-v','ON_ERROR_STOP=1','-f',REPO/'IMV2/sql/schema.sql'])
        run([PG/'psql','-h','127.0.0.1','-p',ports['pg'],'-U','imv2_e2e','-d','imv2_e2e','-v','ON_ERROR_STOP=1','-c',f"INSERT INTO im_v2.shard_admission_pools(room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit) VALUES ('rooms-primary','standard','{uuid.uuid4()}',1,CURRENT_TIMESTAMP+INTERVAL '1 hour',1000)"])
        run(['python3',REPO/'IMV2/scripts/prepare_v2_room_actor_configuration.py','--output-dir',root/'actors','--host',f'gateway=localhost:{ports["actor_gateway"]}','--caller',f'account=localhost:{ports["actor_account"]}','--shards','rooms-primary'])
        ca=root/'actors/ca/cert.pem'; cert=root/'actors/gateway/tls.pem'; key=root/'actors/gateway/tls.key'
        composition=yaml.safe_load((REPO/'IMV2/docker-compose.local-account.yml').read_text())['services']
        secret_names=re.findall(r"printf '([A-Z0-9_]+)=%s",(REPO/'IMV2/scripts/run_v2_local_account_stack.sh').read_text())
        generated={name:base64.b64encode(secrets.token_bytes(32)).decode() for name in secret_names}
        base={k:v for k,v in os.environ.items() if not k.startswith(('IM_V2_','IMV2_'))}
        def environment(service):
            values=dict(base); values.update(generated)
            for k,v in composition[service]['environment'].items():
                def expand(match):
                    name,default=match.group(1),match.group(2)
                    return generated.get(name,default or '')
                values[k]=re.sub(r'\$\{([A-Z0-9_]+)(?::[-?]([^}]*))?\}',expand,str(v))
            database=f'postgres://imv2_e2e@127.0.0.1:{ports["pg"]}/imv2_e2e'
            values.update(IM_V2_DATABASE_URL=database,
                IM_V2_ROOM_SHARD_STORES_JSON=json.dumps([{'shard_id':'rooms-primary','database_url':database,'schema':'im_v2'}]),
                IM_V2_USER_SHARD_STORES_JSON=json.dumps([{'bucket':'users-primary','database_url':database,'schema':'im_v2'}]),
                IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(root/'actors'/service/'configuration.json'),
                IM_V2_LOCAL_MEDIA_ROOT_DIRECTORY=str(root/'media'),IM_V2_LOCAL_MEDIA_PUBLIC_BASE_URL=f'https://localhost:{ports["edge"]}',
                IM_V2_ACCOUNT_LISTEN_PORT=str(ports['account']),IM_V2_TLS_HOST='127.0.0.1',IM_V2_TLS_PORT=str(ports['gateway']),
                IM_V2_TLS_CERTIFICATE_CHAIN_PATH=str(cert),IM_V2_TLS_PRIVATE_KEY_PATH=str(key),IM_V2_METRICS_PORT=str(ports['metrics']))
            return values
        account_env=environment('account')
        def spawn(name,binary,env):
            log=(root/(name+'.log')).open('wb');logs.append(log)
            process=subprocess.Popen([str(binary)],env=env,stdout=log,stderr=subprocess.STDOUT);processes.append(process);return process
        spawn('account',REPO/'IMV2Server/.build/debug/IMV2AccountServerApp',account_env)
        spawn('gateway',REPO/'IMV2Server/.build/debug/IMV2ServerApp',environment('gateway'))
        def wait_listener(number):
            deadline=time.monotonic()+90
            while time.monotonic()<deadline:
                if any(p.poll() is not None for p in processes): raise RuntimeError('native service exited; inspect isolated log')
                try:
                    with socket.create_connection(('127.0.0.1',number),timeout=.2): return
                except OSError: time.sleep(.2)
            raise RuntimeError('native service readiness timeout')
        wait_listener(ports['account']);wait_listener(ports['gateway'])
        class Edge(http.server.BaseHTTPRequestHandler):
            protocol_version='HTTP/1.1'
            def log_message(self,*_): pass
            def do_POST(self):
                length=int(self.headers.get('Content-Length','0'))
                if not 0 <= length <= 1024*1024: self.send_error(413);return
                body=self.rfile.read(length)
                # Never forward user-supplied edge authorization/address proof.
                headers={k:v for k,v in self.headers.items() if k.lower() not in {'host','connection','transfer-encoding','x-im-v2-account-edge-authorization','x-im-v2-account-client-address'}}
                headers['X-IM-V2-Account-Edge-Authorization']=account_env['IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64']
                headers['X-IM-V2-Account-Client-Address']=self.client_address[0]
                connection=http.client.HTTPConnection('127.0.0.1',ports['account'],timeout=30)
                try:
                    connection.request('POST',self.path,body,headers);response=connection.getresponse();data=response.read(1024*1024+1)
                    if len(data)>1024*1024: self.send_error(502);return
                    self.send_response(response.status)
                    for k,v in response.getheaders():
                        if k.lower() not in {'connection','transfer-encoding','content-length'}: self.send_header(k,v)
                    self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
                finally: connection.close()
        edge=http.server.ThreadingHTTPServer(('127.0.0.1',ports['edge']),Edge)
        server_tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);server_tls.minimum_version=ssl.TLSVersion.TLSv1_2;server_tls.load_cert_chain(cert,key)
        edge.socket=server_tls.wrap_socket(edge.socket,server_side=True)
        threading.Thread(target=edge.serve_forever,daemon=True).start()
        client_tls=ssl.create_default_context(cafile=str(ca))
        def post(path,body):
            request=urllib.request.Request(f'https://localhost:{ports["edge"]}'+path,data=json.dumps(body).encode(),headers={'Content-Type':'application/json'},method='POST')
            with urllib.request.urlopen(request,context=client_tls,timeout=30) as response:
                if response.status != 200: raise RuntimeError('unexpected account HTTP status')
                return json.load(response)
        device=str(uuid.uuid4()).upper();operation=str(uuid.uuid4()).upper();suffix=uuid.uuid4().hex[:20]
        registration=post('/v2/account-auth/password/register',{'accountHandle':'e2e_'+suffix,'publicHandle':'e2e'+suffix,'displayName':'Isolated native E2E','password':'isolated-e2e-password','deviceID':device})
        cancellation={'deviceID':device,'operationID':operation,'proof':'imv2-cancel-registration-v1.'+base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip('='),'issueBeforeMilliseconds':int((time.time()+600)*1000)}
        issued=post('/v2/device-credentials',{'accountAssertion':registration['accountAssertion'],'deviceID':device,'operationID':operation,'cancellation':cancellation})
        probe=dict(base,IM_V2_GATEWAY_PROBE_ACCOUNT_BASE_URL=f'https://localhost:{ports["edge"]}',IM_V2_GATEWAY_PROBE_ACCESS_TOKEN=issued['accessToken'],IM_V2_GATEWAY_PROBE_DEVICE_ID=device,
            IM_V2_GATEWAY_PROBE_HOST='127.0.0.1',IM_V2_GATEWAY_PROBE_PORT=str(ports['gateway']),IM_V2_GATEWAY_PROBE_CA_PATH=str(ca),IM_V2_GATEWAY_PROBE_SERVER_NAME='localhost')
        outcome=run([REPO/'IMV2Server/.build/debug/IMV2LocalGatewayProbe'],env=probe,timeout=30)
        if b'current protocol verified' not in outcome.stdout: raise RuntimeError('gateway authentication proof missing')
        config={'httpsBaseURL':f'https://localhost:{ports["edge"]}','gatewayHost':'localhost','gatewayPort':ports['gateway'],'caPath':str(ca)}
        (root/'test-endpoints.json').write_text(json.dumps(config))
        print('PASS independent PG + HTTPS registration + credential issue + native TLS gateway authentication',flush=True)
        if args.hold_seconds:
            print('test endpoint config='+str(root/'test-endpoints.json'),flush=True)
            deadline=time.monotonic()+args.hold_seconds
            while time.monotonic()<deadline and not (root/'stop').exists(): time.sleep(.5)
    finally:
        if edge: edge.shutdown();edge.server_close()
        for process in reversed(processes):
            if process.poll() is None: process.terminate()
        for process in reversed(processes):
            try: process.wait(timeout=75)
            except subprocess.TimeoutExpired: process.kill();process.wait()
        for log in logs: log.close()
        if pg_started: run([PG/'pg_ctl','-D',root/'pg','-m','fast','-w','stop'])
        print('owned stack stopped; diagnostics retained at '+str(root),flush=True)

if __name__=='__main__': main()
