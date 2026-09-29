#!/usr/bin/env python3
"""Reject new server layer violations; migration may only shrink the baseline.

This source-level guard complements SwiftPM's target dependency checks. It is
not a Swift parser and does not establish behavioral or transaction correctness.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

from analyze_v2_server_module_dependencies import code_only

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'scripts/v2_server_boundary_baseline.json'
SOURCE_ROOT = 'IMV2Server/Sources/'


def violations(path, source):
    relative = path.removeprefix(SOURCE_ROOT)
    actual_target = relative.partition('/')[0]
    # Match source identifiers, not documentation or metric label text.
    source = code_only(source)
    rules = []
    is_contract_or_application = (
        actual_target in {'IMV2ServerContracts', 'IMV2ServerApplication'}
        or relative.startswith(('IMV2Server/Contracts/', 'IMV2Server/Application/'))
        or relative.startswith('IMV2Server/Resources/Application/')
    )
    if is_contract_or_application:
        rules.append(('application-storage', r'\b(?:(?:PostgresV2|V2Postgres)\w+|SQLDatabase|Database|PostgresConnection)\b'))
        rules.append(('application-driver-import', r'(?m)^import\s+(?:FluentKit|SQLKit|PostgresKit|PostgresNIO|Vapor|NIOCore)\b'))
    if actual_target == 'IMV2ServerContracts' or relative.startswith('IMV2Server/Contracts/'):
        rules.append(('contracts-outer-import', r'(?m)^import\s+(?:IMV2ServerApplication|IMV2ServerInfrastructure|IMV2ServerGateway|IMV2ServerHTTP)\b'))
    if actual_target == 'IMV2ServerApplication':
        rules.append(('application-outer-import', r'(?m)^import\s+(?:IMV2ServerInfrastructure|IMV2ServerGateway|IMV2ServerHTTP|IMV2ActorRuntime|IMV2ActorCluster)\b'))
    if actual_target in {'IMV2ActorContracts', 'IMV2ActorRuntime', 'IMV2ActorCluster'}:
        rules.append(('actor-server-import', r'(?m)^import\s+IMV2Server(?:Contracts|Application|Infrastructure|Gateway|HTTP)?\b'))
    if actual_target == 'IMV2ServerInfrastructure':
        rules.append(('infrastructure-transport-import', r'(?m)^import\s+(?:IMV2ServerGateway|IMV2ServerHTTP)\b'))
    if actual_target == 'IMV2ServerGateway':
        rules.append(('gateway-storage-import', r'(?m)^import\s+(?:IMV2ServerInfrastructure|FluentKit|SQLKit|PostgresKit|PostgresNIO)\b'))
    if relative.startswith('IMV2ServerHTTP/'):
        rules.append(('http-storage-import', r'(?m)^import\s+(?:IMV2ServerInfrastructure|FluentKit|SQLKit|PostgresKit|PostgresNIO)\b'))
        rules.append(('http-storage', r'\b(?:PostgresV2|V2Postgres)\w+\b'))
    if actual_target in {'IMV2ServerContracts', 'IMV2ServerApplication',
                         'IMV2ServerInfrastructure', 'IMV2ServerGateway', 'IMV2ServerHTTP'}:
        rules.append(('reverse-composition-import', r'(?m)^import\s+IMV2Server\b'))
    return {f'{path}|{rule}|{match.group(0)}'
            for rule, pattern in rules for match in re.finditer(pattern, source)}


def current_sources():
    for path in sorted((ROOT / SOURCE_ROOT).rglob('*.swift')):
        yield path.relative_to(ROOT).as_posix(), path.read_text()


def reference_sources(ref):
    paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', ref, SOURCE_ROOT], cwd=ROOT, text=True)
    for path in paths.splitlines():
        if path.endswith('.swift'):
            yield path, subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=ROOT, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--initialize-from', metavar='GIT_REF')
    parser.add_argument('--prune-resolved', action='store_true')
    args = parser.parse_args()
    if args.initialize_from:
        if BASELINE.exists():
            parser.error('baseline already exists; initialization must not accept new violations')
        initial = sorted({v for p, s in reference_sources(args.initialize_from) for v in violations(p, s)})
        revision = subprocess.check_output(['git', 'rev-parse', args.initialize_from], cwd=ROOT, text=True).strip()
        BASELINE.write_text(json.dumps({'sourceRevision': revision, 'allowed': initial}, indent=2) + '\n')
    data = json.loads(BASELINE.read_text())
    allowed = set(data['allowed'])
    observed = {v for p, s in current_sources() for v in violations(p, s)}
    added = sorted(observed - allowed)
    if added:
        print('New server boundary violations:', file=sys.stderr)
        print('\n'.join(added), file=sys.stderr)
        return 1
    resolved = allowed - observed
    if args.prune_resolved:
        data['allowed'] = sorted(observed)
        BASELINE.write_text(json.dumps(data, indent=2) + '\n')
    print(f'Server boundaries passed: {len(observed)} migration exceptions, {len(resolved)} resolved.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
