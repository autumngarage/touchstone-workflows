#!/usr/bin/env node
// Studio owns the dedicated App key. Only the one-repo token crosses SSH.
import { createAppAuth } from '@octokit/auth-app';
import { request } from '@octokit/request';
import { readFile, lstat } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export const repository = 'autumngarage/hesperus';
export const repositoryId = 1350057617;
export const permissions = Object.freeze({ actions: 'read', contents: 'read', pull_requests: 'read', statuses: 'write' });
const grantedPermissions = { ...permissions, metadata: 'read' };
const require = (condition, message) => { if (!condition) throw new Error(message); };
const same = (a, b) => JSON.stringify(Object.entries(a ?? {}).sort()) === JSON.stringify(Object.entries(b).sort());

export function validateConfig(config, policy) {
  const issuer = policy[repository]?.issuer;
  require(issuer?.creator_type === 'Bot' && Number.isSafeInteger(issuer.app_id) && issuer.app_id > 0
    && Number.isSafeInteger(issuer.creator_id) && issuer.creator_id > 0, 'verified App policy is not installed');
  require(config.app_id === issuer.app_id && config.creator_id === issuer.creator_id
    && config.creator_login === issuer.creator_login, 'issuer differs from protected policy');
  require(Number.isSafeInteger(config.installation_id) && config.installation_id > 0, 'installation is not pinned');
  require(config.repository === repository && config.repository_id === repositoryId, 'repository differs');
  require(config.ssh_target === 'linuxci@ci-linux-01.local', 'credential receiver differs');
  for (const key of ['private_key_file', 'ssh_identity_file', 'ssh_known_hosts_file']) {
    require(typeof config[key] === 'string' && config[key].startsWith('/') && !config[key].includes('\n'), `invalid ${key}`);
  }
}

export async function privateFile(path, secret = true) {
  const info = await lstat(path);
  require(info.isFile() && !info.isSymbolicLink() && [0, process.getuid()].includes(info.uid)
    && (secret ? [0o400, 0o600].includes(info.mode & 0o777) : (info.mode & 0o022) === 0), 'issuer input is not private or trusted');
  return readFile(path, 'utf8');
}

export async function mint(config, api, now = Date.now()) {
  const app = (await api('GET /app')).data;
  require(app.id === config.app_id && app.slug + '[bot]' === config.creator_login, 'App key identity differs');
  // The bot account, rather than /user, independently identifies installation-token posts.
  const bot = (await api('GET /users/{username}', { username: config.creator_login })).data;
  require(bot.id === config.creator_id && bot.login === config.creator_login && bot.type === 'Bot', 'App bot identity differs');
  const installation = (await api('GET /repos/{owner}/{repo}/installation', { owner: 'autumngarage', repo: 'hesperus' })).data;
  require(installation.id === config.installation_id && installation.app_id === config.app_id
    && installation.repository_selection === 'selected' && !installation.suspended_at
    && same(installation.permissions, grantedPermissions), 'installation scope or identity differs');
  const minted = (await api('POST /app/installations/{installation_id}/access_tokens', {
    installation_id: config.installation_id, repository_ids: [repositoryId], permissions,
  })).data;
  const expires = Date.parse(minted.expires_at);
  require(Number.isFinite(expires) && expires - now >= 30 * 60_000 && expires - now <= 65 * 60_000, 'token expiry differs');
  require(typeof minted.token === 'string' && /^[\x21-\x7e]{1,4096}$/.test(minted.token), 'invalid installation token');
  require(same(minted.permissions, grantedPermissions) && minted.repositories?.length === 1
    && minted.repositories[0].id === repositoryId && minted.repositories[0].full_name === repository
    && minted.repositories[0].private === true, 'minted token scope differs');
  return { version: 1, repository, repository_id: repositoryId, app_id: config.app_id,
    creator_id: config.creator_id, creator_login: config.creator_login, installation_id: config.installation_id,
    permissions: minted.permissions, issued_at: Math.floor(now / 1000), expires_at: Math.floor(expires / 1000), token: minted.token };
}

export function deliver(config, credential, run = spawnSync) {
  // No remote command is sent: authorized_keys forces the fixed receiver.
  const args = ['-F', '/dev/null', '-T', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
    '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5',
    '-o', 'ServerAliveCountMax=2', '-i', config.ssh_identity_file,
    '-o', `UserKnownHostsFile=${config.ssh_known_hosts_file}`, config.ssh_target];
  const result = run('/usr/bin/ssh', args, { input: JSON.stringify(credential), encoding: 'utf8', timeout: 30_000, maxBuffer: 4096 });
  require(!result.error && result.status === 0, 'credential delivery failed; prior credential retained');
  let ack;
  try { ack = JSON.parse(result.stdout); } catch { throw new Error('invalid credential delivery acknowledgement'); }
  require(ack.version === 1 && ack.expires_at === credential.expires_at && ack.repository_id === repositoryId,
    'credential delivery acknowledgement differs');
}

export async function renew(config, policy, api, run, now = Date.now()) {
  validateConfig(config, policy);
  const credential = await mint(config, api, now);
  deliver(config, credential, run);
  return { version: 1, repository_id: repositoryId, expires_at: credential.expires_at };
}

export function appAPI(config, privateKey, fetch = globalThis.fetch) {
  const boundedRequest = request.defaults({ request: {
    fetch: (url, options) => fetch(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(15_000) }),
  }, headers: { 'x-github-api-version': '2022-11-28' } });
  const auth = createAppAuth({ appId: config.app_id, privateKey, request: boundedRequest });
  const authenticated = boundedRequest.defaults({ request: { hook: auth.hook } });
  return (route, parameters) => route === 'GET /users/{username}'
    ? boundedRequest(route, parameters) : authenticated(route, parameters);
}

export function installationPlan() {
  return { changes: false, activation: false, app_creation: false,
    studio: {
      source: '/Users/henry/.local/lib/hesperus-native/runner',
      files: ['merge-routing.py', 'status-issuer/renew.mjs', 'status-issuer/package.json', 'status-issuer/package-lock.json'],
      config: '/Users/henry/.config/hesperus-native-issuer/config.json',
      private_inputs: ['app.pem', 'receiver-key', 'known_hosts'],
      launch_agent: '/Users/henry/Library/LaunchAgents/com.autumngarage.native-status-renewal.plist',
      interval_seconds: 1200,
    },
    pc: {
      source: '/opt/hesperus-runner/native/status-credential.py',
      credential: '/var/lib/hesperus-runscaler/native-credential/status.json',
      directory_mode: '0700', credential_mode: '0600', receiver_user: 'linuxci',
      authorized_key_options: 'restrict,command="/usr/bin/python3 -I /opt/hesperus-runner/native/status-credential.py"',
    } };
}

async function main() {
  if (process.argv.length === 3 && process.argv[2] === '--install-dry-run') {
    console.log(JSON.stringify(installationPlan(), null, 2));
    return;
  }
  require(process.argv.length === 3, 'usage: renew.mjs /absolute/path/config.json');
  const config = JSON.parse(await privateFile(process.argv[2]));
  // Read policy from the same reviewed source bundle as the PC controller.
  const policyResult = spawnSync('/usr/bin/python3', ['-I', '-c',
    'import importlib.util,json; s=importlib.util.spec_from_file_location("routing", __import__("sys").argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(json.dumps(m.POLICY))',
    new URL('../merge-routing.py', import.meta.url).pathname], { encoding: 'utf8', timeout: 5000 });
  require(policyResult.status === 0, 'protected issuer policy is unavailable');
  const policy = JSON.parse(policyResult.stdout);
  validateConfig(config, policy);
  const privateKey = await privateFile(config.private_key_file);
  await privateFile(config.ssh_identity_file);
  await privateFile(config.ssh_known_hosts_file, false);
  console.log(JSON.stringify(await renew(config, policy, appAPI(config, privateKey))));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    // Octokit errors can contain request headers. Never print them or a stack.
    const status = Number.isInteger(error.status) ? ` (GitHub HTTP ${error.status})` : '';
    console.error(`native status renewal refused${status}; check issuer configuration, GitHub and SSH; prior credential retained`);
    process.exitCode = 1;
  });
}
