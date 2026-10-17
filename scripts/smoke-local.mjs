import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// Integration check for local development only. Creates then removes one synthetic
// identity. Credentials, tokens, user records and subprocess output stay private.
const root = fileURLToPath(new URL('../', import.meta.url));
const authOrigin = 'http://127.0.0.1:54321';
const id = randomUUID();
const email = `nene-smoke-${id}@example.invalid`;
const password = randomBytes(32).toString('base64url');
let api;
let identityId;
let adminHeaders;
let failed = false;
let stage = 'local service configuration';

function sql(statement) {
  const result = spawnSync('docker', [
    'exec', '--interactive', 'supabase_db_nene-local', 'psql', '-X',
    '--set', 'ON_ERROR_STOP=1', '--username', 'postgres', '--dbname', 'postgres', '--quiet',
  ], { input: statement, encoding: 'utf8', timeout: 15_000, windowsHide: true });
  if (result.error || result.status !== 0) throw new Error('Local fixture database operation failed.');
}

async function request(url, options = {}) {
  return fetch(url, { ...options, signal: AbortSignal.timeout(8000) });
}

async function unusedPort() {
  const server = createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

try {
  const status = JSON.parse(execFileSync(process.execPath, [
    path.join(root, 'node_modules', 'supabase', 'dist', 'supabase.js'),
    'status', '--workdir', 'infrastructure', '--output', 'json',
  ], { cwd: root, encoding: 'utf8', timeout: 30_000, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }));
  const endpoint = new URL(status.API_URL);
  assert.equal(endpoint.protocol, 'http:');
  assert.ok(['127.0.0.1', 'localhost'].includes(endpoint.hostname));
  assert.equal(endpoint.port, '54321');
  const publicKey = status.PUBLISHABLE_KEY || status.ANON_KEY;
  const adminKey = status.SERVICE_ROLE_KEY || status.SECRET_KEY;
  assert.ok(publicKey && adminKey);
  adminHeaders = { apikey: adminKey, Authorization: `Bearer ${adminKey}`, 'Content-Type': 'application/json' };
  const databaseEnv = readFileSync(path.join(root, 'infrastructure', '.env.api.local'), 'utf8');
  const database = new URL(/^DATABASE_URL=(\S+)\r?$/m.exec(databaseEnv)?.[1] ?? '');
  assert.ok(database.protocol === 'postgresql:' && database.hostname === '127.0.0.1' &&
    database.port === '54322' && database.pathname === '/postgres' &&
    database.username === 'nene_api' && !database.search && !database.hash &&
    /^[A-Za-z0-9_-]{43,}$/.test(database.password));

  const port = await unusedPort();
  stage = 'API startup';
  const base = `http://127.0.0.1:${port}/api/v1`;
  api = spawn(process.execPath, ['dist/main.js'], {
    cwd: path.join(root, 'backend'), windowsHide: true,
    env: {
      ...process.env, NODE_ENV: 'development', HOST: '127.0.0.1', PORT: String(port),
      SUPABASE_URL: authOrigin, SUPABASE_PUBLISHABLE_KEY: publicKey,
      DATABASE_URL: database.href, DATABASE_SSL_MODE: 'disable', DATABASE_SSL_CA_FILE: '',
    },
    stdio: ['ignore', 'ignore', 'ignore'],
  });
  let ready = false;
  for (let attempt = 0; attempt < 30; attempt++) {
    if (api.exitCode !== null) throw new Error('Local API exited before becoming ready.');
    try {
      const health = await request(`${base}/health`);
      if (health.ok) { ready = true; break; }
    } catch { /* Startup connection refusal is expected briefly. */ }
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  assert.ok(ready, 'API startup timed out');
  stage = 'unauthenticated requests';
  assert.equal((await request(`${base}/me`)).status, 401);
  assert.equal((await request(`${base}/me`, { headers: { Authorization: 'Bearer invalid' } })).status, 401);

  stage = 'synthetic identity creation';
  const created = await request(`${authOrigin}/auth/v1/admin/users`, {
    method: 'POST', headers: adminHeaders,
    body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { role: 'officer' } }),
  });
  assert.ok(created.ok, 'Could not create local synthetic identity');
  const user = await created.json();
  assert.match(user.id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
  identityId = user.id;
  stage = 'synthetic profile creation';
  sql(`insert into bank.user_profiles (id, display_name, role) values ('${identityId}', 'Local smoke fixture', 'customer');`);
  stage = 'password sign-in';
  const signedIn = await request(`${authOrigin}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: publicKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (!signedIn.ok) {
    const diagnostic = await signedIn.json();
    const code = diagnostic.error_code ?? diagnostic.code;
    console.error(`Local Auth sign-in status: ${signedIn.status}${typeof code === 'string' && /^[a-z_]{1,80}$/.test(code) ? `; code: ${code}` : ''}.`);
  }
  assert.ok(signedIn.ok, 'Local sign-in failed');
  const { access_token: token } = await signedIn.json();
  const headers = { Authorization: `Bearer ${token}` };
  stage = 'authenticated customer profile';
  let response = await request(`${base}/me`, { headers });
  assert.equal(response.status, 200);
  let profile = await response.json();
  assert.equal(profile.id, identityId);
  assert.equal(profile.role, 'customer', 'Client-controlled metadata must not grant officer access');

  stage = 'server-owned officer role';
  sql(`update bank.user_profiles set role = 'officer', updated_at = now() where id = '${identityId}';`);
  response = await request(`${base}/me`, { headers });
  assert.equal(response.status, 200);
  profile = await response.json();
  assert.equal(profile.role, 'officer');

  stage = 'disabled profile rejection';
  sql(`update bank.user_profiles set status = 'disabled', updated_at = now() where id = '${identityId}';`);
  assert.equal((await request(`${base}/me`, { headers })).status, 403);
  stage = 'missing profile rejection';
  sql(`delete from bank.user_profiles where id = '${identityId}';`);
  assert.equal((await request(`${base}/me`, { headers })).status, 403);
  console.log('Passed local API/Auth/PostgreSQL integration: anonymous and invalid sessions rejected; customer/officer roles read from server; metadata cannot elevate access; disabled and missing profiles denied.');
} catch (error) {
  failed = true;
  const statusDetail = error instanceof assert.AssertionError && typeof error.actual === 'number' && typeof error.expected === 'number'
    ? ` (expected ${error.expected}, received ${error.actual})` : '';
  console.error(`Local integration check failed at ${stage}${statusDetail}. No credentials or provider responses were logged.`);
} finally {
  if (identityId) {
    try {
      sql(`delete from bank.user_profiles where id = '${identityId}';`);
      const removed = await request(`${authOrigin}/auth/v1/admin/users/${identityId}`, { method: 'DELETE', headers: adminHeaders });
      assert.ok(removed.ok);
      console.log('Removed the temporary local smoke-test identity and profile.');
    } catch {
      failed = true;
      console.error('Local fixture cleanup failed. Remove the nene-smoke identity from the LOCAL Supabase Studio before the next check.');
    }
  }
  if (api && api.exitCode === null) api.kill();
  process.exitCode = failed ? 1 : 0;
}
