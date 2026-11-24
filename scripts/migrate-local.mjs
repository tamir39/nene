import { readFileSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Local-only fallback for this workstation's Supabase CLI PostgreSQL timeout.
// Applies forward migrations and their CLI history atomically; never resets data.
const container = 'supabase_db_nene-local';
const directory = new URL('../infrastructure/supabase/migrations/', import.meta.url);

function sql(input) {
  const result = spawnSync('docker', [
    'exec', '--interactive', container, 'psql', '-X', '--set', 'ON_ERROR_STOP=1',
    '--username', 'postgres', '--dbname', 'postgres', '--quiet', '--tuples-only', '--no-align',
  ], { input, encoding: 'utf8', timeout: 60_000, windowsHide: true });
  if (result.error || result.status !== 0) throw new Error('Migration failed.');
  return result.stdout;
}

try {
  const inspected = spawnSync('docker', ['inspect', '--type', 'container', container],
    { encoding: 'utf8', timeout: 15_000, windowsHide: true });
  if (inspected.error || inspected.status !== 0) throw new Error('No local database.');
  const records = JSON.parse(inspected.stdout);
  if (records.length !== 1 || records[0].Name !== `/${container}` || !records[0].State?.Running ||
      !/(?:^|\/)supabase\/postgres(?::|@)/.test(records[0].Config?.Image ?? '')) {
    throw new Error('Unexpected database.');
  }
  const applied = new Set(sql('select version from supabase_migrations.schema_migrations;').trim().split(/\r?\n/));
  const files = readdirSync(directory).filter(file => /^\d{14}_[a-z0-9_]+\.sql$/.test(file)).sort();
  let count = 0;
  for (const file of files) {
    const [, version, name] = /^(\d{14})_([a-z0-9_]+)\.sql$/.exec(file);
    if (applied.has(version)) continue;
    const source = readFileSync(new URL(file, directory), 'utf8');
    const delimiter = `$nene_${version}$`;
    if (source.includes(delimiter)) throw new Error('Invalid delimiter.');
    sql(`begin;
      select pg_advisory_xact_lock(hashtext('nene-local-forward-migrations'));
      do $guard$ begin
        if exists (select 1 from supabase_migrations.schema_migrations where version = '${version}') then
          raise exception 'Migration already applied; retry the runner.';
        end if;
      end $guard$;
      ${source}
      insert into supabase_migrations.schema_migrations (version,name,statements)
        values ('${version}','${name}',array[${delimiter}${source}${delimiter}]);
      commit;`);
    count++;
    console.log(`Applied local migration ${file}.`);
  }
  console.log(`Local forward migrations complete: ${count} applied. Existing data retained.`);
} catch {
  console.error(`Local migration failed; the current migration was not confirmed. Check the named Nene database and migration sources in ${fileURLToPath(directory)}. No SQL values or credentials logged.`);
  process.exitCode = 1;
}
