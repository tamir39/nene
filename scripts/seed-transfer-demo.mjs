import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { parseEnv } from "node:util";
import { transferSeedSql } from "./lib/transfer-seed.mjs";
// Explicit local fixture preparation; never a deposit endpoint or arbitrary balance editor.
try {
  const [source, recipient, ...extra] = process.argv.slice(2);
  if (
    extra.length ||
    !/^\d{12}$/.test(source ?? "") ||
    !/^\d{12}$/.test(recipient ?? "") ||
    source === recipient
  )
    throw new Error();
  const envPath = new URL("../backend/.env", import.meta.url),
    raw = readFileSync(envPath, "utf8"),
    env = parseEnv(raw);
  const auth = new URL(env.SUPABASE_URL),
    db = new URL(env.DATABASE_URL);
  if (
    env.NODE_ENV === "production" ||
    !["localhost", "127.0.0.1", "[::1]"].includes(auth.hostname) ||
    !["localhost", "127.0.0.1", "[::1]"].includes(db.hostname)
  )
    throw new Error();
  const docker = ["--host", "npipe:////./pipe/dockerDesktopLinuxEngine"];
  const info = JSON.parse(
    execFileSync("docker", [...docker, "inspect", "supabase_db_nene-local"], {
      encoding: "utf8",
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    }),
  )[0];
  if (
    info.Name !== "/supabase_db_nene-local" ||
    !info.State?.Running ||
    info.Config?.Labels?.["com.supabase.cli.project"] !== "nene-local"
  )
    throw new Error();
  const sql = transferSeedSql(source, recipient);
  execFileSync(
    "docker",
    [
      ...docker,
      "exec",
      "-i",
      "supabase_db_nene-local",
      "psql",
      "-X",
      "-v",
      "ON_ERROR_STOP=1",
      "-U",
      "postgres",
      "-d",
      "postgres",
    ],
    {
      input: sql,
      encoding: "utf8",
      timeout: 15000,
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    },
  );
  const lines = raw
    .split(/\r?\n/)
    .filter((line) => !/^LOCAL_TRANSFERS_ENABLED=/.test(line));
  while (lines.at(-1) === "") lines.pop();
  writeFileSync(
    envPath,
    lines.join("\n") + "\nLOCAL_TRANSFERS_ENABLED=true\n",
    { mode: 0o600 },
  );
  console.log(
    "Prepared synthetic accounts with a one-time 3,000,000 VND opening fixture (repeat is a no-op). No deposit or real money. Restart run.bat to load the local-only flag.",
  );
} catch {
  console.error(
    "Demo preparation failed. Usage: node scripts/seed-transfer-demo.mjs SOURCE_ACCOUNT_NUMBER RECIPIENT_ACCOUNT_NUMBER. Start Nene with current migrations first; use active @example.invalid checking accounts and a never-funded source. No credentials printed.",
  );
  process.exitCode = 1;
}
