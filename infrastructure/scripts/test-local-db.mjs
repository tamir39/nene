import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const containerName = 'supabase_db_nene-local';
const testFiles = [
  new URL('../supabase/tests/database/identity_access.test.sql', import.meta.url),
  new URL('../supabase/tests/database/customer_accounts.test.sql', import.meta.url),
];

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

  let total = 0;
  for (const testFile of testFiles) {
    const result = spawnSync('docker', [
      'exec', '--interactive', containerName, 'psql', '-X',
      '--set', 'ON_ERROR_STOP=1', '--username', 'postgres', '--dbname', 'postgres',
      '--tuples-only', '--no-align',
    ], {
      input: readFileSync(testFile, 'utf8'),
      encoding: 'utf8', timeout: 30_000, windowsHide: true,
    });

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
