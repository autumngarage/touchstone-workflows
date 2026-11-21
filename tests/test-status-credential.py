#!/usr/bin/env python3
"""No secrets: expiry, exact scope, atomic delivery and unattended recovery."""
import fcntl
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('credential', ROOT / 'runner/status-credential.py')
credential = importlib.util.module_from_spec(spec)
spec.loader.exec_module(credential)
spec = importlib.util.spec_from_file_location('admission', ROOT / 'runner/kvm-admission.py')
admission = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admission)


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.now = int(time.time())
        self.issuer = {'app_id': 10, 'creator_id': 20, 'creator_login': 'fixture[bot]', 'creator_type': 'Bot'}
        self.policy = dict(credential.routing.POLICY[credential.REPOSITORY], issuer=self.issuer)
        self.contexts = [patch.dict(module.routing.POLICY, {credential.REPOSITORY: self.policy}) for module in (credential, admission.credential)]
        for context in self.contexts:
            context.start()
            self.addCleanup(context.stop)
        self.doc = dict(version=1, repository=credential.REPOSITORY, repository_id=self.policy['repository_id'],
                        **{k: self.issuer[k] for k in ('app_id', 'creator_id', 'creator_login')},
                        installation_id=30, permissions=credential.PERMISSIONS, issued_at=self.now,
                        expires_at=self.now + 3600, token='fixture-token-never-real')
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'status.json'

    def test_exact_schema_scope_issuer_and_expiry(self):
        self.assertEqual(credential.validate(self.doc, self.now), self.doc['token'])
        for patching in ({'version': 2}, {'repository_id': 1}, {'app_id': 1}, {'creator_login': 'henry'},
                         {'permissions': dict(credential.PERMISSIONS, contents='write')},
                         {'issued_at': self.now + 6}, {'expires_at': self.now + 60},
                         {'expires_at': self.now + 7200}, {'token': 'contains\nnewline'}):
            with self.subTest(patching=patching), self.assertRaises(credential.routing.Refused):
                credential.validate(dict(self.doc, **patching), self.now)

    def test_atomic_private_refresh_replaces_expired_token_and_rejects_delayed_delivery(self):
        credential.receive(self.doc, self.path, self.now)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        old_bytes = self.path.read_bytes()
        with self.assertRaises(credential.routing.Refused):
            credential.receive(dict(self.doc, permissions={}), self.path, self.now)
        self.assertEqual(self.path.read_bytes(), old_bytes)
        later = dict(self.doc, token='renewed-fixture', issued_at=self.now + 3700, expires_at=self.now + 7300)
        credential.receive(later, self.path, self.now + 3700)
        self.assertEqual(credential.read(self.path, self.now + 3700)['token'], 'renewed-fixture')
        with self.assertRaises(credential.routing.Refused):
            credential.receive(self.doc, self.path, self.now)
        self.assertEqual(json.loads(self.path.read_text())['token'], 'renewed-fixture')

    def test_failed_atomic_update_retains_valid_prior_then_retry_recovers(self):
        credential.receive(self.doc, self.path, self.now)
        later = dict(self.doc, token='renewed-fixture', issued_at=self.now + 1200, expires_at=self.now + 4800)
        with patch.object(Path, 'replace', side_effect=OSError('fixture disk failure')), self.assertRaises(OSError):
            credential.receive(later, self.path, self.now + 1200)
        self.assertEqual(credential.read(self.path, self.now + 1200)['token'], self.doc['token'])
        self.assertFalse(list(self.path.parent.glob('.status-*')))
        credential.receive(later, self.path, self.now + 1200)
        self.assertEqual(credential.read(self.path, self.now + 1200)['token'], 'renewed-fixture')

    def test_controller_reloads_every_call_and_refuses_expired_unprivate_or_legacy_tokens(self):
        credential.receive(self.doc, self.path, self.now)
        api = admission.StatusAPI(self.path)
        with patch.object(admission.routing.GitHub, 'call', return_value={}) as remote:
            api.call('/fixture')
            later = dict(self.doc, token='renewed-fixture', expires_at=self.now + 3650)
            credential.receive(later, self.path, self.now)
            api.call('/fixture')
            self.assertEqual(api.token, 'renewed-fixture')
            with patch.object(admission.credential.time, 'time', return_value=self.now + 3600), self.assertRaises(admission.credential.routing.Refused):
                api.call('/fixture')
            self.assertEqual(remote.call_count, 2)
        self.path.chmod(0o644)
        with self.assertRaises(credential.routing.Refused):
            credential.read(self.path, self.now)
        self.path.chmod(0o600)
        self.path.write_text('old-raw-token')
        with self.assertRaises(json.JSONDecodeError):
            credential.read(self.path, self.now)

    def test_symlink_and_missing_policy_do_not_overwrite_anything(self):
        target = self.path.parent / 'other'
        target.write_text('preserve')
        self.path.symlink_to(target)
        with self.assertRaises(credential.routing.Refused):
            credential.receive(self.doc, self.path, self.now)
        self.assertEqual(target.read_text(), 'preserve')
        with patch.dict(credential.routing.POLICY, {credential.REPOSITORY: dict(self.policy, issuer=None)}), self.assertRaises(credential.routing.Refused):
            credential.validate(self.doc, self.now)

    def test_concurrent_delivery_refuses_without_waiting_or_losing_prior_token(self):
        credential.receive(self.doc, self.path, self.now)
        with (self.path.parent / 'receive.lock').open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                credential.receive(self.doc, self.path, self.now)
        self.assertEqual(credential.read(self.path, self.now)['token'], self.doc['token'])

    def test_supplied_boot_job_is_bounded_renewal_of_only_the_dedicated_config(self):
        plist = plistlib.loads((ROOT / 'runner/status-issuer/com.autumngarage.native-status-renewal.plist').read_bytes())
        self.assertEqual(plist['StartInterval'], 1200)
        self.assertTrue(plist['RunAtLoad'])
        self.assertNotIn('KeepAlive', plist)
        self.assertEqual(plist['ProgramArguments'], ['/opt/homebrew/bin/node',
            '/Users/henry/.local/lib/hesperus-native/runner/status-issuer/renew.mjs',
            '/Users/henry/.config/hesperus-native-issuer/config.json'])


if __name__ == '__main__':
    unittest.main()
