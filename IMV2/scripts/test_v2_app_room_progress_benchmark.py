"""Central App-mode routing and cleanup gates; no process, Loader or database."""
import argparse
import ast
import contextlib
import io
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from run_v2_actor_realtime_benchmark import app_canary_enabled, app_canary_selection, run_app_canary, preflight_app_canary, settle_app_cleanup_result, trim_owned_app_journal
from v2_app_room_progress_canary import preflight


def arguments(**changes):
    return SimpleNamespace(**dict(dict(app_outbox_canary=False,app_multi_device_canary=False,app_room_progress_canary=False),**changes))


class AppRoomProgressBenchmarkTests(unittest.TestCase):
    def test_trim_rejects_unowned_database_before_starting_psql(self):
        with patch('run_v2_actor_realtime_benchmark.subprocess.run') as run:
            with self.assertRaisesRegex(RuntimeError, 'database_not_owned'):
                trim_owned_app_journal(SimpleNamespace(), 'production')
            run.assert_not_called()

    def test_trim_requires_actual_removed_history(self):
        args = SimpleNamespace(pg_host='127.0.0.1', pg_port=18539,
            pg_user='fixture', pg_bin_directory=Path('/fixture'))
        for output in ['{"advancedPartitions":0,"removedEntries":0}',
                       '{"advancedPartitions":1,"removedEntries":0}']:
            with patch('run_v2_actor_realtime_benchmark.subprocess.run',
                       return_value=SimpleNamespace(returncode=0,stdout=output)):
                with self.assertRaisesRegex(RuntimeError, 'no_history_removed'):
                    trim_owned_app_journal(args, 'imv2_va_actor_candidate_0123456789ab')

    def test_trim_rejects_missing_or_changed_cursor_proof(self):
        args = SimpleNamespace(pg_host='127.0.0.1', pg_port=18539,
            pg_user='fixture', pg_bin_directory=Path('/fixture'))
        for proof, failure in [({}, 'no_consumer_cursors_checked'),
                ({'consumerCursorRowsChecked': 2}, 'consumer_cursors_changed'),
                ({'consumerCursorRowsChecked': 2, 'consumerCursorsPreserved': False}, 'consumer_cursors_changed')]:
            import json
            output = json.dumps(dict(advancedPartitions=1, removedEntries=3, **proof))
            with patch('run_v2_actor_realtime_benchmark.subprocess.run',
                    return_value=SimpleNamespace(returncode=0, stdout=output)):
                with self.assertRaisesRegex(RuntimeError, failure):
                    trim_owned_app_journal(args, 'imv2_va_actor_candidate_0123456789ab')

    def test_trim_accepts_measured_empty_consumer_set(self):
        args = SimpleNamespace(pg_host='127.0.0.1', pg_port=18539,
            pg_user='fixture', pg_bin_directory=Path('/fixture'))
        output = '{"advancedPartitions":1,"removedEntries":3,"consumerCursorRowsChecked":0,"consumerCursorsPreserved":true}'
        with patch('run_v2_actor_realtime_benchmark.subprocess.run',
                return_value=SimpleNamespace(returncode=0, stdout=output)):
            self.assertEqual(trim_owned_app_journal(args, 'imv2_va_actor_candidate_0123456789ab')['consumerCursorRowsChecked'], 0)

    def test_mode_selection_source_result_and_existing_modes(self):
        for flag,module,result in [('app_outbox_canary','v2_app_outbox_canary','app-outbox-canary.json'),
                ('app_multi_device_canary','v2_app_multi_device_canary','app-multi-device-canary.json'),
                ('app_room_progress_canary','v2_app_room_progress_canary','app-room-progress-canary.json')]:
            args = arguments(**{flag:True})
            self.assertTrue(app_canary_enabled(args))
            self.assertEqual(app_canary_selection(args),(flag,module,result))
        self.assertFalse(app_canary_enabled(arguments()))
        with self.assertRaises(ValueError): app_canary_selection(arguments())
        for other in ('app_outbox_canary','app_multi_device_canary'):
            with self.assertRaises(ValueError): app_canary_selection(arguments(app_room_progress_canary=True,**{other:True}))
        self.assertTrue(app_canary_enabled(SimpleNamespace(app_multi_device_canary=True)))

    def test_new_runner_receives_parent_query_and_preflight(self):
        args = arguments(app_room_progress_canary=True); query = object(); directory = Path('/unused')
        with patch('v2_app_room_progress_canary.run_canary',return_value={'qualityPassed':False}) as runner:
            self.assertEqual(run_app_canary(args,directory,query),{'qualityPassed':False})
            runner.assert_called_once_with(args,directory,query,gateway_crash=None)
        crash = object()
        with patch('v2_app_room_progress_canary.run_canary',return_value={}) as runner:
            run_app_canary(args,directory,query,gateway_crash=crash)
            runner.assert_called_once_with(args,directory,query,gateway_crash=crash)
        manifest = {'users':120}
        with patch('v2_app_room_progress_canary.preflight') as gate:
            preflight_app_canary(args,manifest); gate.assert_called_once_with(args,manifest)
        with patch('v2_app_multi_device_canary.run_canary',return_value={}) as runner:
            old = arguments(app_multi_device_canary=True)
            run_app_canary(old,directory,query); runner.assert_called_once_with(old,directory)

    def test_cleanup_never_promotes_failed_product_or_unsettled_resources(self):
        for product in (False,True):
            for app in (False,True):
                for services in (False,True):
                    for postgres in (False,True):
                        result = dict(productQualityPassed=product,appFixtureCleanupPassed=app,
                            ownedServicesCleanupPassed=services,ownedPostgresCleanupPending=True,
                            appRoomProgressCanary=True,qualityPassed=False)
                        settle_app_cleanup_result(result,postgres_passed=postgres)
                        self.assertEqual(result['qualityPassed'],product and app and services and postgres)
                        self.assertFalse(result['ownedPostgresCleanupPending'])
                        self.assertEqual(result['productQualityPassed'],product)

    def test_actual_parser_makes_all_three_modes_mutually_exclusive(self):
        source = Path(__file__).with_name('run_v2_actor_realtime_benchmark.py').read_text()
        main = next(node for node in ast.parse(source).body if isinstance(node,ast.FunctionDef) and node.name=='main')
        statements = [node for node in main.body if (isinstance(node,ast.Assign)
            and any(isinstance(target,ast.Name) and target.id=='app_mode' for target in node.targets))
            or (isinstance(node,ast.Expr) and isinstance(node.value,ast.Call)
                and isinstance(node.value.func,ast.Attribute) and isinstance(node.value.func.value,ast.Name)
                and node.value.func.value.id=='app_mode')]
        parser = argparse.ArgumentParser()
        exec(compile(ast.Module(body=statements,type_ignores=[]),'<actual App parser group>','exec'),{'parser':parser})
        self.assertTrue(parser.parse_args(['--app-room-progress-canary']).app_room_progress_canary)
        for other in ('--app-outbox-canary','--app-multi-device-canary'):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
                parser.parse_args(['--app-room-progress-canary',other])
            self.assertEqual(failure.exception.code,2)

    def test_preflight_rejects_other_faults_preserving_base_gate(self):
        for field,value in [('room_notification_loss_canary',True),('preclose_recovery_witness',True)]:
            args = SimpleNamespace(gateway_port=18443,**{field:value})
            with patch('v2_app_room_progress_canary.app_preflight') as base:
                with self.assertRaises(ValueError): preflight(args,{'users':120})
                base.assert_called_once_with(args,{'users':120},ack_cut=False)
        with patch('v2_app_room_progress_canary.app_preflight',side_effect=ValueError('base_quality_gate')):
            with self.assertRaisesRegex(ValueError,'base_quality_gate'): preflight(SimpleNamespace(gateway_port=18443),{'users':120})


if __name__ == '__main__': unittest.main()
