import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { parseEnv } from 'node:util';
import path from 'node:path';

// LOCAL ONLY. Generated coloured PNGs exercise storage, not face recognition.
// Fixtures have random IDs and are removed in finally; never print secrets/images.
const root = fileURLToPath(new URL('../', import.meta.url));
const requireBackend = createRequire(new URL('../backend/package.json', import.meta.url));
const fixtures = ['officer', 'customer', 'customer'].map((role, index) => ({
  id: randomUUID(), role, name: `Synthetic reference ${role} ${index}`,
  email: `reference-${randomUUID()}@example.invalid`,
  password: randomBytes(24).toString('base64url'),
}));
let origin, publicKey, adminHeaders, apiEnv, base, api;
let stage = 'local configuration';
let fixturesStarted = false;
let failed = false;

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
  return fetch(url, { ...options, signal: AbortSignal.timeout(20_000) });
}

function call(endpoint, token, method = 'GET', body, key) {
  return request(`${base}${endpoint}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      'Content-Type': 'application/json',
      ...(key ? { 'Idempotency-Key': key } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

async function success(response) {
  assert.ok(response.status === 200 || response.status === 201, `Unexpected HTTP status ${response.status}`);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  return response.json();
}

async function startApi() {
  let chosen;
  for (let port = 3001; port <= 3005; port++) {
    const listener = createServer();
    try {
      await new Promise((resolve, reject) => {
        listener.once('error', reject);
        listener.listen(port, '127.0.0.1', resolve);
      });
      await new Promise(resolve => listener.close(resolve));
      chosen = port;
      break;
    } catch { listener.close(); }
  }
  if (!chosen) throw new Error('No free Nene API port; no listener stopped.');
  base = `http://127.0.0.1:${chosen}/api/v1`;
  api = spawn(process.execPath, ['dist/main.js'], {
    cwd: path.join(root, 'backend'), windowsHide: true, stdio: 'ignore',
    env: { ...apiEnv, PORT: String(chosen) },
  });
  for (let attempt = 0; attempt < 50; attempt++) {
    if (api.exitCode !== null) throw new Error('API exited during startup.');
    try { if ((await request(`${base}/health`)).ok) return; } catch { /* Startup only. */ }
    await new Promise(resolve => setTimeout(resolve, 200));
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
  const url = new URL(status.API_URL);
  assert.equal(url.protocol, 'http:');
  assert.equal(url.hostname, '127.0.0.1');
  assert.equal(url.pathname, '/');
  assert.equal(url.username + url.password + url.search + url.hash, '');
  origin = url.origin;
  publicKey = status.PUBLISHABLE_KEY || status.ANON_KEY;
  const adminKey = status.SECRET_KEY || status.SERVICE_ROLE_KEY;
  assert.ok(publicKey && adminKey);
  adminHeaders = { apikey: adminKey, Authorization: `Bearer ${adminKey}`, 'Content-Type': 'application/json' };
  const configured = parseEnv(readFileSync(path.join(root, 'infrastructure', '.env.api.local'), 'utf8'));
  const database = new URL(configured.DATABASE_URL);
  assert.equal(database.protocol, 'postgresql:');
  assert.equal(database.hostname, '127.0.0.1');
  assert.equal(database.username, 'nene_api');
  assert.equal(database.pathname, '/postgres');
  assert.equal(database.search + database.hash, '');
  assert.equal(new URL(status.DB_URL).port, database.port);
  apiEnv = {
    ...process.env, NODE_ENV: 'development', HOST: '127.0.0.1',
    SUPABASE_URL: origin, SUPABASE_PUBLISHABLE_KEY: publicKey, SUPABASE_SECRET_KEY: adminKey,
    DATABASE_URL: database.href, DATABASE_SSL_MODE: 'disable', DATABASE_SSL_CA_FILE: '',
  };
  stage = 'API startup and anonymous denial';
  await startApi();
  assert.equal((await call('/me/identity')).status, 401);
  fixturesStarted = true;
  stage = 'synthetic local fixtures';
  for (const fixture of fixtures) {
    const created = await request(`${origin}/auth/v1/admin/users`, {
      method: 'POST', headers: adminHeaders,
      body: JSON.stringify({ id: fixture.id, email: fixture.email, password: fixture.password, email_confirm: true }),
    });
    assert.equal(created.status, 200);
    assert.equal((await created.json()).id, fixture.id);
    sql(`insert into bank.user_profiles (id,display_name,role) values ('${fixture.id}','${fixture.name}','${fixture.role}');`);
    const login = await request(`${origin}/auth/v1/token?grant_type=password`, {
      method: 'POST', headers: { apikey: publicKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: fixture.email, password: fixture.password }),
    });
    assert.equal(login.status, 200);
    fixture.token = (await login.json()).access_token;
    assert.equal(typeof fixture.token, 'string');
  }
  const [officer, customer, other] = fixtures;
  stage = 'initial status and role denial';
  let summary = await success(await call('/me/identity', customer.token));
  assert.equal(summary.status, 'not_started');
  assert.equal((await call('/me/identity', officer.token)).status, 403);
  assert.equal((await call(`/officer/customers/${customer.id}/identity`, other.token)).status, 403);
  const startBody = { noticeVersion: summary.notice.version, acknowledged: true };
  const startKey = randomUUID();
  stage = 'acknowledgement and enrollment replay';
  assert.equal((await call('/me/identity/cases', customer.token, 'POST', { ...startBody, acknowledged: false }, randomUUID())).status, 400);
  assert.equal((await call('/me/identity/cases', customer.token, 'POST', { ...startBody, isVerified: true }, randomUUID())).status, 400);
  summary = await success(await call('/me/identity/cases', customer.token, 'POST', startBody, startKey));
  assert.equal(summary.status, 'draft');
  const caseId = summary.caseId;
  assert.match(caseId, /^[0-9a-f-]{36}$/i);
  const repeatedStart = await success(await call('/me/identity/cases', customer.token, 'POST', startBody, startKey));
  assert.equal(repeatedStart.caseId, caseId);
  assert.equal(repeatedStart.version, summary.version);
  const casePath = `/identity/cases/${caseId}`;
  assert.equal((await call(casePath, other.token)).status, 404);
  stage = 'invalid evidence and private upload';
  const sharp = requireBackend('sharp');
  const png = await sharp({ create: { width: 48, height: 48, channels: 3, background: '#4C929E' } }).png().toBuffer();
  const otherPng = await sharp({ create: { width: 48, height: 48, channels: 3, background: '#F6C9A5' } }).png().toBuffer();
  const uploadBody = { expectedVersion: summary.version, contentType: 'image/png', dataBase64: png.toString('base64') };
  assert.equal((await call(`${casePath}/evidence`, customer.token, 'POST', { ...uploadBody, dataBase64: 'not-an-image' }, randomUUID())).status, 400);
  const uploadKey = randomUUID();
  summary = await success(await call(`${casePath}/evidence`, customer.token, 'POST', uploadBody, uploadKey));
  assert.ok(summary.evidenceId);
  assert.equal((await success(await call(`${casePath}/evidence`, customer.token, 'POST', uploadBody, uploadKey))).evidenceId, summary.evidenceId);
  assert.equal((await call(`${casePath}/evidence`, customer.token, 'POST', { ...uploadBody, dataBase64: otherPng.toString('base64') }, uploadKey)).status, 409);
  let evidencePath = `${casePath}/evidence/${summary.evidenceId}`;
  const image = await call(evidencePath, customer.token);
  assert.equal(image.status, 200);
  assert.equal(image.headers.get('cache-control'), 'no-store');
  assert.ok((await image.arrayBuffer()).byteLength > 0);
  assert.equal((await call(evidencePath, other.token)).status, 404);
  assert.equal((await call(`${casePath}/evidence`, other.token, 'POST', uploadBody, randomUUID())).status, 404);
  const objectKey = sql(`select object_key from bank.identity_evidence where id = '${summary.evidenceId}';`);
  const privateDirect = await request(`${origin}/storage/v1/object/authenticated/identity-evidence/${objectKey}`, {
    headers: { apikey: publicKey, Authorization: `Bearer ${customer.token}` },
  });
  assert.equal(privateDirect.ok, false);
  assert.equal((await request(`${origin}/storage/v1/object/public/identity-evidence/${objectKey}`)).ok, false);
  stage = 'submission and officer correction';
  const submitBody = { expectedVersion: summary.version };
  const submitKey = randomUUID();
  summary = await success(await call(`${casePath}/submit`, customer.token, 'POST', submitBody, submitKey));
  assert.equal(summary.status, 'submitted');
  assert.equal((await success(await call(`${casePath}/submit`, customer.token, 'POST', submitBody, submitKey))).version, summary.version);
  const reviewPath = `/officer/identity/cases/${caseId}/reviews`;
  const correction = { expectedVersion: summary.version, action: 'request_changes', associationConfirmed: false, reason: 'Please retake with the full face visible.' };
  assert.equal((await call(reviewPath, customer.token, 'POST', correction, randomUUID())).status, 403);
  summary = await success(await call(reviewPath, officer.token, 'POST', correction, randomUUID()));
  assert.equal(summary.status, 'needs_changes');
  assert.equal(summary.correctionReason, correction.reason);
  stage = 'officer-assisted capture and competing decisions';
  summary = await success(await call(`/officer/customers/${customer.id}/identity/cases`, officer.token, 'POST', startBody, randomUUID()));
  assert.equal(summary.status, 'draft');
  summary = await success(await call(`${casePath}/evidence`, officer.token, 'POST', { ...uploadBody, expectedVersion: summary.version }, randomUUID()));
  evidencePath = `${casePath}/evidence/${summary.evidenceId}`;
  summary = await success(await call(`${casePath}/submit`, officer.token, 'POST', { expectedVersion: summary.version }, randomUUID()));
  const accept = { expectedVersion: summary.version, action: 'accept_reference', associationConfirmed: true, reason: null };
  assert.equal((await call(reviewPath, officer.token, 'POST', { ...accept, associationConfirmed: false }, randomUUID())).status, 400);
  const decisions = await Promise.all([
    call(reviewPath, officer.token, 'POST', accept, randomUUID()),
    call(reviewPath, officer.token, 'POST', accept, randomUUID()),
  ]);
  assert.equal(decisions.filter(response => response.status === 409).length, 1);
  summary = await success(decisions.find(response => response.status !== 409));
  assert.equal(summary.status, 'reference_accepted');
  assert.equal(summary.allowedActions.includes('accept_reference'), false);
  stage = 'accepted state persists across API restart';
  await stopApi();
  await startApi();
  summary = await success(await call('/me/identity', customer.token));
  assert.equal(summary.status, 'reference_accepted');
  assert.equal((await call(evidencePath, officer.token)).status, 200);
  stage = 'requested name edit invalidates accepted reference';
  await success(await call(`/officer/customers/${customer.id}`, officer.token, 'PATCH', {
    displayName: 'Synthetic revised reference customer', phone: null, address: null,
    requestReason: 'Customer requests correction of demo display name.',
  }));
  summary = await success(await call('/me/identity', customer.token));
  assert.equal(summary.status, 'needs_changes');
  assert.equal(summary.customerName, 'Synthetic revised reference customer');
  assert.equal((await call(reviewPath, officer.token, 'POST', accept, randomUUID())).status, 409);
  stage = 'expiry blocks access and cleanup deletes physical evidence';
  summary = await success(await call('/me/identity/cases', customer.token, 'POST', startBody, randomUUID()));
  summary = await success(await call(`${casePath}/evidence`, customer.token, 'POST', { ...uploadBody, expectedVersion: summary.version }, randomUUID()));
  const expiredEvidenceId = summary.evidenceId;
  const expiredObjectKey = sql(`select object_key from bank.identity_evidence where id = '${expiredEvidenceId}';`);
  sql(`begin;
    update bank.identity_cases set expires_at=now()-interval '1 second' where id='${caseId}';
    update bank.identity_evidence set expires_at=now()-interval '1 second' where id='${expiredEvidenceId}';
    commit;`);
  summary = await success(await call('/me/identity', customer.token));
  assert.equal(summary.status, 'needs_changes');
  assert.equal(summary.expired, true);
  assert.equal(summary.evidenceId, null);
  assert.equal((await call(`${casePath}/evidence/${expiredEvidenceId}`, customer.token)).status, 404);
  execFileSync(process.execPath, ['dist/identity/cleanup.js'], {
    cwd: path.join(root, 'backend'), env: apiEnv, windowsHide: true,
    timeout: 30_000, stdio: ['ignore', 'pipe', 'pipe'],
  });
  assert.equal(sql(`select deleted_at is not null from bank.identity_evidence where id='${expiredEvidenceId}';`), 't');
  assert.equal((await request(`${origin}/storage/v1/object/identity-evidence/${expiredObjectKey}`, { headers: adminHeaders })).ok, false);
  summary = await success(await call('/me/identity/cases', customer.token, 'POST', startBody, randomUUID()));
  assert.equal(summary.status, 'draft');
  assert.equal(summary.expired, false);
  console.log('Passed local reference enrollment: private generated-image upload/read, direct Storage and role/ownership denial, exact retries, correction/resubmission, officer assistance, competing review conflict, restart persistence, name invalidation, expiry and physical cleanup. No face matching or real-person capture was tested.');
} catch (error) {
  failed = true;
  const detail = error instanceof assert.AssertionError && typeof error.actual === 'number' && typeof error.expected === 'number'
    ? ` (expected ${error.expected}, received ${error.actual})`
    : error instanceof Error && /^Unexpected HTTP status \d{3}$/.test(error.message)
      ? ` (${error.message})` : '';
  console.error(`Reference-flow check failed at ${stage}${detail}. No credentials, images or response bodies logged.`);
} finally {
  await stopApi();
  if (fixturesStarted) {
    try {
      const ids = fixtures.map(fixture => `'${fixture.id}'`).join(',');
      const objects = JSON.parse(sql(`select coalesce(json_agg(e.object_key), '[]'::json)
        from bank.identity_evidence e join bank.identity_cases c on c.id = e.case_id where c.customer_id in (${ids});`));
      if (objects.length) {
        const removed = await request(`${origin}/storage/v1/object/identity-evidence`, {
          method: 'DELETE', headers: adminHeaders, body: JSON.stringify({ prefixes: objects }),
        });
        assert.ok(removed.ok);
      }
      sql(`begin;
        delete from bank.identity_commands where actor_id in (${ids}) or customer_id in (${ids});
        delete from bank.identity_reviews where case_id in (select id from bank.identity_cases where customer_id in (${ids}));
        delete from bank.identity_evidence where case_id in (select id from bank.identity_cases where customer_id in (${ids}));
        delete from bank.identity_cases where customer_id in (${ids});
        delete from bank.profile_edit_audit where actor_id in (${ids}) or customer_id in (${ids});
        delete from bank.user_profiles where id in (${ids});
        commit;`);
      for (const fixture of fixtures) {
        const removed = await request(`${origin}/auth/v1/admin/users/${fixture.id}`, { method: 'DELETE', headers: adminHeaders });
        assert.ok(removed.ok || removed.status === 404);
      }
      console.log('Removed temporary reference-flow Auth identities, database records and private files.');
    } catch {
      failed = true;
      console.error('Reference fixture cleanup failed. Inspect only synthetic reference-* users in local Studio; do not reset the database.');
    }
  }
  process.exitCode = failed ? 1 : 0;
}
