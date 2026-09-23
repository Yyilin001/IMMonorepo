#!/usr/bin/env python3
"""Probe actual Gateway authorization recovery across startup, SIGKILL and SIGTERM.

Build IMV2ServerApp first. Requires a loopback disposable PostgreSQL cluster,
PGHOST/PGPORT/PGUSER, psql/createdb/dropdb and openssl. Creates and removes only
its unique database; keeps logs under /tmp. Seeds held authorization fixtures,
not network SendMessage requests. No deployed configuration is read.
"""
import os,json,time,uuid,subprocess,signal,socket,base64
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
if os.environ.get('IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE') != '1':
    raise SystemExit('Set IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1 and PGHOST/PGPORT/PGUSER for a disposable local cluster.')
for key in ('PGHOST','PGPORT','PGUSER'):
    if not os.environ.get(key): raise SystemExit('Missing '+key)
if os.environ['PGHOST'] not in ('localhost','127.0.0.1','::1'):
    raise SystemExit('This probe requires a loopback disposable cluster.')
PG=Path(os.environ.get('IMV2_PG_BINDIR') or subprocess.check_output(['pg_config','--bindir'],text=True).strip())
BIN=Path(subprocess.check_output(['swift','build','--disable-automatic-resolution','--package-path',str(ROOT/'IMV2Server'),'--show-bin-path'],text=True).strip())
DIR=Path('/tmp/imv2-auth-gateway-'+str(uuid.uuid4()));DIR.mkdir()
DB='auth_gateway_'+uuid.uuid4().hex[:12]
ENV={**os.environ,'PGDATABASE':DB}
created=False
process=None; output=None; holder=None

def sql(query):
    return subprocess.check_output([str(PG/'psql'),'-X','-At','-v','ON_ERROR_STOP=1','-c',query],env=ENV,text=True,stderr=subprocess.PIPE).strip()
def wait(check,seconds=40):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if check():return
        if process is not None and process.poll() is not None:raise RuntimeError('gateway exited; see '+str(DIR))
        time.sleep(.1)
    raise TimeoutError('checkpoint timed out; see '+str(DIR))
def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def launch(label):
    global process,output
    output=(DIR/(label+'.log')).open('w')
    process=subprocess.Popen([str(BIN/'IMV2ServerApp')],env=config,stdout=output,stderr=subprocess.STDOUT)
    wait(lambda:'IM V2 metrics listener bound' in (DIR/(label+'.log')).read_text(),20)
def stop(sig):
    global process,output
    process.send_signal(sig);code=process.wait(timeout=15);process=None;output.close();return code
room,sender,recipient=[str(uuid.uuid4()) for _ in range(3)]
sender,recipient=sorted([sender,recipient])
def seed():
    client=str(uuid.uuid4())
    policy=json.dumps({'sender':{'user_id':sender,'is_active':True},'recipient':{'user_id':recipient,'is_active':True},'blocked':False,'isFriend':False,'allowsStrangers':True})
    sql(f"INSERT INTO im_v2.direct_authorization_intents(room_id,sender_user_id,client_message_id,recipient_user_id,request_fingerprint,generation,owner_shard_id,owner_epoch,policy,created_at,attempt_created_at,updated_at,next_check_at) VALUES('{room}','{sender}','{client}','{recipient}',decode(repeat('11',32),'hex'),1,'rooms-primary',0,'{policy}',now()-interval '60 seconds',now()-interval '60 seconds',now()-interval '60 seconds',now()-interval '1 second')")
    return client
try:
    subprocess.run([str(PG/'createdb'),DB],env=ENV,check=True)
    created=True
    with (DIR/'schema.log').open('w') as out:
        subprocess.run([str(PG/'psql'),'-X','-v','ON_ERROR_STOP=1','-f',str(ROOT/'IMV2/sql/schema.sql')],env=ENV,stdout=out,stderr=out,check=True)
    sql(f"INSERT INTO im_v2.rooms(room_id,room_kind,room_shard_id,capacity_profile_id) VALUES('{room}','direct','rooms-primary','standard'); INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at) VALUES('{room}','rooms-primary',0,now(),now()); INSERT INTO im_v2.direct_room_pairs(lower_user_id,higher_user_id,room_id,created_at) VALUES('{sender}','{recipient}','{room}',now())")
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(DIR/'key.pem'),'-out',str(DIR/'cert.pem'),'-days','1','-subj','/CN=localhost'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
    config={k:v for k,v in os.environ.items() if not k.startswith('IM_V2_')}
    config.update({'IM_V2_ACCEPT_BATCH_SIZE': '256',
 'IM_V2_AUTHENTICATION_TIMEOUT_MS': '10000',
 'IM_V2_BACKLOG_MAINTENANCE_BUSY_DRAIN_BUDGET_MS': '100',
 'IM_V2_BACKLOG_MAINTENANCE_IDLE_POLL_INTERVAL_MS': '1000',
 'IM_V2_BACKLOG_MAINTENANCE_MAX_CONSECUTIVE_BUSY_PASSES': '4',
 'IM_V2_CAPABILITY_PROFILE': 'base',
 'IM_V2_CAPACITY_PROFILE_ID': 'standard',
 'IM_V2_COMMAND_DIAGNOSTIC_LOG_MAX_PER_SECOND': '20',
 'IM_V2_COMMAND_SLOW_LOG_THRESHOLD_MS': '250',
 'IM_V2_COMMAND_SUCCESS_LOG_SAMPLE_PERMILLE': '10',
 'IM_V2_CONTENT_REVIEW_MODE': 'enabled',
 'IM_V2_DATABASE_CONNECT_TIMEOUT_MS': '5000',
 'IM_V2_DATABASE_DELIVERY_CONNECTIONS_PER_EVENT_LOOP': '1',
 'IM_V2_DATABASE_EVENT_LOOP_THREADS': '4',
 'IM_V2_DATABASE_FOREGROUND_CONNECTIONS_PER_EVENT_LOOP': '4',
 'IM_V2_DATABASE_IDLE_TRANSACTION_TIMEOUT_MS': '10000',
 'IM_V2_DATABASE_LOCK_TIMEOUT_MS': '2000',
 'IM_V2_DATABASE_MAINTENANCE_CONNECTIONS_PER_EVENT_LOOP': '1',
 'IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP': '8',
 'IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS': '512',
 'IM_V2_DATABASE_POOL_TIMEOUT_MS': '3000',
 'IM_V2_DATABASE_PROJECTION_CONNECTIONS_PER_EVENT_LOOP': '1',
 'IM_V2_DATABASE_STATEMENT_TIMEOUT_MS': '5000',
 'IM_V2_DATABASE_SYNC_CONNECTIONS_PER_EVENT_LOOP': '1',
 'IM_V2_DATABASE_URL': 'postgres://v2:password@db/im_v2',
 'IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED': 'true',
 'IM_V2_DATABASE_WORK_ADMISSION_ENABLED': 'true',
 'IM_V2_DATABASE_WORK_ADMISSION_TIMEOUT_MS': '200',
 'IM_V2_DEVICE_COMMANDS_PER_SECOND': '32',
 'IM_V2_DEVICE_COMMAND_BURST': '64',
 'IM_V2_DIRECT_ROOM_SHARD_ID': 'rooms-primary',
 'IM_V2_DURABLE_RETRY_INITIAL_DELAY_MS': '1000',
 'IM_V2_DURABLE_RETRY_JITTER_PERCENT': '20',
 'IM_V2_DURABLE_RETRY_MAX_ATTEMPTS': '10',
 'IM_V2_DURABLE_RETRY_MAX_DELAY_MS': '60000',
 'IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_LIMIT': '3',
 'IM_V2_FOREGROUND_CONTROL_WRITE_DATABASE_WORK_MAX_QUEUED': '288',
 'IM_V2_FOREGROUND_WRITE_DATABASE_WORK_LIMIT': '9',
 'IM_V2_FOREGROUND_WRITE_DATABASE_WORK_MAX_QUEUED': '288',
 'IM_V2_GATEWAY_NODE_ID': 'gateway-a',
 'IM_V2_GATEWAY_REPLICA_COUNT': '1',
 'IM_V2_GROUP_ROOM_SHARD_ID': 'rooms-primary',
 'IM_V2_IDEMPOTENCY_RETENTION_SECONDS': '3888000',
 'IM_V2_IDLE_TIMEOUT_MS': '60000',
 'IM_V2_INTERACTIVE_READ_DATABASE_WORK_LIMIT': '4',
 'IM_V2_INTERACTIVE_READ_DATABASE_WORK_MAX_QUEUED': '96',
 'IM_V2_LISTEN_BACKLOG': '4096',
 'IM_V2_MAINTENANCE_POLL_INTERVAL_MS': '60000',
 'IM_V2_MAX_COMMANDS_PER_WINDOW': '1000',
 'IM_V2_MAX_CONNECTIONS': '10000',
 'IM_V2_MAX_CONNECTIONS_PER_DEVICE': '2',
 'IM_V2_MAX_CONNECTIONS_PER_USER': '8',
 'IM_V2_MAX_ELIGIBLE_MEMBERS': '100000',
 'IM_V2_MAX_FRAME_BYTES': '65536',
 'IM_V2_MAX_IN_FLIGHT_REQUESTS': '32',
 'IM_V2_MAX_MESSAGE_UTF8_BYTES': '4096',
 'IM_V2_MAX_PROTOBUF_MESSAGE_DEPTH': '32',
 'IM_V2_MAX_QUEUED_INBOUND_BYTES': '262144',
 'IM_V2_MAX_QUEUED_INBOUND_CHUNKS': '512',
 'IM_V2_MAX_USER_SHARD_STORES': '16',
 'IM_V2_MEDIA_WITHDRAWN_RETENTION_SECONDS': '2592000',
 'IM_V2_METRICS_HOST': '127.0.0.1',
 'IM_V2_METRICS_MINIMUM_REFRESH_INTERVAL_MS': '30000',
 'IM_V2_METRICS_PORT': '9464',
 'IM_V2_METRICS_REFRESH_TIMEOUT_MS': '4000',
 'IM_V2_RATE_LIMIT_MAX_TRACKED_IDENTITIES': '20000',
 'IM_V2_RATE_LIMIT_RETRY_AFTER_SECONDS': '3',
 'IM_V2_STRANGER_MESSAGE_MAX_PER_WINDOW': '3',
 'IM_V2_STRANGER_MESSAGE_WINDOW_SECONDS': '86400',
 'IM_V2_SYNC_DATABASE_WORK_LIMIT': '4',
 'IM_V2_SYNC_DATABASE_WORK_MAX_QUEUED': '128',
 'IM_V2_SYNC_WAKE_COALESCING_ENABLED': 'true',
 'IM_V2_SYNC_WAKE_COALESCING_MS': '40',
 'IM_V2_SYNC_WAKE_DELIVERY_CONCURRENCY': '64',
 'IM_V2_SYNC_WAKE_MAX_PENDING_USERS': '50000',
 'IM_V2_TLS_CERTIFICATE_CHAIN_PATH': '/run/secrets/tls-chain.pem',
 'IM_V2_TLS_HOST': '0.0.0.0',
 'IM_V2_TLS_PORT': '7443',
 'IM_V2_TLS_PRIVATE_KEY_PATH': '/run/secrets/tls-key.pem',
 'IM_V2_USER_COMMANDS_PER_SECOND': '128',
 'IM_V2_USER_COMMAND_BURST': '256',
 'IM_V2_USER_PROJECTION_BUSY_DRAIN_BUDGET_MS': '50',
 'IM_V2_USER_PROJECTION_CONCURRENCY': '2',
 'IM_V2_USER_PROJECTION_MAX_CONSECUTIVE_BUSY_PASSES': '16',
 'IM_V2_USER_SHARD_BUCKET': 'users-primary',
 'IM_V2_USER_SHARD_ROUTER_EPOCH': '7',
 'IM_V2_WORKER_BATCH_SIZE': '256',
 'IM_V2_WORKER_POLL_INTERVAL_MS': '100'})
    config['IM_V2_ACCESS_TOKEN_HMAC_KEY_BASE64']=base64.b64encode(os.urandom(32)).decode()
    config.update({'IM_V2_DATABASE_URL':f"postgres://{ENV['PGUSER']}@{ENV['PGHOST']}:{ENV['PGPORT']}/{DB}",'IM_V2_TLS_HOST':'127.0.0.1','IM_V2_TLS_PORT':str(port()),'IM_V2_METRICS_PORT':str(port()),'IM_V2_TLS_CERTIFICATE_CHAIN_PATH':str(DIR/'cert.pem'),'IM_V2_TLS_PRIVATE_KEY_PATH':str(DIR/'key.pem'),'IM_V2_CONTENT_REVIEW_MODE':'disabled','IM_V2_DATABASE_EVENT_LOOP_THREADS':'4','IM_V2_DATABASE_WORK_ADMISSION_ENABLED':'false','IM_V2_USER_PROJECTION_CONCURRENCY':'1'})
    first=seed();launch('startup')
    wait(lambda:sql(f"SELECT disposition FROM im_v2.direct_authorization_intents WHERE client_message_id='{first}'")=='aborted')
    assert stop(signal.SIGTERM)==0
    assert 'drained=true' in (DIR/'startup.log').read_text()
    second=seed()
    holder=subprocess.Popen([str(PG/'psql'),'-X','-v','ON_ERROR_STOP=1','-c',f"BEGIN;SELECT room_id FROM im_v2.rooms WHERE room_id='{room}' FOR UPDATE;SELECT pg_sleep(60)"],env=ENV,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    wait(lambda:sql("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event='PgSleep'")=='1')
    launch('killed')
    wait(lambda:int(sql("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%owner_epoch%'"))>0)
    assert stop(signal.SIGKILL)==-signal.SIGKILL
    sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=current_database() AND wait_event='PgSleep'")
    holder.wait(timeout=5);holder=None
    assert sql(f"SELECT disposition IS NULL FROM im_v2.direct_authorization_intents WHERE client_message_id='{second}'")=='t'
    launch('restart')
    wait(lambda:sql(f"SELECT disposition FROM im_v2.direct_authorization_intents WHERE client_message_id='{second}'")=='aborted')
    holder=subprocess.Popen([str(PG/'psql'),'-X','-v','ON_ERROR_STOP=1','-c',f"BEGIN;SELECT room_id FROM im_v2.rooms WHERE room_id='{room}' FOR UPDATE;SELECT pg_sleep(60)"],env=ENV,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    wait(lambda:sql("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event='PgSleep'")=='1')
    third=seed()
    wait(lambda:int(sql("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%owner_epoch%'"))>0)
    assert stop(signal.SIGTERM)==0
    assert 'drained=true' in (DIR/'restart.log').read_text()
    assert sql(f"SELECT disposition IS NULL FROM im_v2.direct_authorization_intents WHERE client_message_id='{third}'")=='t'
    sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=current_database() AND wait_event='PgSleep'")
    holder.wait(timeout=5);holder=None
    launch('after-graceful')
    wait(lambda:sql(f"SELECT disposition FROM im_v2.direct_authorization_intents WHERE client_message_id='{third}'")=='aborted')
    assert stop(signal.SIGTERM)==0
    assert 'drained=true' in (DIR/'after-graceful.log').read_text()
    assert sql('SELECT count(*) FROM im_v2.direct_authorization_receipts')=='3'
    assert sql('SELECT count(*) FROM im_v2.messages')=='0'
    (DIR/'report.json').write_text(json.dumps({'startupRecovered':True,'killSignal':9,'restartRecovered':True,'gracefulDrained':True,'cancelledInFlightRecovered':True,'proofs':3,'messages':0},indent=2))
    print('PASS '+str(DIR),flush=True)
finally:
    if process is not None and process.poll() is None:process.kill();process.wait()
    if holder is not None and holder.poll() is None:holder.terminate();holder.wait()
    if output is not None:output.close()
    if created:
        subprocess.run([str(PG/'dropdb'),'--if-exists','--force',DB],env=ENV,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    print('Evidence '+str(DIR),flush=True)
