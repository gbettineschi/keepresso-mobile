import copy
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('signing_environment',Path(__file__).resolve().parents[1]/'verify-macos-signing-environment.py')
policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)


class SigningEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.environment={'name':'macos-release','can_admins_bypass':False,'deployment_branch_policy':{'protected_branches':False,'custom_branch_policies':True},
            'protection_rules':[{'type':'required_reviewers','reviewers':[{'type':'User','reviewer':{'id':42}}]}]}
        self.refs={'branch_policies':[{'type':'tag','name':'v*'},{'type':'branch','name':'fix/macos-permission-identity'}]}

    def check(self):policy.validate(self.environment,self.refs,42,'fix/macos-permission-identity')

    def test_owner_required_review_and_exact_trial_ref_are_accepted(self):self.check()

    def test_missing_or_other_approver_is_refused(self):
        for reviewers in [[],[{'type':'User','reviewer':{'id':99}}],
                          [{'type':'User','reviewer':{'id':42}},{'type':'User','reviewer':{'id':99}}]]:
            self.environment['protection_rules'][0]['reviewers']=reviewers
            with self.subTest(reviewers=reviewers),self.assertRaises(ValueError):self.check()
        self.environment['protection_rules']=[]
        with self.assertRaises(ValueError):self.check()

    def test_unrestricted_deployment_or_wildcard_branch_is_refused(self):
        self.environment['can_admins_bypass']=True
        with self.assertRaises(ValueError):self.check()
        self.setUp();self.environment['deployment_branch_policy']=None
        with self.assertRaises(ValueError):self.check()
        self.setUp();self.refs['branch_policies'].append({'type':'branch','name':'*'})
        with self.assertRaises(ValueError):self.check()
        self.setUp();self.refs['branch_policies'][1]['name']='different-branch'
        with self.assertRaises(ValueError):self.check()

    def test_production_requires_only_version_tags_after_trial(self):
        self.refs['branch_policies']=self.refs['branch_policies'][:1]
        policy.validate(self.environment,self.refs,42,None)
        with self.assertRaises(ValueError):self.check()


if __name__=='__main__':unittest.main()
