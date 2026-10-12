#!/usr/bin/env python3
"""Actual TCP/SQL planned Host restart with three independent native voters.

Creates and removes its own PostgreSQL instance and private deployment. This is
planned retirement verification; no timeout or process death authorizes takeover.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

from v2_native_placement_processes import start_controls, voter_arguments
from v2_native_placement_inspection import room_placement, require_live_owner, same_owner

ROOT = Path(__file__).resolve().parents[2]
ROOM = '00000000-0000-0000-0000-000000000011'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--postgres-bin', required=True, type=Path)
    parser.add_argument('--artifact-dir', required=True, type=Path)
    args = parser.parse_args()
    output = args.artifact_dir.resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    private = Path(tempfile.mkdtemp(prefix='imv2-native-business-'))
    processes = []; streams = []; held = []; pg_started = False
    result = dict(passed=False, crashTakeoverVerified=False)
    environment = {k: v for k, v in os.environ.items() if not k.startswith(('IMV2_', 'IM_V2_', 'VA_', 'PG'))}
    binary = ROOT / 'IMV2Server/.build/out/Products/Debug/VirtualActorBusinessProbe'
    control_binary = binary.with_name('IMV2PlacementControlApp')
    def run(command, *, env=environment, log=None, **kwargs):
        if log:
            with (output / log).open('ab') as stream:
                return subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                      check=True, **kwargs)
        return subprocess.run(command, env=env, check=True, **kwargs)
    def spawn(name, executable, env, mode=None):
        stream = (output / (name + '.log')).open('xb'); streams.append(stream)
        process = subprocess.Popen([str(executable)] + ([mode] if mode else []), env=env,
                                   stdout=stream, stderr=subprocess.STDOUT)
        processes.append(process)
        return process
    def wait_file(name, process, seconds=60):
        deadline = time.monotonic() + seconds
        while not (output / name).is_file():
            if process.poll() is not None: raise RuntimeError('process exited before ' + name)
            if time.monotonic() >= deadline: raise TimeoutError(name)
            time.sleep(.1)
    try:
        # Build from this checkout; a previously existing binary is not evidence.
        for product in ('VirtualActorBusinessProbe', 'IMV2PlacementControlApp'):
            run(['swift', 'build', '--disable-automatic-resolution', '--package-path',
                 str(ROOT / 'IMV2Server'), '--product', product], log='build.log', timeout=300)
        binary = Path(subprocess.check_output(['swift', 'build', '--disable-automatic-resolution',
            '--package-path', str(ROOT / 'IMV2Server'), '--show-bin-path'], env=environment, text=True).strip()) / 'VirtualActorBusinessProbe'
        control_binary = binary.with_name('IMV2PlacementControlApp')
        ports = []
        for _ in range(7):
            while True:
                first = socket.socket(); first.bind(('127.0.0.1', 0)); port = first.getsockname()[1]
                second = socket.socket(); third = socket.socket()
                try:
                    third.bind(('127.0.0.1', port + 2))
                    second.bind(('127.0.0.1', port + 1))
                except OSError: first.close(); second.close(); third.close(); continue
                held.extend([first, second, third]); ports.append(port); break
        actors = private / 'actors'
        run(['python3', str(ROOT / 'IMV2/scripts/prepare_v2_room_actor_configuration.py'),
             '--output-dir', str(actors), '--host', f'host=localhost:{ports[0]}',
             '--caller', f'client=localhost:{ports[1]}', '--caller', f'inspector=localhost:{ports[2]}',
             '--shards', 'room-a', '--user-buckets', 'g4-users', *voter_arguments(ports[3:6])],
            log='configuration.log', timeout=30)
        # This isolated DB-boundary probe does not host policy mutation actors.
        # Production deployments keep their configured policy composition.
        for name in ('host', 'client', 'inspector'):
            path = actors / name / 'configuration.json'
            document = json.loads(path.read_text()); document.pop('policyPlacement', None)
            path.write_text(json.dumps(document))
        run([str(args.postgres_bin / 'initdb'), '-D', str(private / 'pg'), '-U', 'probe',
             '-A', 'trust', '--encoding=UTF8', '--no-locale'], log='initdb.log', timeout=30)
        for handle in held: handle.close()
        held.clear()
        run([str(args.postgres_bin / 'pg_ctl'), '-D', str(private / 'pg'), '-l', str(output / 'postgres.log'),
             '-o', f'-h 127.0.0.1 -p {ports[6]} -c max_connections=96 -c max_locks_per_transaction=512',
             '-w', 'start'], log='pg-control.log', timeout=30)
        pg_started = True
        psql = [str(args.postgres_bin / 'psql'), '-h', '127.0.0.1', '-p', str(ports[6]),
                '-U', 'probe', '-d', 'postgres', '-X', '-v', 'ON_ERROR_STOP=1']
        run(psql + ['-f', str(ROOT / 'IMV2/sql/schema.sql')], log='schema.log', timeout=30)
        run(psql + ['-f', str(ROOT / 'IMV2/scripts/native_actor_business_fixture.sql')], log='fixture.log', timeout=30)
        controls = []
        start_controls(binary=control_binary, actors=actors, shards=['room-a'], log_directory=output,
                       spawn=spawn, owned=controls)
        def node_env(name):
            return dict(environment, IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(actors / name / 'configuration.json'),
                        IMV2_PLACEMENT_SHARD_IDS='room-a', VA_G4_EVIDENCE_DIR=str(output),
                        VA_G4_STALE_CALLER_PORT=str(ports[1]+2),
                        VA_G4_DATABASE_URL=f'postgres://probe@127.0.0.1:{ports[6]}/postgres')
        def inspect():
            response = subprocess.run([str(control_binary), '--inspect'], env=node_env('inspector'),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True, timeout=45)
            shards = json.loads(response.stdout)
            return room_placement({shard['shardID']: shard for shard in shards}, ROOM, 'room-a')
        host = spawn('host-first', binary, node_env('host'), 'host')
        wait_file('host-ready', host)
        client = spawn('client', binary, node_env('client'), 'client')
        wait_file('client-stage1', client)
        before = inspect(); require_live_owner(before, before['hostID'])
        host.terminate()
        if host.wait(timeout=40) != 0 or not (output / 'host-stopped').is_file():
            raise RuntimeError('Host did not physically drain and retire normally')
        retired = inspect()
        if not same_owner(before, retired) or not retired['hostRetired'] or not retired['retired']:
            raise RuntimeError('normal process exit lacks committed retirement')
        (output / 'host-ready').unlink()
        replacement = spawn('host-replacement', binary, node_env('host'), 'host')
        wait_file('host-ready', replacement)
        after = inspect(); require_live_owner(after, before['hostID'])
        if after['incarnationID'] == before['incarnationID'] or after['epoch'] <= before['epoch']:
            raise RuntimeError('replacement did not register a new incarnation and epoch')
        (output / 'continue-after-restart').touch(mode=0o600)
        wait_file('client-done', client, seconds=90)
        if client.wait(timeout=40) != 0: raise RuntimeError('client failed after business verification')
        business = json.loads((output / 'result.json').read_text())
        if business['messageRows'] != 1 or not business['staleActivationRejected'] or not business['wrongDataOwnerRejected']:
            raise RuntimeError('native Actor/SQL/replay assertions incomplete')
        if any(process.poll() is not None for process in controls) or replacement.poll() is not None:
            raise RuntimeError('control voter or replacement Host exited during verification')
        result.update(passed=True, placementBefore=before, placementRetired=retired,
                      placementAfter=after, business=business)
    except Exception as error:
        result['failureType'] = type(error).__name__
        raise
    finally:
        for handle in held: handle.close()
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    if process.wait(timeout=40) != 0: result['passed'] = False
                except subprocess.TimeoutExpired: process.kill(); process.wait(); result['passed']=False
        for stream in streams: stream.close()
        if pg_started:
            stopped = subprocess.run([str(args.postgres_bin / 'pg_ctl'), '-D', str(private / 'pg'),
                                      '-m', 'fast', '-w', 'stop'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if stopped.returncode: result['passed']=False; raise RuntimeError('owned PostgreSQL did not stop')
        shutil.rmtree(private)
        result['ownedPrivateResourcesRemoved'] = not private.exists()
        (output / 'native-result.json').write_text(json.dumps(result, indent=2)+'\n')
    if not result['passed']: raise RuntimeError('native business verification incomplete')


if __name__ == '__main__':
    main()
