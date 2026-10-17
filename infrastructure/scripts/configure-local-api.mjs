import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

// Only configures the named local Docker database. It cannot target a hosted DB.
const containerName = 'supabase_db_nene-local';
const environmentPath = fileURLToPath(new URL('../.env.api.local', import.meta.url));

function docker(args, options = {}) {
  const result = spawnSync('docker', args, {
    encoding: 'utf8',
    timeout: 15_000,
    windowsHide: true,
    ...options,
  });
  if (result.error || result.status !== 0) {
    // Do not print SQL, container output, passwords, or connection URLs.
    throw new Error('Local Docker operation failed. Start Docker and the Nene Supabase stack, then retry.');
  }
  return result.stdout.trim();
}

function readOrCreateConnection() {
  if (!existsSync(environmentPath)) {
    const connection = new URL('postgresql://nene_api@127.0.0.1:54322/postgres');
    connection.password = randomBytes(32).toString('base64url');
    return { connection, isNew: true };
  }

  const existing = readFileSync(environmentPath, 'utf8');
  const match = /^DATABASE_URL=(\S+)\r?$/m.exec(existing);
  if (!match) {
    throw new Error('Existing infrastructure/.env.api.local is invalid; fix it explicitly before retrying.');
  }
  let connection;
  try {
    connection = new URL(match[1]);
  } catch {
    throw new Error('Existing local database URL is invalid.');
  }
  if (
    connection.protocol !== 'postgresql:' ||
    connection.hostname !== '127.0.0.1' ||
    connection.port !== '54322' ||
    connection.pathname !== '/postgres' ||
    connection.username !== 'nene_api' ||
    connection.search ||
    connection.hash ||
    !/^[A-Za-z0-9_-]{43,}$/.test(connection.password)
  ) {
    throw new Error('Existing local database URL does not match the generated Nene local-only configuration.');
  }
  return { connection, isNew: false };
}

try {
  const { connection, isNew } = readOrCreateConnection();
  const containers = JSON.parse(docker(['inspect', '--type', 'container', containerName]));
  const container = containers[0];
  if (
    containers.length !== 1 ||
    container.Name !== `/${containerName}` ||
    !container.State?.Running ||
    !/(?:^|\/)supabase\/postgres(?::|@)/.test(container.Config?.Image ?? '')
  ) {
    throw new Error('The expected running Nene Supabase PostgreSQL container was not found.');
  }

  // The password is generated/validated as base64url, not user-supplied SQL.
  // Passing SQL through stdin keeps it out of process arguments and shell history.
  const sql = `
    do $nene$
    begin
      if not exists (
        select 1 from pg_roles
        where rolname = 'nene_api'
          and not rolsuper and not rolcreaterole and not rolcreatedb
          and not rolbypassrls
      ) then
        raise exception 'Apply Nene migrations before configuring the local API role.';
      end if;
    end $nene$;
    alter role nene_api login password '${connection.password}';
  `;
  docker(
    ['exec', '--interactive', containerName, 'psql', '-X', '--set', 'ON_ERROR_STOP=1', '--username', 'postgres', '--dbname', 'postgres', '--quiet'],
    { input: sql },
  );

  if (isNew) {
    writeFileSync(
      environmentPath,
      `# Generated local-only credential. Never commit or use in a hosted project.\nDATABASE_URL=${connection.href}\nDATABASE_SSL_MODE=disable\n`,
      { encoding: 'utf8', mode: 0o600, flag: 'wx' },
    );
  }
  console.log('Local API database login configured. Credentials remain in infrastructure/.env.api.local.');
} catch (error) {
  // JSON parsing or filesystem errors may include raw content; only known messages
  // are appropriate here, so do not log arbitrary Error objects or nested causes.
  const message = error instanceof Error && (
    error.message.startsWith('Local Docker operation failed.') ||
    error.message.startsWith('Existing ') ||
    error.message.startsWith('The expected running ')
  ) ? error.message : 'Could not configure the local API database login. Check Docker, migrations, and local file permissions.';
  console.error(message);
  process.exitCode = 1;
}
