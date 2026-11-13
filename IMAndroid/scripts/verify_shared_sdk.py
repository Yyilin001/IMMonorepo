#!/usr/bin/env python3
"""Build and verify the shared SDK App against an explicitly supplied isolated real backend.
Only the dedicated .sharedverification package and owned adb reverses/relay are touched.
Start IMV2/scripts/verify_v2_isolated_native_account.py --hold-seconds 900 first.
"""
import argparse, hashlib, json, os, select, socket, socketserver, subprocess, threading, time
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = 'com.xmtx.im.android.sharedverification'

class Relay:
    def __init__(self, target):
        self.target = target
        self.listener = socket.socket(); self.listener.bind(('127.0.0.1', 0)); self.listener.listen(); self.listener.settimeout(.5)
        self.port = self.listener.getsockname()[1]
        self.lock = threading.Lock(); self.sockets = set(); self.paused = False; self.closed = False; self.cuts = 0; self.accepted = 0
        self.worker = threading.Thread(target=self.accept, daemon=True); self.worker.start()
    def accept(self):
        while not self.closed:
            try: client, _ = self.listener.accept()
            except (socket.timeout, OSError): continue
            with self.lock:
                if self.paused or self.closed: client.close(); continue
                self.sockets.add(client)
            threading.Thread(target=self.forward, args=(client,), daemon=True).start()
    def forward(self, client):
        upstream = None
        try:
            upstream = socket.create_connection(('127.0.0.1', self.target), timeout=5)
            with self.lock:
                if self.paused or self.closed: return
                self.sockets.add(upstream); self.accepted += 1
            while not self.closed:
                ready, _, _ = select.select([client, upstream], [], [], .5)
                for source in ready:
                    data = source.recv(65536)
                    if not data: return
                    (upstream if source is client else client).sendall(data)
        except (OSError, ValueError): pass
        finally:
            with self.lock:
                self.sockets.discard(client); self.sockets.discard(upstream)
            client.close()
            if upstream: upstream.close()
    def pause(self):
        with self.lock:
            self.paused = True; self.cuts += 1; owned = list(self.sockets)
        for sock in owned:
            try: sock.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            sock.close()
    def close(self):
        self.closed = True; self.pause(); self.listener.close(); self.worker.join(2)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--phase', type=int, choices=[5, 6, 7, 8, 9, 10, 11], default=5)
    parser.add_argument('--endpoints', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=True)
    config = json.loads(args.endpoints.read_text())
    origin = urlparse(config['httpsBaseURL'])
    if origin.scheme != 'https' or origin.hostname != 'localhost' or not origin.port:
        raise ValueError('Requires the isolated localhost HTTPS backend')
    adb = [str(Path.home() / 'Library/Android/sdk/platform-tools/adb'), '-s', args.serial]
    def device(*command, check=True):
        return subprocess.run(adb + list(command), text=True, capture_output=True, check=check, timeout=30).stdout
    assert device('shell', 'getprop', 'ro.build.version.sdk').strip() == '31'
    assert device('shell', 'getprop', 'sys.boot_completed').strip() == '1'
    relay = Relay(config['gatewayPort'])
    class Control(socketserver.StreamRequestHandler):
        def handle(self):
            value = self.rfile.readline(64).strip()
            if value == b'pause': relay.pause()
            elif value == b'resume':
                with relay.lock: relay.paused = False
            else: self.wfile.write(b'ERROR\n'); return
            self.wfile.write(b'OK\n')
    control = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Control)
    control.daemon_threads = True
    worker = threading.Thread(target=control.serve_forever, daemon=True); worker.start()
    ports = [origin.port, relay.port, control.server_address[1]]
    if args.phase in (5, 6, 7, 8, 9, 10, 11): ports.append(config['gatewayPort'])
    owned = []
    try:
        existing = device('reverse', '--list')
        for port in ports:
            if 'tcp:' + str(port) in existing: raise RuntimeError('Refusing to replace an existing reverse')
            device('reverse', 'tcp:' + str(port), 'tcp:' + str(port)); owned.append(port)
        environment = dict(os.environ, JAVA_HOME=subprocess.check_output(['/usr/libexec/java_home','-v','17'], text=True).strip())
        command = [str(ROOT/'IMAndroid/gradlew'), '-p', str(ROOT/'IMAndroid'),  '-PimSharedSDKVerification=true',
            '-PimDebugTestCaFile='+config['caPath'], ':sharedsdk:testDebugUnitTest', ':sharedsdk:lintDebug', ':swiftplatform:lintDebug',
            ':app:testDebugUnitTest', ':app:assembleDebug', ':app:assembleDebugAndroidTest', ':app:lintDebug']
        with (args.output/'gradle.log').open('w') as log: subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
        # This package is exclusively reserved for this harness; normal user App data is untouched.
        device('uninstall', PACKAGE+'.test', check=False); device('uninstall', PACKAGE, check=False)
        apk = ROOT/'IMAndroid/app/build/outputs/apk/debug/app-debug.apk'
        test = ROOT/'IMAndroid/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk'
        device('install', str(apk)); device('install', str(test))
        command = adb + ['shell','am','instrument','-w','-r','-e','class',('com.xmtx.im.SharedSDKMessagingBackendTests' if args.phase == 5 else 'com.xmtx.im.SharedSDKDirectoryBackendTests' if args.phase == 6 else 'com.xmtx.im.SharedSDKPeopleBackendTests' if args.phase == 7 else 'com.xmtx.im.SharedSDKAvatarBackendTests' if args.phase == 8 else 'com.xmtx.im.SharedSDKMediaBackendTests' if args.phase == 9 else 'com.xmtx.im.SharedSDKMessageToolsBackendTests' if args.phase == 10 else 'com.xmtx.im.SharedSDKInteractionsBackendTests'),
            '-e','sharedPeerTLSPort',str(config['gatewayPort']),'-e','sharedURL',config['httpsBaseURL'],'-e','sharedTLSPort',str(relay.port),'-e','sharedControlPort',str(ports[2]),
            PACKAGE+'.test/androidx.test.runner.AndroidJUnitRunner']
        with (args.output/'instrumentation.log').open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=360)
        text = (args.output/'instrumentation.log').read_text()
        if result.returncode or 'OK (1 test)' not in text: raise RuntimeError('App acceptance failed; inspect instrumentation.log')
        evidence = json.loads(device('shell','run-as',PACKAGE,'cat','files/shared-sdk-evidence.json'))
        installed = device('shell','pm','path',PACKAGE).strip().removeprefix('package:')
        evidence.update(api=31, serial=args.serial, apkSHA256=hashlib.sha256(apk.read_bytes()).hexdigest(),
            installedApkSHA256=device('shell','sha256sum',installed).split()[0], relayCuts=relay.cuts, relayConnections=relay.accepted)
        assert evidence['passed'] and evidence['relayCuts'] >= 1 and evidence['apkSHA256'] == evidence['installedApkSHA256']
        (args.output/'results.json').write_text(json.dumps(evidence, indent=2)+'\n')
        print(json.dumps(evidence, indent=2))
    finally:
        device('shell','am','force-stop',PACKAGE,check=False)
        for port in owned: device('reverse','--remove','tcp:'+str(port),check=False)
        control.shutdown(); control.server_close(); worker.join(2); relay.close()

if __name__ == '__main__': main()
