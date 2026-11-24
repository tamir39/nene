import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import {
  interbankEnvironment,
  ownedInterbankContainer,
  interbankEnableSql,
  enableInterbankEnvironment,
} from "./lib/interbank-enable.mjs";

try {
  const [account, ...extra] = process.argv.slice(2);
  if (extra.length) throw new Error();
  const sql = interbankEnableSql(account);
  const envPath = new URL("../backend/.env", import.meta.url);
  const raw = readFileSync(envPath, "utf8");
  const databaseTarget = interbankEnvironment(raw);
  const docker = ["--host", "npipe:////./pipe/dockerDesktopLinuxEngine"];
  const info = JSON.parse(
    execFileSync("docker", [...docker, "inspect", "supabase_db_nene-local"], {
      encoding: "utf8",
      timeout: 10000,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    }),
  )[0];
  if (!ownedInterbankContainer(info, databaseTarget)) throw new Error();
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
  writeFileSync(envPath, enableInterbankEnvironment(raw), { mode: 0o600 });
  console.log(
    "Enabled the local fictional other-bank transfer demo. No balance or history changed and no money was seeded. Restart your run.bat to load the flag.",
  );
} catch {
  console.error(
    "Enablement failed. Usage: node scripts/enable-interbank-demo.mjs SOURCE_ACCOUNT_NUMBER. Start Nene with current migrations and use an existing funded synthetic VND checking account. Gates may be partially enabled if writing local configuration failed; rerun after fixing access. No credentials printed.",
  );
  process.exitCode = 1;
}
