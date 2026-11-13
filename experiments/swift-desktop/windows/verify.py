#!/usr/bin/env python3
"""Native Windows readiness checks. --host-smoke checks the probe on this host, not Windows support."""
import argparse, hashlib, json, os, shutil, subprocess, sys, tempfile, time, urllib.request, zipfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
SQLITE_SHA = '6e2a845a493026bdbad0618b2b5a0cf48584faab47384480ed9f592d912f23ec'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host-smoke', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'win32' and not args.host_smoke:
        parser.error('Run on native Windows; WSL/macOS is not Windows evidence.')
    args.output.mkdir(parents=True, exist_ok=True)
    evidence = dict(platform=sys.platform, hostSmoke=args.host_smoke, windowsValidated=False, stages={})
    def run(stage, command, **kwargs):
        result = subprocess.run(list(map(str, command)), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=1800, **kwargs)
        (args.output / (stage + '.log')).write_text(result.stdout, encoding='utf-8')
        evidence['stages'][stage] = dict(exitCode=result.returncode)
        result.check_returncode()
        return result.stdout
    try:
        compiler = shutil.which('clang')
        if not compiler: raise RuntimeError('Install Swift and the Visual Studio C++/Windows SDK tools; clang must be on PATH.')
        with tempfile.TemporaryDirectory(prefix='im-desktop-probe-') as directory:
            work = Path(directory)
            cached = ROOT / 'experiments/swift-android/build/sqlite-amalgamation-3510200.zip'
            archive = cached if cached.exists() else work / 'sqlite.zip'
            if not archive.exists():
                with urllib.request.urlopen('https://www.sqlite.org/2026/sqlite-amalgamation-3510200.zip', timeout=60) as response:
                    archive.write_bytes(response.read())
            if hashlib.sha256(archive.read_bytes()).hexdigest() != SQLITE_SHA: raise RuntimeError('SQLite archive checksum mismatch')
            with zipfile.ZipFile(archive) as zipped: zipped.extractall(work)
            sqlite = work / 'sqlite-amalgamation-3510200'
            binary = work / ('native-probe.exe' if sys.platform == 'win32' else 'native-probe')
            lock = ROOT / 'MessageSubstringSearch/Sources/CSearchFileLock'
            flags = ['-DSQLITE_ENABLE_FTS5', '-DSQLITE_ENABLE_SNAPSHOT', '-DSQLITE_THREADSAFE=1']
            if sys.platform != 'win32': flags += ['-lpthread', '-ldl', '-lm']
            run('compile-native', [compiler, '-O2', '-I'+str(sqlite), '-I'+str(lock/'include'), HERE/'native_probe.c', lock/'Lock.c', sqlite/'sqlite3.c', *flags, '-o', binary])
            run('sqlite', [binary, 'sqlite'], cwd=work)
            holder = subprocess.Popen([str(binary), 'hold'], cwd=work, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                # Bounded startup: acquire mode exits quickly; failed holder cannot hang this reader.
                import concurrent.futures
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                    future = pool.submit(holder.stdout.readline)
                    try: ready = future.result(timeout=15)
                    except concurrent.futures.TimeoutError:
                        holder.kill(); holder.wait(timeout=5); raise
                if ready.strip() != 'locked': raise RuntimeError('Lock owner did not start')
                run('lock-contention', [binary, 'busy'], cwd=work)
                holder.kill(); holder.wait(timeout=5)
                for attempt in range(20):
                    result = subprocess.run([str(binary), 'acquire'], cwd=work, timeout=10)
                    if result.returncode == 0: break
                    time.sleep(.1)
                else: raise RuntimeError('Lock did not release after owner process death')
                evidence['stages']['lock-after-process-death'] = dict(exitCode=0)
            finally:
                if holder.poll() is None: holder.kill(); holder.wait(timeout=5)
                holder.stdin.close(); holder.stdout.close(); holder.stderr.close()
        evidence['nativeProbePassed'] = True
        if not args.host_smoke:
            run('swift-version', ['swift', '--version'])
            run('shared-sdk-build', ['swift', 'build', '--package-path', ROOT/'IMV2ClientKit', '--product', 'IMV2SharedSDK'])
            # Build success alone does not certify missing secure-store/TLS/resource adapters.
            evidence['stages']['platform-adapters'] = dict(status='not-implemented', required=['secure storage', 'HTTP/TLS cancellation', 'resource file durability', 'DLL host binding', 'real backend'])
            raise RuntimeError('Native probes passed, but Windows platform adapters and backend acceptance remain incomplete.')
    finally:
        (args.output/'results.json').write_text(json.dumps(evidence, indent=2)+'\n', encoding='utf-8')

if __name__ == '__main__': main()
