import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { test } from 'node:test';
import { appAPI, deliver, installationPlan, mint, permissions, renew, repository, repositoryId, validateConfig } from '../runner/status-issuer/renew.mjs';

const now = 1_800_000_000_000;
const issuer = { app_id: 10, creator_id: 20, creator_login: 'fixture[bot]', creator_type: 'Bot' };
const policy = { [repository]: { issuer } };
const config = { ...issuer, repository, repository_id: repositoryId, installation_id: 30,
  private_key_file: '/private/fixture.pem', ssh_identity_file: '/private/receiver-key',
  ssh_known_hosts_file: '/private/known_hosts', ssh_target: 'linuxci@ci-linux-01.local' };
const granted = { ...permissions, metadata: 'read' };
function fixture() {
  const calls = [];
  const responses = {
    'GET /app': { id: 10, slug: 'fixture' },
    'GET /users/{username}': { id: 20, login: 'fixture[bot]', type: 'Bot' },
    'GET /repos/{owner}/{repo}/installation': { id: 30, app_id: 10, repository_selection: 'selected', permissions: granted },
    'POST /app/installations/{installation_id}/access_tokens': { token: 'fixture-token-never-real',
      expires_at: new Date(now + 3600_000).toISOString(), permissions: granted,
      repositories: [{ id: repositoryId, full_name: repository, private: true }] },
  };
  return { calls, responses, api: async (route, args) => { calls.push([route, args]); return { data: responses[route] }; } };
}

test('only the protected Bot, target and dedicated installation can renew', () => {
  validateConfig(config, policy);
  for (const patch of [{ app_id: 11 }, { creator_id: 1 }, { creator_login: 'henry' }, { installation_id: null },
    { repository: 'autumngarage/other' }, { repository_id: 1 }, { ssh_target: 'root@other' }]) {
    assert.throws(() => validateConfig({ ...config, ...patch }, policy));
  }
  assert.throws(() => validateConfig(config, { [repository]: { issuer: null } }));
});

test('installation dry run remains inert and restricts the existing SSH endpoint to one receiver', () => {
  const plan = installationPlan();
  assert.deepEqual([plan.changes, plan.activation, plan.app_creation], [false, false, false]);
  assert.equal(plan.pc.credential, '/var/lib/hesperus-runscaler/native-credential/status.json');
  assert.equal(plan.pc.authorized_key_options, 'restrict,command="/usr/bin/python3 -I /opt/hesperus-runner/native/status-credential.py"');
  assert.equal(plan.studio.interval_seconds, 1200);
});

test('mint sends exact one-repo least privilege and binds expiry', async () => {
  const f = fixture();
  const credential = await mint(config, f.api, now);
  assert.deepEqual(f.calls.at(-1), ['POST /app/installations/{installation_id}/access_tokens', {
    installation_id: 30, repository_ids: [repositoryId], permissions,
  }]);
  assert.equal(credential.issued_at, now / 1000);
  assert.equal(credential.expires_at, now / 1000 + 3600);
  assert.equal(credential.version, 1);
});

test('wrong App, personal account, broad permissions/repositories, and short/long expiry refuse delivery', async () => {
  const cases = [
    ['GET /app', { id: 11 }], ['GET /users/{username}', { type: 'User' }],
    ['GET /repos/{owner}/{repo}/installation', { suspended_at: 'now' }],
    ['GET /repos/{owner}/{repo}/installation', { permissions: { ...granted, administration: 'write' } }],
    ['POST /app/installations/{installation_id}/access_tokens', { permissions: { ...granted, contents: 'write' } }],
    ['POST /app/installations/{installation_id}/access_tokens', { repositories: [{ id: repositoryId }, { id: 2 }] }],
    ['POST /app/installations/{installation_id}/access_tokens', { expires_at: new Date(now + 60_000).toISOString() }],
    ['POST /app/installations/{installation_id}/access_tokens', { expires_at: new Date(now + 7200_000).toISOString() }],
  ];
  for (const [route, patch] of cases) {
    const f = fixture(); Object.assign(f.responses[route], patch);
    await assert.rejects(renew(config, policy, f.api, () => assert.fail('unsafe delivery'), now));
  }
});

test('delivery uses bounded strict forced SSH, stdin only, and exact acknowledgement', async () => {
  const credential = await mint(config, fixture().api, now);
  deliver(config, credential, (file, args, options) => {
    assert.equal(file, '/usr/bin/ssh');
    assert.equal(args.at(-1), config.ssh_target);
    assert(args.includes('StrictHostKeyChecking=yes'));
    assert(args.includes('IdentitiesOnly=yes'));
    assert(!args.join(' ').includes(credential.token));
    assert.deepEqual(JSON.parse(options.input), credential);
    assert.equal(options.timeout, 30_000);
    return { status: 0, stdout: JSON.stringify({ version: 1, repository_id: repositoryId, expires_at: credential.expires_at }) };
  });
  for (const result of [{ status: 1 }, { error: new Error('transport') }, { status: 0, stdout: '{}' }]) {
    assert.throws(() => deliver(config, credential, () => result));
  }
});

test('failed issuance never delivers; next scheduled run recovers without cached credentials', async () => {
  await assert.rejects(renew(config, policy, async () => { throw new Error('fixture outage'); }, () => assert.fail('delivery'), now));
  const f = fixture();
  const result = await renew(config, policy, f.api, (_file, _args, options) => {
    const doc = JSON.parse(options.input);
    return { status: 0, stdout: JSON.stringify({ version: 1, repository_id: repositoryId, expires_at: doc.expires_at }) };
  }, now);
  assert.deepEqual(Object.keys(result).sort(), ['expires_at', 'repository_id', 'version']);
});

test('pinned Octokit signs real App JWTs, permits public bot lookup, and bounds requests without redirects', async () => {
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const f = fixture();
  const routes = [ '/app', '/users/fixture%5Bbot%5D', '/repos/autumngarage/hesperus/installation', '/app/installations/30/access_tokens' ];
  let count = 0;
  const api = appAPI(config, pem, async (url, options) => {
    assert.equal(new URL(url).pathname, routes[count]);
    assert.equal(options.redirect, 'error');
    assert(options.signal instanceof AbortSignal);
    const auth = options.headers.authorization;
    if (count === 1) assert.equal(auth, undefined);
    else {
      const [header, body, signature] = auth.split(' ')[1].split('.');
      assert.equal(JSON.parse(Buffer.from(body, 'base64url')).iss, 10);
      assert(verify('RSA-SHA256', Buffer.from(header + '.' + body), publicKey, Buffer.from(signature, 'base64url')));
    }
    const route = Object.keys(f.responses)[count++];
    if (options.body) assert.deepEqual(JSON.parse(options.body), { repository_ids: [repositoryId], permissions });
    return new Response(JSON.stringify(f.responses[route]), { status: options.method === 'POST' ? 201 : 200, headers: { 'content-type': 'application/json' } });
  });
  await mint(config, api, now);
  assert.equal(count, 4);
});
