import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// LOCAL ONLY. Creates synthetic Auth/database fixtures and removes them in
// finally. Never prints passwords, tokens, provider bodies or database values.
const root = fileURLToPath(new URL('../', import.meta.url));
const origin = 'http://127.0.0.1:54321';
const officerId = randomUUID();
const officerEmail = `flow-officer-${officerId}@example.invalid`;
const officerPassword = randomBytes(24).toString('base64url');
const fixtureIds = new Set([officerId]);
let api;
let publicKey;
let adminHeaders;
let apiEnv;
let base;
let stage = 'local configuration';
let failed = false;
let fixturesStarted = false;

function sql(statement) {
  const result = spawnSync('docker', [
    'exec', '--interactive', 'supabase_db_nene-local', 'psql', '-X',
    '--set', 'ON_ERROR_STOP=1', '--username', 'postgres', '--dbname', 'postgres',
    '--quiet', '--tuples-only', '--no-align',
  ], { input: statement, encoding: 'utf8', windowsHide: true, timeout: 15_000 });
  if (result.error || result.status !== 0) throw new Error('Fixture database operation failed.');
  return result.stdout.trim();
}

function request(url, options = {}) {
  return fetch(url, { ...options, signal: AbortSignal.timeout(15_000) });
}

async function signIn(email, password) {
  const response = await request(`${origin}/auth/v1/token?grant_type=password`, {
    method: 'POST', headers: { apikey: publicKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  assert.equal(response.status, 200);
  const session = await response.json();
  assert.equal(typeof session.access_token, 'string');
  return session.access_token;
}

function call(endpoint, token, method = 'GET', body, extraHeaders = {}) {
  return request(`${base}${endpoint}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...extraHeaders },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

async function startApi() {
  const listener = createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', resolve);
  });
  const port = listener.address().port;
  await new Promise(resolve => listener.close(resolve));
  base = `http://127.0.0.1:${port}/api/v1`;
  api = spawn(process.execPath, ['dist/main.js'], {
    cwd: path.join(root, 'backend'), windowsHide: true,
    env: { ...apiEnv, PORT: String(port) }, stdio: 'ignore',
  });
  for (let attempt = 0; attempt < 40; attempt++) {
    if (api.exitCode !== null) throw new Error('API exited during startup.');
    try { if ((await request(`${base}/health`)).ok) return; } catch { /* Startup only. */ }
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  throw new Error('API did not become ready.');
}

async function stopApi() {
  if (!api || api.exitCode !== null) return;
  const child = api;
  const exited = new Promise(resolve => child.once('exit', resolve));
  child.kill();
  await exited;
}

try {
  const status = JSON.parse(execFileSync(process.execPath, [
    path.join(root, 'node_modules', 'supabase', 'dist', 'supabase.js'),
    'status', '--workdir', 'infrastructure', '--output', 'json',
  ], { cwd: root, encoding: 'utf8', timeout: 30_000, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }));
  assert.equal(status.API_URL, origin);
  publicKey = status.PUBLISHABLE_KEY || status.ANON_KEY;
  const adminKey = status.SECRET_KEY || status.SERVICE_ROLE_KEY;
  assert.ok(publicKey && adminKey);
  adminHeaders = { apikey: adminKey, Authorization: `Bearer ${adminKey}`, 'Content-Type': 'application/json' };
  const databaseEnv = readFileSync(path.join(root, 'infrastructure', '.env.api.local'), 'utf8');
  const database = new URL(/^DATABASE_URL=(\S+)\r?$/m.exec(databaseEnv)?.[1] ?? '');
  assert.equal(database.protocol, 'postgresql:');
  assert.equal(database.hostname, '127.0.0.1');
  assert.equal(database.port, '54322');
  assert.equal(database.username, 'nene_api');
  assert.equal(database.pathname, '/postgres');
  assert.equal(database.search, '');
  assert.equal(database.hash, '');
  assert.match(database.password, /^[A-Za-z0-9_-]{43,}$/);
  apiEnv = {
    ...process.env, NODE_ENV: 'development', HOST: '127.0.0.1',
    SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: publicKey, SUPABASE_SECRET_KEY: adminKey,
    DATABASE_URL: database.href, DATABASE_SSL_MODE: 'disable', DATABASE_SSL_CA_FILE: '',
  };
  stage = 'API startup';
  await startApi();
  stage = 'unauthenticated rejection';
  for (const endpoint of ['/me/accounts', '/officer/customers?query=test']) {
    assert.equal((await request(`${base}${endpoint}`)).status, 401);
  }
  stage = 'local officer fixture';
  fixturesStarted = true;
  const officer = await request(`${origin}/auth/v1/admin/users`, {
    method: 'POST', headers: adminHeaders,
    body: JSON.stringify({ id: officerId, email: officerEmail, password: officerPassword, email_confirm: true }),
  });
  assert.equal(officer.status, 200);
  stage = 'officer fixture UUID verification';
  assert.equal((await officer.json()).id, officerId);
  stage = 'officer profile fixture insertion';
  sql(`insert into bank.user_profiles (id, display_name, role) values ('${officerId}', 'Synthetic flow officer', 'officer');`);
  stage = 'officer fixture password sign-in';
  const officerToken = await signIn(officerEmail, officerPassword);
  stage = 'officer creates customer and zero-balance account';
  const payload = {
    email: `flow-customer-${randomUUID()}@example.invalid`,
    displayName: 'Synthetic flow customer',
    phone: '+84 900 123 456',
    address: 'Demo address 1',
    initialPassword: randomBytes(24).toString('base64url'),
  };
  const key = randomUUID();
  const idempotency = { 'Idempotency-Key': key };
  const create = () => call('/officer/customers', officerToken, 'POST', payload, idempotency);
  const [created, concurrentCreate] = await Promise.all([create(), create()]);
  assert.equal(created.status, 201);
  assert.ok(concurrentCreate.status === 200 || concurrentCreate.status === 201);
  assert.equal(created.headers.get('cache-control'), 'no-store');
  const customer = await created.json();
  assert.match(customer.id, /^[0-9a-f-]{36}$/i);
  const concurrentCustomer = await concurrentCreate.json();
  assert.equal(concurrentCustomer.id, customer.id);
  assert.equal(concurrentCustomer.accounts[0].id, customer.accounts[0].id);
  fixtureIds.add(customer.id);
  assert.equal(customer.email, payload.email);
  assert.equal(customer.displayName, payload.displayName);
  assert.equal(customer.accounts.length, 1);
  assert.equal(customer.accounts[0].type, 'checking');
  assert.equal(customer.accounts[0].currency, 'VND');
  assert.equal(customer.accounts[0].balanceMinor, '0');
  assert.equal(JSON.stringify(customer).includes(payload.initialPassword), false);
  stage = 'concurrent replay and changed-payload rejection';
  for (const replay of await Promise.all([create(), create()])) {
    assert.ok(replay.status === 200 || replay.status === 201);
    const result = await replay.json();
    assert.equal(result.id, customer.id);
    assert.equal(result.accounts[0].id, customer.accounts[0].id);
  }
  for (const altered of [
    { ...payload, displayName: 'Different requested name' },
    { ...payload, initialPassword: `${payload.initialPassword}x` },
  ]) {
    assert.equal((await call('/officer/customers', officerToken, 'POST', altered, idempotency)).status, 409);
  }
  stage = 'duplicate email cannot create or adopt another identity';
  assert.equal((await call('/officer/customers', officerToken, 'POST', payload,
    { 'Idempotency-Key': randomUUID() })).status, 409);
  stage = 'customer sign-in, ownership and edit permissions';
  const customerToken = await signIn(payload.email, payload.initialPassword);
  const me = await call('/me', customerToken);
  assert.equal(me.status, 200);
  assert.equal((await me.json()).role, 'customer');
  const ownAccounts = await call('/me/accounts', customerToken);
  assert.equal(ownAccounts.status, 200);
  assert.deepEqual((await ownAccounts.json()).accounts, customer.accounts);
  assert.equal((await call('/officer/customers?query=Synthetic', customerToken)).status, 403);
  assert.equal((await call(`/officer/customers/${customer.id}`, customerToken)).status, 403);
  assert.equal((await call('/officer/customers', customerToken, 'POST', payload, { 'Idempotency-Key': randomUUID() })).status, 403);
  assert.equal((await call('/me/contact', customerToken, 'PATCH', { phone: '0999999999', address: 'Demo address 2', role: 'officer' })).status, 400);
  const contact = { phone: '0999999999', address: 'Demo address 2' };
  const updated = await call('/me/contact', customerToken, 'PATCH', contact);
  assert.equal(updated.status, 200);
  assert.equal((await updated.json()).address, contact.address);
  assert.equal((await call('/me/accounts', officerToken)).status, 403);
  stage = 'officer search and requested edit';
  const empty = await call('/officer/customers?query=', officerToken);
  assert.deepEqual((await empty.json()).customers, []);
  const search = await call(`/officer/customers?query=${encodeURIComponent(payload.email)}`, officerToken);
  assert.equal(search.status, 200);
  assert.ok((await search.json()).customers.some(item => item.id === customer.id));
  const officerChange = {
    displayName: 'Synthetic corrected name', phone: contact.phone,
    address: 'Demo address 3', requestReason: 'Customer requested contact correction',
  };
  assert.equal((await call(`/officer/customers/${customer.id}`, officerToken, 'PATCH',
    { ...officerChange, requestReason: '' })).status, 400);
  const officerUpdated = await call(`/officer/customers/${customer.id}`, officerToken, 'PATCH', officerChange);
  assert.equal(officerUpdated.status, 200);
  assert.equal((await officerUpdated.json()).displayName, officerChange.displayName);
  stage = 'ownership with a separate customer';
  const otherPayload = { ...payload, email: `flow-other-${randomUUID()}@example.invalid`, displayName: 'Other synthetic customer' };
  const otherResponse = await call('/officer/customers', officerToken, 'POST', otherPayload, { 'Idempotency-Key': randomUUID() });
  assert.equal(otherResponse.status, 201);
  const other = await otherResponse.json();
  fixtureIds.add(other.id);
  const otherToken = await signIn(otherPayload.email, otherPayload.initialPassword);
  const otherAccounts = (await (await call('/me/accounts', otherToken)).json()).accounts;
  assert.equal(otherAccounts.length, 1);
  assert.notEqual(otherAccounts[0].id, customer.accounts[0].id);
  assert.equal((await call('/me/contact', otherToken, 'PATCH', { ...contact, customerId: customer.id })).status, 400);
  stage = 'persistence and idempotency after API restart';
  await stopApi();
  await startApi();
  const persisted = await call('/me', customerToken);
  assert.equal(persisted.status, 200);
  const persistedProfile = await persisted.json();
  assert.equal(persistedProfile.displayName, officerChange.displayName);
  assert.equal(persistedProfile.address, officerChange.address);
  const replayAfterRestart = await create();
  assert.ok(replayAfterRestart.status === 200 || replayAfterRestart.status === 201);
  const replayed = await replayAfterRestart.json();
  assert.equal(replayed.id, customer.id);
  assert.equal(replayed.accounts.length, 1);
  console.log('Passed local customer flow: officer creation/search/requested edit; customer login, own accounts and contact edit; denied privilege/ownership changes; concurrent replay and restart persistence.');
} catch (error) {
  failed = true;
  const detail = error instanceof assert.AssertionError && typeof error.actual === 'number' && typeof error.expected === 'number'
    ? ` (expected ${error.expected}, received ${error.actual})` : '';
  console.error(`Customer-flow check failed at ${stage}${detail}. No credentials or response bodies logged.`);
} finally {
  await stopApi();
  if (fixturesStarted) {
    try {
      const reserved = sql(`select customer_id from bank.customer_creation_requests where officer_id = '${officerId}';`);
      for (const reservedId of reserved.split(/\r?\n/).filter(Boolean)) {
        assert.match(reservedId, /^[0-9a-f-]{36}$/i);
        fixtureIds.add(reservedId);
      }
      const ids = [...fixtureIds].map(id => `'${id}'`).join(',');
      sql(`begin;
        delete from bank.profile_edit_audit where actor_id in (${ids}) or customer_id in (${ids});
        delete from bank.customer_creation_requests where officer_id = '${officerId}';
        delete from bank.banking_accounts where owner_id in (${ids});
        delete from bank.user_profiles where id in (${ids});
        commit;`);
      for (const id of fixtureIds) {
        const removed = await request(`${origin}/auth/v1/admin/users/${id}`, { method: 'DELETE', headers: adminHeaders });
        assert.ok(removed.ok || removed.status === 404);
      }
      console.log('Removed temporary customer-flow profiles, accounts, requests, audit records and Auth identities.');
    } catch {
      failed = true;
      console.error('Local customer-flow fixture cleanup failed. Inspect the synthetic flow-* users in LOCAL Studio; do not reset the database.');
    }
  }
  process.exitCode = failed ? 1 : 0;
}
