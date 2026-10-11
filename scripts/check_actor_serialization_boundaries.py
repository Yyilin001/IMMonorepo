#!/usr/bin/env python3
"""Prevent JSON RPC bodies and serialized in-process room dispatch."""
from pathlib import Path
import re
import sys
root = Path(__file__).resolve().parents[1] / 'IMV2Server/Sources'
failures = []
for target in ('IMV2ActorContracts', 'IMV2ActorCluster', 'IMV2ActorRuntime'):
    forbidden = r'\b(?:JSONEncoder|JSONDecoder|JSONSerialization)\b'
    if target == 'IMV2ActorRuntime':
        forbidden = r'\b(?:JSONEncoder|JSONDecoder|JSONSerialization|V2ActorProtobuf)\b'
    for path in sorted((root / target).rglob('*.swift')):
        for index, line in enumerate(path.read_text().splitlines(), 1):
            if not line.lstrip().startswith('//') and re.search(forbidden, line):
                failures.append(f'{path.relative_to(root)}:{index}: serialized local dispatch or JSON RPC')
if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print('Actor serialization boundaries passed.')
