#!/usr/bin/env python3
"""Verify owner-only deployment approval before provisioning or using a Mac key."""
import argparse
import json
from pathlib import Path


def validate(environment, refs, owner_id, trial_branch=None):
    rules = environment.get('protection_rules', [])
    reviewers = [rule.get('reviewers', []) for rule in rules if rule.get('type') == 'required_reviewers']
    expected = [{'type': 'User', 'reviewer': {'id': owner_id}}]
    actual = [[{'type': r.get('type'), 'reviewer': {'id': r.get('reviewer', {}).get('id')}} for r in group] for group in reviewers]
    if not isinstance(owner_id, int) or owner_id <= 0 or environment.get('name') != 'macos-release' or actual != [expected]:
        raise ValueError('macos-release must require approval exclusively from the repository owner')
    if environment.get('can_admins_bypass') is not False:
        raise ValueError('Disable administrator bypass for the signing environment')
    if environment.get('deployment_branch_policy') != {'protected_branches': False, 'custom_branch_policies': True}:
        raise ValueError('Selected deployment refs are required')
    allowed = {('tag', 'v*')}
    if trial_branch:
        if '*' in trial_branch or '?' in trial_branch or '[' in trial_branch or not trial_branch.strip():
            raise ValueError('The approved trial branch must be exact')
        allowed.add(('branch', trial_branch))
    policies = refs.get('branch_policies', [])
    configured = {(p.get('type'), p.get('name')) for p in policies}
    if configured != allowed or len(policies) != len(allowed):
        raise ValueError('Allow only version tags and the exact currently approved trial branch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository-json', type=Path, required=True)
    parser.add_argument('--environment-json', type=Path, required=True)
    parser.add_argument('--refs-json', type=Path, required=True)
    parser.add_argument('--trial-branch', default='')
    args = parser.parse_args()
    try:
        repository = json.loads(args.repository_json.read_text())
        if repository.get('full_name') != 'gbettineschi/keepresso-mobile': raise ValueError('Wrong signing repository')
        validate(json.loads(args.environment_json.read_text()), json.loads(args.refs_json.read_text()),
                 repository['owner']['id'], args.trial_branch or None)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(2, 'Signing protection check failed: ' + str(error) + '\n')
    print('Owner approval and exact deployment refs verified.')


if __name__ == '__main__': main()
