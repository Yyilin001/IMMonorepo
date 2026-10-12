"""Own three native control processes; no database or workload is started here."""
import json
import os
from pathlib import Path
import subprocess
import time

VOTERS = ('placement-a', 'placement-b', 'placement-c')


def voter_arguments(ports):
    if len(ports) != 3 or len(set(ports)) != 3 or any(not 1 <= port <= 65535 for port in ports):
        raise ValueError('three distinct placement ports are required')
    return [value for name, port in zip(VOTERS, ports)
            for value in ('--placement-voter', f'{name}=localhost:{port}')]


def start_controls(*, binary, actors, shards, log_directory, spawn, owned, timeout=45):
    """Append ownership immediately so partial startup also drains in finally.

    spawn(name, binary, environment) must retain each child's log/process.
    A ready marker follows a fresh quorum read, not merely a listening socket.
    """
    if owned:
        raise ValueError("placement process ownership must start empty")
    if not shards or len(set(shards)) != len(shards):
        raise ValueError("unique nonempty placement shards are required")
    binary = Path(binary)
    if not binary.is_file():
        raise FileNotFoundError('build IMV2PlacementControlApp before starting the native stack')
    configurations = [Path(actors) / name / 'configuration.json' for name in VOTERS]
    files = []
    environments = []
    for configuration in configurations:
        value = json.loads(configuration.read_text())
        paths = value['placementControl']['storagePaths']
        if set(paths) != set(shards):
            raise ValueError('placement storage must exactly cover the configured shards')
        files.extend(Path(path) for path in paths.values())
        base = {key: value for key, value in os.environ.items()
                if not key.startswith(('IM_V2_', 'IMV2_'))}
        environments.append(dict(base, IMV2_ROOM_ACTOR_CONFIGURATION_FILE=str(configuration),
                                 IMV2_PLACEMENT_SHARD_IDS=','.join(shards)))
    if len(set(files)) != len(files):
        raise ValueError('voters must own separate storage files')
    present = sum(path.exists() for path in files)
    if present not in (0, len(files)):
        raise RuntimeError('partial placement history; refusing to initialize missing voters')
    if not present:
        for name, environment in zip(VOTERS, environments):
            with (Path(log_directory) / (name + '-provision.log')).open('xb') as stream:
                subprocess.run([str(binary), '--provision'], env=environment, stdout=stream,
                               stderr=subprocess.STDOUT, check=True, timeout=30)
    for name, environment in zip(VOTERS, environments):
        owned.append(spawn(name, binary, environment))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(process.poll() is not None for process in owned):
            raise RuntimeError('placement control exited before quorum readiness; inspect owned logs')
        ready = []
        for name in VOTERS:
            path = Path(log_directory) / (name + '.log')
            ready.append(path.exists() and 'Placement control ready.' in path.read_text(errors='replace'))
        if all(ready):
            return
        time.sleep(.1)
    raise TimeoutError('native placement quorum readiness timed out')
