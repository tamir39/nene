import { parseEnv } from "node:util";

const loopback = (hostname) =>
  ["localhost", "127.0.0.1", "[::1]"].includes(hostname);

// This command only enables an existing local fixture. It never seeds money.
export function interbankEnvironment(raw) {
  const env = parseEnv(raw);
  const auth = new URL(env.SUPABASE_URL);
  const database = new URL(env.DATABASE_URL);
  if (
    !["development", "test"].includes(env.NODE_ENV ?? "development") ||
    !loopback(auth.hostname) ||
    !["127.0.0.1", "[::1]"].includes(database.hostname) ||
    !["http:", "https:"].includes(auth.protocol) ||
    !["postgres:", "postgresql:"].includes(database.protocol) ||
    database.username !== "nene_api" ||
    database.search ||
    database.pathname !== "/postgres"
  )
    throw new Error("Only the owned local Nene configuration is supported.");
  return {
    databasePort: database.port || "5432",
    databaseHost: database.hostname === "[::1]" ? "::1" : database.hostname,
  };
}

export function ownedInterbankContainer(info, { databasePort, databaseHost }) {
  const bindings = info?.NetworkSettings?.Ports?.["5432/tcp"];
  return (
    info?.Name === "/supabase_db_nene-local" &&
    info.State?.Running === true &&
    info.Config?.Labels?.["com.supabase.cli.project"] === "nene-local" &&
    Array.isArray(bindings) &&
    bindings.every((binding) =>
      ["127.0.0.1", "::1"].includes(binding.HostIp),
    ) &&
    bindings.some(
      (binding) =>
        binding.HostIp === databaseHost && binding.HostPort === databasePort,
    ) === true
  );
}

export function interbankEnableSql(account) {
  if (typeof account !== "string" || !/^\d{12}$/.test(account))
    throw new Error("Use a 12-digit demo checking account.");
  // Exact digits are validated before interpolation. No caller SQL is accepted.
  return `begin;
set local lock_timeout='3s';
set local statement_timeout='10s';
do $$ begin
  perform 1 from bank.banking_accounts a join bank.user_profiles p on p.id=a.owner_id
    where a.account_number=${account} and a.is_demo and a.type='checking'
      and a.currency='VND' and a.status='active' and a.balance_minor>0
      and p.status='active' and p.role='customer' and p.email like '%@example.invalid'
    for share of a,p;
  if not found then raise exception 'Use an existing funded synthetic VND checking account'; end if;
  update bank.local_interbank_settings set enabled=true where id;
  if not found then raise exception 'Apply the interbank migration first'; end if;
end $$;
commit;`;
}

export function enableInterbankEnvironment(raw) {
  const lines = raw
    .split(/\r?\n/)
    .filter(
      (line) => !/^\s*(?:export\s+)?LOCAL_INTERBANK_ENABLED\s*=/.test(line),
    );
  while (lines.at(-1) === "") lines.pop();
  return `${lines.join("\n")}\nLOCAL_INTERBANK_ENABLED=true\n`;
}
