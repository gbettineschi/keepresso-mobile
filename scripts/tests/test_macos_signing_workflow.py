import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_policy', ROOT / 'scripts/release-policy.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
SHA = 'a' * 40
REPO = 'gbettineschi/keepresso-mobile'


class ReleasePolicyTests(unittest.TestCase):
    def plan(self, event='workflow_dispatch', ref='refs/heads/main', inputs=None, repo=REPO, sha=SHA):
        return policy.plan(repo, event, ref, sha, inputs or {'tag': 'v0.6.13', 'mode': 'verify'})

    def test_ordinary_verification_never_signs_or_publishes_mac(self):
        result = self.plan()
        self.assertFalse(result['sign_mac']); self.assertFalse(result['publish'])
        self.assertTrue(result['build_android'])

    def test_exact_mac_trial_is_mac_only_and_unpublished(self):
        result = self.plan(ref='refs/heads/fix/macos-permission-identity', inputs={'tag': 'v0.6.13', 'mode': 'mac-trial', 'expected_sha': SHA})
        self.assertTrue(result['sign_mac']); self.assertFalse(result['build_android']); self.assertFalse(result['publish'])
        self.assertEqual(result['source_sha'], SHA)

    def test_real_tag_builds_and_signs_both_platforms(self):
        result = self.plan(event='push', ref='refs/tags/v0.6.13', inputs={})
        self.assertTrue(result['sign_mac']); self.assertTrue(result['build_android']); self.assertTrue(result['publish'])
        self.assertEqual(result['tag'], 'v0.6.13')

    def test_forks_prs_moved_or_missing_sha_and_untrusted_refs_fail_closed(self):
        bad = [dict(repo='fork/keepresso-mobile'), dict(event='pull_request', ref='refs/pull/8/merge'),
               dict(event='push', ref='refs/heads/main'), dict(sha='a\n'*20),
               dict(inputs={'tag':'v0.6.13','mode':'mac-trial'}),
               dict(inputs={'tag':'v0.6.13','mode':'mac-trial','expected_sha':'b'*40}),
               dict(inputs={'tag':'v0.6.13','mode':'bad'}), dict(ref='refs/tags/v0.6.13'),
               dict(inputs={'tag':'v1.1000.1','mode':'verify'}), dict(inputs={'tag':'v01.2.3','mode':'verify'})]
        for case in bad:
            with self.subTest(case=case), self.assertRaises(ValueError): self.plan(**case)


class WorkflowBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Parse the actual workflow structure rather than search its source text.
        ruby = 'require "yaml"; require "json"; puts JSON.generate(YAML.load_file(ARGV[0]))'
        cls.workflow = json.loads(subprocess.check_output(['ruby','-e',ruby,str(ROOT/'.github/workflows/release.yml')],text=True))
        cls.jobs = cls.workflow['jobs']

    def test_only_tag_push_and_explicit_dispatch_can_enter_release(self):
        triggers = self.workflow.get('on', self.workflow.get('true'))
        self.assertEqual(set(triggers), {'push', 'workflow_dispatch'})
        self.assertEqual(triggers['push'], {'tags': ['v*']})
        self.assertEqual(triggers['workflow_dispatch']['inputs']['mode']['default'], 'verify')

    def test_signing_has_a_fresh_runner_and_private_environment(self):
        job = self.jobs['macos-sign']
        self.assertEqual(job['environment'], 'macos-release')
        self.assertEqual(job['needs'], ['plan','macos'])
        self.assertEqual(job['if'], "needs.plan.outputs.sign_mac == 'true'")
        self.assertEqual(self.jobs['android']['if'], "needs.plan.outputs.build_android == 'true'")
        self.assertEqual(self.jobs['publish']['needs'], ['plan','macos-sign','android'])
        self.assertEqual(self.jobs['publish']['if'], "needs.plan.outputs.publish == 'true'")

    def test_only_sign_step_receives_mac_secrets_and_never_executes_candidate(self):
        job = self.jobs['macos-sign']
        secret_steps = [s for s in job['steps'] if 'MACOS_SIGNING_PKCS12_BASE64' in s.get('env',{})]
        self.assertEqual(len(secret_steps),1)
        step = secret_steps[0]
        self.assertEqual(step['run'], 'python3 macos/scripts/ci-project-signing.py candidate/KeepressoMobile.zip signed/KeepressoMobile.zip --source-sha "$SOURCE_SHA" > signed/signing.json')
        self.assertEqual(set(step['env']), {'SOURCE_SHA','MACOS_SIGNING_PKCS12_BASE64','MACOS_SIGNING_PKCS12_PASSWORD','MACOS_SIGNING_CERTIFICATE_SHA1'})
        self.assertEqual(job['steps'][-1]['if'], 'always()')
        self.assertEqual(job['steps'][-1]['run'], 'python3 macos/scripts/ci-project-signing.py --cleanup-only')
        self.assertFalse(any('environment' in self.jobs[j] for j in ('plan','macos')))

    def test_exact_source_artifact_names_and_one_day_retention(self):
        for name in ('macos','macos-sign'):
            steps = self.jobs[name]['steps']
            checkout = next(s for s in steps if s.get('uses','').startswith('actions/checkout@'))
            self.assertEqual(checkout['with']['ref'], '${{ needs.plan.outputs.source_sha }}')
            self.assertFalse(checkout['with']['persist-credentials'])
            uploads = [s for s in steps if s.get('uses','').startswith('actions/upload-artifact@')]
            self.assertEqual(len(uploads),1)
            self.assertEqual(uploads[0]['with']['retention-days'],1)
            self.assertNotIn('*',uploads[0]['with']['path'])
        download = next(s for s in self.jobs['macos-sign']['steps'] if s.get('uses','').startswith('actions/download-artifact@'))
        self.assertEqual(download['with']['name'],'Keepresso-Mac-keyless-${{ github.sha }}')
        self.assertEqual(download['with']['path'],'candidate')
        self.assertEqual(self.jobs['plan']['outputs']['source_sha'], '${{ steps.policy.outputs.source_sha }}')


if __name__ == '__main__': unittest.main()
