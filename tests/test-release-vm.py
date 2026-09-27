"""Transport/lifetime fixtures; real Tart probes remain separate evidence."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['FIXTURE'])
tool = pathlib.Path(sys.argv[0]).name
a = sys.argv[1:]
with (root/'calls').open('a') as f:
    f.write(json.dumps([tool, a, bool(os.environ.get('GH_TOKEN'))])+'\n')
case = os.environ['CASE']
if tool == 'uuidgen': print('00000000-0000-0000-0000-000000000001')
elif tool == 'gh':
    s = ' '.join(a)
    if 'generate-jitconfig' in s:
        print(json.dumps({'runner': {'id': 42}, 'encoded_jit_config':'single-use-config'}))
    elif '-X DELETE' in s: pass
    elif '/repositories' in s: print('autumngarage/nyx true')
    elif 'runner-groups/5' in s: print('false' if case == 'unrestricted' else 'true')
    elif 'runner-groups' in s:
        print(json.dumps({'id':5, 'visibility':'all' if case=='broad' else 'selected', 'allows_public_repositories':False}))
elif tool == 'tart':
    if a[0] == 'clone': (root/'guest').touch()
    elif a[0] == 'run':
        while not (root/'stop').exists(): time.sleep(.02)
    elif a[0] == 'stop':
        (root/'stop').touch()
        if case == 'stop-failure': sys.exit(1)
    elif a[0] == 'delete': (root/'guest').unlink()
    elif a[0] == 'exec':
        if '-i' not in a:
            sys.exit(1 if case == 'boot-failure' else 0)
        (root/'transport').write_text(sys.stdin.read())
        if case == 'job-failure': sys.exit(42)
'''


class ReleaseVMTests(unittest.TestCase):
    def exercise(self, case):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root/'bin'
            bin_dir.mkdir()
            for name in ['gh', 'tart', 'softnet', 'uuidgen']:
                p = bin_dir/name
                p.write_text(FAKE)
                p.chmod(0o755)
            token = root/'token'
            token.write_text('host-only-credential')
            token.chmod(0o600)
            if case == 'missing-token': token.unlink()
            state = root/'state'
            env = dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'],
                       FIXTURE=tmp, CASE=case, RELEASE_RUNNER_STATE=str(state),
                       RELEASE_RUNNER_TOKEN_FILE=str(token),
                       RELEASE_RUNNER_IMAGE='ghcr.io/example/base@sha256:'+'a'*64,
                       RELEASE_RUNNER_BOOT_SECONDS='3', RELEASE_RUNNER_JOB_SECONDS='3',
                       GH_TOKEN='must-not-use-interactive-token')
            if case == 'unpinned': env['RELEASE_RUNNER_IMAGE']='ghcr.io/example/base:latest'
            result = subprocess.run(['bash', str(ROOT/'runner/macos-release-vm.sh')],
                                    env=env, capture_output=True, text=True, timeout=15)
            calls = [json.loads(x) for x in (root/'calls').read_text().splitlines()] if (root/'calls').exists() else []
            self.assertNotIn('host-only-credential', result.stdout+result.stderr)
            self.assertNotIn('single-use-config', result.stdout+result.stderr)
            self.assertNotIn('host-only-credential', json.dumps(calls))
            self.assertNotIn('single-use-config', json.dumps(calls))
            return result, calls, (state/'lease').exists(), (root/'guest').exists(), (root/'transport').read_text() if (root/'transport').exists() else None

    def test_success_transports_only_jit_and_removes_guest(self):
        result, calls, lease, guest, transport = self.exercise('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(lease)
        self.assertFalse(guest)
        self.assertEqual(transport, 'single-use-config\n')
        for tool, args, token in calls:
            if tool == 'tart' and args[0] in ['run','exec']:
                self.assertFalse(token)
            if tool == 'tart' and args[0] == 'run':
                self.assertIn('--net-softnet', args)
                self.assertIn('--no-clipboard', args)
                self.assertFalse(any(x.startswith('--dir') for x in args))

    def test_refusals_do_not_create_guest(self):
        for case in ['unpinned','missing-token','broad','unrestricted']:
            with self.subTest(case=case):
                result, calls, lease, guest, _ = self.exercise(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(lease)
                self.assertFalse(guest)
                self.assertFalse(any(c[0]=='tart' for c in calls))

    def test_boot_and_job_failures_clean_up(self):
        for case in ['boot-failure','job-failure']:
            with self.subTest(case=case):
                result, calls, lease, guest, _ = self.exercise(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(lease)
                self.assertFalse(guest)

    def test_failed_cleanup_is_visible_and_retains_lease(self):
        result, _, lease, guest, _ = self.exercise('stop-failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cleanup incomplete', result.stderr)
        self.assertTrue(lease)
        self.assertTrue(guest)


if __name__ == '__main__': unittest.main()
