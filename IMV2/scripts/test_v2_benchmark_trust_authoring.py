import unittest
from pathlib import Path
from v2_benchmark_dynamic_membership import authority_profile, trust_authoring_command


class TrustAuthoringTests(unittest.TestCase):
    def configuration(self):
        return dict(runtime='/private/runtime', authorityProfile='imv2-growth-authority',
            processes={'gateway-0': dict(profile='imv2-growth-node0'),
                       'account': dict(profile='imv2-growth-account'),
                       'load-0': dict(profile='imv2-growth-probe')})

    def test_uses_explicit_offline_vm_and_exact_frozen_native_tool(self):
        command = trust_authoring_command(self.configuration(), Path('/private/actors'),
                                          Path('/private/expanded'), Path('/private/grant.pb'))
        self.assertEqual(command[:5], ['colima', '-p', 'imv2-growth-authority', 'ssh', '--'])
        self.assertEqual(command[5:10], ['sudo', '-n', 'unshare', '--net', '--'])
        self.assertIn('/private/runtime/bin/IMV2TrustAdmissionTool', command)
        self.assertEqual(command[-2:], ['/private/actors/.trust-admission/signing.pem', '/private/grant.pb'])
        self.assertNotIn('docker', command)
        self.assertNotIn('colima-imv2-tests', command)

    def test_missing_unowned_or_online_authority_profile_is_rejected(self):
        for profile in [None, '', 'imv2-tests', 'imv2-growth-account',
                        'imv2-growth-node0', 'imv2-growth-probe', 'imv2-growth-a;bad']:
            with self.subTest(profile=profile):
                configuration = self.configuration()
                configuration['authorityProfile'] = profile
                with self.assertRaises(ValueError):
                    authority_profile(configuration)


if __name__ == '__main__':
    unittest.main()
