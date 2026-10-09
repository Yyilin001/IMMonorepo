#!/usr/bin/env python3
"""Disposable native HTTPS/account/gateway smoke. Never reads .env or changes trust stores."""
import argparse, base64, collections, hashlib, http.client, http.server, json, os, re, secrets, signal, socket, ssl
import shlex, subprocess, tempfile, threading, time, urllib.error, urllib.parse, urllib.request, uuid
from pathlib import Path
import yaml
from v2_native_background_upload_gate import NativeBackgroundUploadGate

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
    parser.add_argument('--two-install-ui',action='store_true',help='Run the existing real two-install App scenario against this disposable native stack.')
    parser.add_argument('--multi-device-ui',action='store_true',help='Run real same-account multi-device App stages and owned Operator snapshot reset.')
    parser.add_argument('--account-switch-ui',action='store_true',help='Run real App sign-out, account switching and cold restoration isolation.')
    parser.add_argument('--read-receipt-ui',action='store_true',help='Run independent App direct delivery and peer-read cold restoration.')
    parser.add_argument('--group-read-ui',action='store_true',help='Run independent App group readers presentation after actual member reading.')
    parser.add_argument('--group-join-ui',action='store_true',help='Run independent App invite QR, actual join submission/cancellation/approval.')
    parser.add_argument('--receiver-simulator',help='Explicitly owned, booted receiver simulator for --two-install-ui.')
    parser.add_argument('--sender-simulator',help='Explicitly owned, booted sender simulator for --two-install-ui.')
    args=parser.parse_args()
    if os.environ.get('IMAPP_LOCAL_TWO_INSTALL_BACKGROUND_UPLOAD_ONLY') == 'true':
        if not args.two_install_ui:
            parser.error('native background upload requires --two-install-ui')
        if any(os.environ.get(name) == 'true' for name in (
                'IMAPP_LOCAL_TWO_INSTALL_MEMBER_DIRECTORY_ONLY',
                'IMAPP_LOCAL_TWO_INSTALL_CREDENTIAL_REFRESH_ONLY',
                'IMAPP_LOCAL_TWO_INSTALL_DIRECT_EDIT_ONLY')):
            parser.error('native background upload must run as an independent scenario')
    if not 0 <= args.hold_seconds <= 900: parser.error('hold must be 0...900 seconds')
    if sum([args.two_install_ui,args.multi_device_ui,args.account_switch_ui,args.read_receipt_ui,args.group_read_ui,args.group_join_ui]) > 1: parser.error('UI modes are mutually exclusive')
    ui_requested=args.two_install_ui or args.multi_device_ui or args.account_switch_ui or args.read_receipt_ui or args.group_read_ui or args.group_join_ui
    if ui_requested:
        if not args.receiver_simulator or not args.sender_simulator or args.receiver_simulator == args.sender_simulator:
            parser.error('two-install UI requires two distinct, explicitly selected simulator IDs')
        if not ssl.HAS_TLSv1_3: parser.error('two-install UI requires a Python runtime with TLS 1.3')
        # The existing App scenario uses these local endpoints. Refuse an occupied
        # endpoint instead of sending test traffic to an unrelated running stack.
        for endpoint in (8443,7443):
            with socket.socket() as listener:
                listener.bind(('127.0.0.1',endpoint))
    required=[PG/name for name in ['initdb','pg_ctl','createdb','psql']]
    required += [REPO/'IMV2Server/.build/debug'/name for name in ['IMV2AccountServerApp','IMV2ServerApp','IMV2LocalGatewayProbe']]
    if args.multi_device_ui: required.append(REPO/'IMV2Server/.build/debug/IMV2OperatorServerApp')
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
    http_responses=collections.Counter(); http_lock=threading.Lock()
    app_refresh_mode=os.environ.get('IMAPP_LOCAL_TWO_INSTALL_CREDENTIAL_REFRESH_ONLY') == 'true'
    background_upload_mode=os.environ.get('IMAPP_LOCAL_TWO_INSTALL_BACKGROUND_UPLOAD_ONLY') == 'true'
    background_gate=NativeBackgroundUploadGate() if background_upload_mode else None
    background_fixture_token=secrets.token_hex(32) if background_upload_mode else None
    refresh_diagnostics=dict(armed=False,injected=0,refreshResponses=0,coldRestore=False,coldFreshDeviceReads=0)
    refresh_digest=[None]  # Process-private comparison only; never exported.
    ports={key:port() for key in ['pg','account','edge','gateway','actor_gateway','actor_account','metrics']}
    if ui_requested: ports.update(edge=8443,gateway=7443)
    if args.multi_device_ui: ports['operator']=port()
    if len(set(ports.values())) != len(ports): raise RuntimeError('port collision; rerun')
    print('isolated E2E root='+str(root),flush=True)
    try:
        run([PG/'initdb','-D',root/'pg','--auth=trust','--username=imv2_e2e','--no-locale'])
        run([PG/'pg_ctl','-D',root/'pg','-l',root/'postgres.log','-o',f'-h 127.0.0.1 -p {ports["pg"]} -k {root}','-w','start']); pg_started=True
        run([PG/'createdb','-h','127.0.0.1','-p',ports['pg'],'-U','imv2_e2e','imv2_e2e'])
        run([PG/'psql','-h','127.0.0.1','-p',ports['pg'],'-U','imv2_e2e','-d','imv2_e2e','-v','ON_ERROR_STOP=1','-f',REPO/'IMV2/sql/schema.sql'])
        run([PG/'psql','-h','127.0.0.1','-p',ports['pg'],'-U','imv2_e2e','-d','imv2_e2e','-v','ON_ERROR_STOP=1','-f',REPO/'IMV2/sql/realtime-change-journal.sql'])
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
        if args.multi_device_ui:
            operator_env=environment('operator');operator_env.pop('IMV2_ROOM_ACTOR_CONFIGURATION_FILE',None)
            operator_env.update(IM_V2_OPERATOR_REPLAY_LISTEN_HOST='127.0.0.1',IM_V2_OPERATOR_REPLAY_LISTEN_PORT=str(ports['operator']))
            spawn('operator',REPO/'IMV2Server/.build/debug/IMV2OperatorServerApp',operator_env)
            wait_listener(ports['operator'])
        class Edge(http.server.BaseHTTPRequestHandler):
            protocol_version='HTTP/1.1'
            def log_message(self,*_): pass
            def dispatch(self):
                length=int(self.headers.get('Content-Length','0'))
                if not 0 <= length <= 1024*1024: self.send_error(413);return
                path=urllib.parse.urlsplit(self.path).path
                if background_gate is not None and path.startswith('/__fixture__/background-upload/'):
                    if self.headers.get('X-Background-Fixture') != background_fixture_token or length != 0:
                        self.send_error(403);return
                    if self.command == 'POST' and path == '/__fixture__/background-upload/release':
                        container=run(['xcrun','simctl','get_app_container',args.receiver_simulator,'com.stskcxfz.imapp','data'],timeout=5).stdout.decode().strip()
                        background_gate.capture_durable_mapping(Path(container))
                        background_gate.release()
                    elif not (self.command == 'GET' and path == '/__fixture__/background-upload/state'):
                        self.send_error(404);return
                    diagnostic=json.dumps(background_gate.snapshot()).encode()
                    self.send_response(200);self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length',str(len(diagnostic)));self.end_headers();self.wfile.write(diagnostic);return
                gated=background_gate is not None and self.command == 'PUT' and path.startswith('/v2/local-media/upload/') and background_gate.claim(self.path,length)
                body=background_gate.read(self,length) if gated else self.rfile.read(length)
                with http_lock:
                    request_is_cold=refresh_diagnostics['coldRestore']
                if app_refresh_mode and path.startswith('/__fixture__/app-refresh-'):
                    with http_lock:
                        if self.command == 'POST' and path == '/__fixture__/app-refresh-arm':
                            refresh_diagnostics['armed']=True
                        elif self.command == 'POST' and path == '/__fixture__/app-refresh-cold':
                            refresh_diagnostics['coldRestore']=True
                        elif not (self.command == 'GET' and path == '/__fixture__/app-refresh-status'):
                            self.send_error(404);return
                        diagnostic=json.dumps(refresh_diagnostics).encode()
                    self.send_response(200);self.send_header('Content-Type','application/json')
                    self.send_header('Content-Length',str(len(diagnostic)));self.end_headers();self.wfile.write(diagnostic);return
                # Never forward user-supplied edge authorization/address proof.
                headers={k:v for k,v in self.headers.items() if k.lower() not in {'host','connection','transfer-encoding','x-im-v2-account-edge-authorization','x-im-v2-account-client-address'}}
                headers['X-IM-V2-Account-Edge-Authorization']=account_env['IM_V2_ACCOUNT_EDGE_AUTHORIZATION_SECRET_BASE64']
                headers['X-IM-V2-Account-Client-Address']=self.client_address[0]
                connection=http.client.HTTPConnection('127.0.0.1',ports['account'],timeout=30)
                try:
                    connection.request(self.command,self.path,body,headers);response=connection.getresponse();data=response.read(1024*1024+1)
                    status=response.status
                    if gated: background_gate.completed(status)
                    with http_lock:
                        if app_refresh_mode and self.command == 'POST' and path == '/v2/device-credentials/refresh' and status == 200:
                            refresh_digest[0]=hashlib.sha256(json.loads(data)['accessToken'].encode()).digest()
                            refresh_diagnostics['refreshResponses']+=1
                        if app_refresh_mode and self.command == 'GET' and path == '/v2/devices' and status == 200:
                            if refresh_diagnostics['armed']:
                                refresh_diagnostics['armed']=False;refresh_diagnostics['injected']+=1
                                status=401;data=b'{}'
                            elif request_is_cold and refresh_digest[0] is not None:
                                authorization=self.headers.get('Authorization','')
                                if authorization.startswith('Bearer ') and hashlib.sha256(authorization[7:].encode()).digest() == refresh_digest[0]:
                                    refresh_diagnostics['coldFreshDeviceReads']+=1
                        http_responses[(self.command, path, status)] += 1
                    if len(data)>1024*1024: self.send_error(502);return
                    self.send_response(status)
                    for k,v in response.getheaders():
                        if k.lower() not in {'connection','transfer-encoding','content-length'}: self.send_header(k,v)
                    self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
                finally: connection.close()
            do_GET = do_POST = do_PUT = do_DELETE = dispatch
        edge=http.server.ThreadingHTTPServer(('127.0.0.1',ports['edge']),Edge)
        server_tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);server_tls.minimum_version=ssl.TLSVersion.TLSv1_3 if args.two_install_ui else ssl.TLSVersion.TLSv1_2;server_tls.load_cert_chain(cert,key)
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
        cancellation={'deviceID':{'rawValue':device},'operationID':operation,'proof':'imv2-cancel-registration-v1.'+base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip('='),'issueBeforeMilliseconds':int((time.time()+600)*1000)}
        issued=post('/v2/device-credentials',{'accountAssertion':registration['accountAssertion'],'deviceID':device,'operationID':operation,'cancellation':cancellation})
        probe=dict(base,IM_V2_GATEWAY_PROBE_ACCOUNT_BASE_URL=f'https://localhost:{ports["edge"]}',IM_V2_GATEWAY_PROBE_ACCESS_TOKEN=issued['accessToken'],IM_V2_GATEWAY_PROBE_DEVICE_ID=device,
            IM_V2_GATEWAY_PROBE_HOST='127.0.0.1',IM_V2_GATEWAY_PROBE_PORT=str(ports['gateway']),IM_V2_GATEWAY_PROBE_CA_PATH=str(ca),IM_V2_GATEWAY_PROBE_SERVER_NAME='localhost')
        outcome=run([REPO/'IMV2Server/.build/debug/IMV2LocalGatewayProbe'],env=probe,timeout=30)
        if b'current protocol verified' not in outcome.stdout: raise RuntimeError('gateway authentication proof missing')
        config={'httpsBaseURL':f'https://localhost:{ports["edge"]}','gatewayHost':'localhost','gatewayPort':ports['gateway'],'caPath':str(ca)}
        (root/'test-endpoints.json').write_text(json.dumps(config))
        print('PASS independent PG + HTTPS registration + credential issue + native TLS gateway authentication',flush=True)
        if ui_requested:
            ui_environment=dict(base,IMAPP_LOCAL_TWO_INSTALL_EXTERNAL_STACK='true',IMAPP_LOCAL_TWO_INSTALL_CA_PATH=str(ca),
                IMAPP_LOCAL_TWO_INSTALL_RECEIVER_SIMULATOR_ID=args.receiver_simulator,
                IMAPP_LOCAL_TWO_INSTALL_SENDER_SIMULATOR_ID=args.sender_simulator,
                IMAPP_LOCAL_TWO_INSTALL_E2E_KEEP_RESULTS='true',
                IMAPP_LOCAL_TWO_INSTALL_PG_PORT=str(ports['pg']),
                IMAPP_LOCAL_TWO_INSTALL_OFFLINE_IDENTITY_PROOF='true')
            ui_log=(root/'two-install-ui.log').open('wb');logs.append(ui_log)
            ui_source=REPO/'IMApp/Scripts/verify_local_account_two_install_e2e.sh'
            success_marker='local two-install direct-and-group-message E2E: pass'
            if args.two_install_ui and background_upload_mode:
                ui_environment['IMAPP_LOCAL_TWO_INSTALL_PG_PORT']=str(ports['pg'])
                ui_environment['IMAPP_BACKGROUND_FIXTURE_TOKEN']=background_fixture_token
                success_marker='local App native background upload E2E: pass'
            if args.two_install_ui and os.environ.get('IMAPP_LOCAL_TWO_INSTALL_MEMBER_DIRECTORY_ONLY') == 'true':
                ui_environment['IMAPP_LOCAL_TWO_INSTALL_PG_PORT']=str(ports['pg'])
                success_marker='local App member directory E2E: pass'
            if args.two_install_ui and app_refresh_mode:
                ui_environment['IMAPP_LOCAL_TWO_INSTALL_PG_PORT']=str(ports['pg'])
                success_marker='local App credential refresh E2E: pass'
            if args.two_install_ui and os.environ.get('IMAPP_LOCAL_TWO_INSTALL_DIRECT_EDIT_ONLY') == 'true':
                ui_environment['IMAPP_LOCAL_TWO_INSTALL_PG_PORT']=str(ports['pg'])
                success_marker='local direct edit cold restoration E2E: pass'
            if args.group_join_ui:
                ui_environment['IMAPP_LOCAL_TWO_INSTALL_GROUP_JOIN_ONLY']='true'
                ui_environment['IMAPP_LOCAL_TWO_INSTALL_PG_PORT']=str(ports['pg'])
                success_marker='local group join approval E2E: pass'
                if os.environ.get('IMAPP_LOCAL_TWO_INSTALL_GROUP_JOIN_REJECT_ONLY') == 'true':
                    success_marker='local group join rejection E2E: pass'
                if os.environ.get('IMAPP_LOCAL_TWO_INSTALL_GROUP_EXIT_ONLY') == 'true':
                    success_marker='local voluntary group exit E2E: pass'
                if os.environ.get('IMAPP_LOCAL_TWO_INSTALL_COLD_INVITE_ONLY') == 'true':
                    success_marker='local cold restore invitation deep-link E2E: pass'
            if args.group_read_ui:
                ui_environment['IMAPP_LOCAL_TWO_INSTALL_GROUP_READ_ONLY']='true'
                success_marker='local group readers E2E: pass'
            if args.read_receipt_ui:
                ui_environment['IMAPP_LOCAL_TWO_INSTALL_READ_RECEIPT_ONLY']='true'
                success_marker='local direct peer-read E2E: pass'
            if args.account_switch_ui:
                ui_environment['IMAPP_LOCAL_TWO_INSTALL_ACCOUNT_SWITCH_ONLY']='true'
                switch_suffix=uuid.uuid4().hex[:18]
                switch_handle='switch_'+switch_suffix
                post('/v2/account-auth/password/register',{'accountHandle':switch_handle,
                    'publicHandle':'switch'+switch_suffix,'displayName':'Switch B',
                    'password':'localpassword','deviceID':str(uuid.uuid4()).upper()})
                ui_environment['IMAPP_LOCAL_TWO_INSTALL_SWITCH_SECOND_HANDLE']=switch_handle
                success_marker='local account-switch isolation E2E: pass'
            if args.multi_device_ui:
                ui_source=REPO/'IMApp/Scripts/verify_local_account_multi_device_e2e.sh'
                ui_environment.update(IMAPP_LOCAL_MULTI_DEVICE_EXTERNAL_STACK='true',IMAPP_LOCAL_MULTI_DEVICE_CA_PATH=str(ca),
                    IMAPP_LOCAL_MULTI_DEVICE_FIRST_SIMULATOR_ID=args.receiver_simulator,
                    IMAPP_LOCAL_MULTI_DEVICE_SECOND_SIMULATOR_ID=args.sender_simulator,
                    IMAPP_LOCAL_MULTI_DEVICE_PG_PORT=str(ports['pg']),IMAPP_LOCAL_MULTI_DEVICE_KEEP_RESULTS='true',
                    IMAPP_LOCAL_MULTI_DEVICE_OPERATOR_URL=f'http://127.0.0.1:{ports["operator"]}/internal/v2/device-snapshots/reset',
                    IMAPP_LOCAL_MULTI_DEVICE_OPERATOR_TOKEN=operator_env['IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64'])
                success_marker='local same-account multi-device E2E: pass'
                if os.environ.get('IMAPP_LOCAL_MULTI_DEVICE_CONVERSATION_PREFERENCE_ONLY') == 'true':
                    success_marker='local same-account conversation preferences E2E: pass'
            ui_driver=root/'two-install-ui-driver.sh'
            ui_driver.write_text(ui_source.read_text().replace(
                'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
                'script_dir='+shlex.quote(str(ui_source.parent))))
            ui=subprocess.Popen(['bash',str(ui_driver)],
                env=ui_environment,stdout=ui_log,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                directory_mode=args.two_install_ui and os.environ.get('IMAPP_LOCAL_TWO_INSTALL_MEMBER_DIRECTORY_ONLY') == 'true'
                result=ui.wait(timeout=2400 if directory_mode else 1800)
            finally:
                if ui.poll() is None:
                    os.killpg(ui.pid,signal.SIGTERM)
                    try: ui.wait(timeout=30)
                    except subprocess.TimeoutExpired: os.killpg(ui.pid,signal.SIGKILL);ui.wait()
            if result != 0: raise RuntimeError('two-install App scenario failed; inspect two-install-ui.log')
            ui_log.flush()
            if success_marker not in (root/'two-install-ui.log').read_text().splitlines():
                raise RuntimeError('two-install driver exited without completing all functional stages')
            print('PASS real two-install App messaging, offline recovery and group scenario',flush=True)
        if args.hold_seconds:
            print('test endpoint config='+str(root/'test-endpoints.json'),flush=True)
            deadline=time.monotonic()+args.hold_seconds
            while time.monotonic()<deadline and not (root/'stop').exists(): time.sleep(.5)
    finally:
        if background_gate is not None:
            (root/'background-upload-observation.json').write_text(json.dumps(background_gate.snapshot(),indent=2)+'\n')
            background_gate.release()  # Drain only this owned observation on any failed stage.
        if edge: edge.shutdown();edge.server_close()
        with http_lock:
            (root/'http-summary.json').write_text(json.dumps([
                {'method':method,'path':path,'status':status,'count':count}
                for (method,path,status),count in sorted(http_responses.items())],indent=2)+'\n')
        if pg_started:
            try:
                facts=run([PG/'psql','-X','-h','127.0.0.1','-p',ports['pg'],'-U','imv2_e2e','-d','imv2_e2e','-tAc',
                    "SELECT COALESCE(json_agg(json_build_object('messageID',m.message_id,'roomID',m.room_id,"
                    "'contentRevision',m.content_revision,'withdrawn',m.withdrawn_at IS NOT NULL,"
                    "'roomHead',r.room_sequence,'eventTypes',(SELECT json_agg(e.event_type ORDER BY e.room_sequence) "
                    "FROM im_v2.room_events e WHERE e.room_id=m.room_id))),'[]'::json) "
                    "FROM im_v2.messages m JOIN im_v2.rooms r USING(room_id)"],timeout=15)
                (root/'message-facts.json').write_bytes(facts.stdout)
            except Exception as error:
                (root/'message-facts-error.log').write_text(type(error).__name__+'\n')
        for process in reversed(processes):
            if process.poll() is None: process.terminate()
        for process in reversed(processes):
            try: process.wait(timeout=75)
            except subprocess.TimeoutExpired: process.kill();process.wait()
        for log in logs: log.close()
        if pg_started: run([PG/'pg_ctl','-D',root/'pg','-m','fast','-w','stop'])
        print('owned stack stopped; diagnostics retained at '+str(root),flush=True)

if __name__=='__main__': main()
