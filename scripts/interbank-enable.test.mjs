import assert from "node:assert/strict";
import { test } from "node:test";
import {
  interbankEnvironment,
  ownedInterbankContainer,
  interbankEnableSql,
  enableInterbankEnvironment,
} from "./lib/interbank-enable.mjs";

const raw =
  "NODE_ENV=development\nSUPABASE_URL=http://127.0.0.1:45321\nDATABASE_URL=postgresql://nene_api:synthetic@127.0.0.1:45322/postgres\n";
test("activation rejects production, remote services and an unrelated database", () => {
  assert.equal(interbankEnvironment(raw).databasePort, "45322");
  for (const invalid of [
    raw.replace("development", "production"),
    raw.replace("development", "unexpected"),
    raw.replace("http://127.0.0.1:45321", "https://remote.example"),
    raw.replace("127.0.0.1:45322", "remote.example:5432"),
    raw.replace("127.0.0.1:45322", "localhost:45322"),
    raw.replace("nene_api:", "postgres:"),
    raw.replace("/postgres\n", "/another_database\n"),
    raw.replace("/postgres\n", "/postgres?host=remote.example\n"),
  ])
    assert.throws(() => interbankEnvironment(invalid));
});
test("activation requires the owned running container and matching loopback port", () => {
  const target = interbankEnvironment(raw);
  const info = {
    Name: "/supabase_db_nene-local",
    State: { Running: true },
    Config: { Labels: { "com.supabase.cli.project": "nene-local" } },
    NetworkSettings: {
      Ports: { "5432/tcp": [{ HostIp: "127.0.0.1", HostPort: "45322" }] },
    },
  };
  assert.equal(ownedInterbankContainer(info, target), true);
  assert.equal(
    ownedInterbankContainer(info, { ...target, databasePort: "54322" }),
    false,
  );
  const ipv6 = interbankEnvironment(
    raw.replace("127.0.0.1:45322", "[::1]:45322"),
  );
  assert.equal(ownedInterbankContainer(info, ipv6), false);
  assert.equal(
    ownedInterbankContainer(
      {
        ...info,
        NetworkSettings: {
          Ports: { "5432/tcp": [{ HostIp: "::1", HostPort: "45322" }] },
        },
      },
      ipv6,
    ),
    true,
  );
  assert.equal(
    ownedInterbankContainer({ ...info, Name: "/another-project" }, target),
    false,
  );
  assert.equal(
    ownedInterbankContainer({ ...info, State: { Running: false } }, target),
    false,
  );
  assert.equal(
    ownedInterbankContainer({ ...info, Config: { Labels: {} } }, target),
    false,
  );
  assert.equal(
    ownedInterbankContainer(
      {
        ...info,
        NetworkSettings: {
          Ports: { "5432/tcp": [{ HostIp: "0.0.0.0", HostPort: "45322" }] },
        },
      },
      target,
    ),
    false,
  );
});
test("activation rejects injected account text and only updates the feature gate", () => {
  for (const value of [
    undefined,
    "",
    "1",
    "990000000001;drop table bank.banking_accounts",
    " 990000000001",
  ])
    assert.throws(() => interbankEnableSql(value));
  const sql = interbankEnableSql("100000000001");
  assert.match(sql, /a.is_demo/);
  assert.match(sql, /a.balance_minor>0/);
  assert.deepEqual(
    [...sql.matchAll(/\bupdate\s+([\w.]+)/gi)].map((m) => m[1]),
    ["bank.local_interbank_settings"],
  );
  assert.doesNotMatch(sql, /\binsert\b|\bdelete\b/i);
});
test("enabling the flag preserves other settings and repeated application does not duplicate it", () => {
  const old =
    raw +
    "\nLOCAL_CASH_ENABLED=true\n export LOCAL_INTERBANK_ENABLED = false\n";
  const result = enableInterbankEnvironment(old);
  assert.ok(result.includes("LOCAL_CASH_ENABLED=true"));
  assert.equal(result.match(/LOCAL_INTERBANK_ENABLED/g).length, 1);
  assert.equal(enableInterbankEnvironment(result), result);
});
