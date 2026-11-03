import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { parseEnv } from "node:util";
import { cashSeedSql } from "./lib/cash-seed.mjs";
// Explicit local fixture preparation; never a deposit endpoint or arbitrary balance editor.
try {
  const [account, ...extra] = process.argv.slice(2);
  if (extra.length || !/^\d{12}$/.test(account ?? "")) throw new Error();
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
  const sql = cashSeedSql(account);
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
    .filter((line) => !/^LOCAL_CASH_ENABLED=/.test(line));
  while (lines.at(-1) === "") lines.pop();
  writeFileSync(envPath, lines.join("\n") + "\nLOCAL_CASH_ENABLED=true\n", {
    mode: 0o600,
  });
  console.log(
    "Prepared a one-time 3,000,000 VND simulated cash balance outside the customer account. Repeating does not top it up. No bank balance or history changed. Restart run.bat to load the local-only flag.",
  );
} catch {
  console.error(
    "Demo preparation failed. Usage: node scripts/seed-cash-demo.mjs ACCOUNT_NUMBER. Start Nene with current migrations first; use an active synthetic VND checking or savings account. No credentials printed.",
  );
  process.exitCode = 1;
}
