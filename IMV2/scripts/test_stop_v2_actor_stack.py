import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class StopActorStackTests(unittest.TestCase):
    def run_stop(self, state):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'compose.json').write_text('{}')
            docker = root / 'docker'
            docker.write_text('''#!/bin/bash
echo "$*" >> "$CALLS"
if [[ "$*" == *'ps -aq gateway'* ]]; then echo gateway-id; fi
if [[ "$1" == inspect ]]; then echo "$HOST_STATE"; fi
''')
            docker.chmod(0o755)
            environment = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'],
                               CALLS=str(root / 'calls'), HOST_STATE=state)
            result = subprocess.run(['bash', str(Path(__file__).with_name('stop_v2_actor_stack.sh')),
                                     '--compose', str(root / 'compose.json')],
                                    env=environment, capture_output=True, text=True)
            return result, (root / 'calls').read_text().splitlines()

    def test_clean_host_stops_before_callers_and_quorum(self):
        result, calls = self.run_stop('exited 0 false')
        self.assertEqual(result.returncode, 0, result.stderr)
        stages = [call.split(' stop ')[1] for call in calls if ' stop ' in call]
        self.assertEqual(stages, ['-t 120 gateway', '-t 45 nginx account operator',
                                  '-t 45 placement-a placement-b placement-c'])
        self.assertLess(next(i for i, call in enumerate(calls) if call.startswith('inspect ')),
                        next(i for i, call in enumerate(calls) if 'stop -t 45' in call))

    def test_failed_or_forced_host_exit_keeps_quorum_available(self):
        for state in ['exited 1 false', 'exited 137 false', 'exited 137 true', 'running 0 false']:
            with self.subTest(state=state):
                result, calls = self.run_stop(state)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any('stop -t 45' in call for call in calls))


if __name__ == '__main__':
    unittest.main()
