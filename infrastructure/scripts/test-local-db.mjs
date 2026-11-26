import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const containerName = 'supabase_db_nene-local';
const testFiles = [
  new URL('../supabase/tests/database/identity_access.test.sql', import.meta.url),
  new URL('../supabase/tests/database/customer_accounts.test.sql', import.meta.url),
  new URL('../supabase/tests/database/identity_reference.test.sql', import.meta.url),
  new URL('../supabase/tests/database/face_verification.test.sql', import.meta.url),
];
const migrationsDir = new URL('../supabase/migrations/', import.meta.url);

function psql(input, extra = []) {
  return spawnSync('docker', [
    'exec', '--interactive', containerName, 'psql', '-X',
    '--set', 'ON_ERROR_STOP=1', '--username', 'postgres', '--dbname', 'postgres',
    '--tuples-only', '--no-align', ...extra,
  ], { input, encoding: 'utf8', timeout: 30_000, windowsHide: true });
}

// Migrations not yet applied to the local stack run inside each test transaction
// and roll back with it, so tests cover the tracked schema without changing the database.
function pendingMigrations() {
  const applied = psql('select version from supabase_migrations.schema_migrations;');
  if (applied.error || applied.status !== 0) {
    throw new Error('Could not read the applied local migrations.');
  }
  const versions = new Set(applied.stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean));
  const latest = [...versions].sort().at(-1) ?? '';
  const pending = readdirSync(migrationsDir)
    .filter((name) => /^\d{14}_[a-z0-9_]+\.sql$/.test(name) && !versions.has(name.slice(0, 14)))
    .sort();
  if (pending.some((name) => name.slice(0, 14) < latest)) {
    throw new Error('A pending migration is older than the latest applied migration.');
  }
  if (pending.length) console.log(`Applying ${pending.length} pending migration(s) inside each rolled-back test transaction.`);
  return pending.map((name) => readFileSync(new URL(name, migrationsDir), 'utf8')).join('\n');
}

try {
  const inspected = spawnSync('docker', ['inspect', '--type', 'container', containerName], {
    encoding: 'utf8', timeout: 15_000, windowsHide: true,
  });
  if (inspected.error || inspected.status !== 0) {
    throw new Error('Start Docker and the Nene Supabase stack before running database tests.');
  }
  const containers = JSON.parse(inspected.stdout);
  if (
    containers.length !== 1 ||
    containers[0].Name !== `/${containerName}` ||
    !containers[0].State?.Running ||
    !/(?:^|\/)supabase\/postgres(?::|@)/.test(containers[0].Config?.Image ?? '')
  ) {
    throw new Error('The expected running Nene PostgreSQL container was not found.');
  }

  const pending = pendingMigrations();
  let total = 0;
  for (const testFile of testFiles) {
    const sql = readFileSync(testFile, 'utf8');
    if (!/^begin;\s*$/m.test(sql)) {
      throw new Error('Database tests failed or did not finish with a complete passing plan and rollback.');
    }
    const result = psql(sql.replace(/^begin;\s*$/m, (line) => `${line}\n${pending}\n`));

    const output = result.stdout ?? '';
    const lines = output.split(/\r?\n/);
    console.log(fileURLToPath(testFile));
    // Display TAP results, not arbitrary database or process output.
    for (const line of lines.filter((line) => /^(?:1\.\.\d+|ok \d+|not ok \d+|#|Bail out!)/.test(line))) {
      console.log(line);
    }
    const plans = [...output.matchAll(/^1\.\.(\d+)\s*$/gm)];
    const assertions = [...output.matchAll(/^ok (\d+)(?:\s|$)/gm)];
    const expected = plans.length === 1 ? Number(plans[0][1]) : 0;
    const sequential = assertions.every((match, index) => Number(match[1]) === index + 1);
    if (
      result.error || result.status !== 0 ||
      /^(?:not ok\b|Bail out!)/m.test(output) ||
      expected < 1 || assertions.length !== expected || !sequential ||
      !/^ROLLBACK\s*$/m.test(output)
    ) {
      throw new Error('Database tests failed or did not finish with a complete passing plan and rollback.');
    }
    total += expected;
  }
  console.log(`Database access tests passed: ${total} assertions; synthetic fixtures rolled back.`);
} catch (error) {
  const safeMessages = new Set([
    'Start Docker and the Nene Supabase stack before running database tests.',
    'The expected running Nene PostgreSQL container was not found.',
    'Database tests failed or did not finish with a complete passing plan and rollback.',
  ]);
  console.error(error instanceof Error && safeMessages.has(error.message)
    ? error.message
    : 'Could not run the local database tests. Check Docker access and the tracked test files.');
  process.exitCode = 1;
}
