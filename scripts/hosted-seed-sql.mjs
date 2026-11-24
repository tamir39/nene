// Prints the existing synthetic demo seed SQL for pasting into the hosted
// Supabase SQL editor. It never connects to a database, reads configuration or
// handles credentials. See docs/HOSTED_DEMO.md.
import { transferSeedSql } from "./lib/transfer-seed.mjs";
import { cashSeedSql } from "./lib/cash-seed.mjs";
import { interbankEnableSql } from "./lib/interbank-enable.mjs";

try {
  const [source, recipient, ...extra] = process.argv.slice(2);
  if (extra.length) throw new Error("Expected exactly two account numbers.");
  // The helpers validate both 12-digit account numbers before anything prints.
  const blocks = [
    transferSeedSql(source, recipient),
    cashSeedSql(source),
    interbankEnableSql(source),
  ];
  process.stdout.write(
    [
      "-- Nene hosted demo seed. Synthetic @example.invalid customers only.",
      `-- ${source}: one-time 3,000,000 VND opening fixture, simulated cash source, other-bank demo.`,
      `-- ${recipient}: same-bank transfer recipient.`,
      "-- Each block is atomic; the seed refuses to reset or top up an account.",
      ...blocks,
      "",
    ].join("\n"),
  );
} catch (error) {
  console.error(
    `${error.message}\nUsage: node scripts/hosted-seed-sql.mjs SOURCE_ACCOUNT RECIPIENT_ACCOUNT`,
  );
  process.exitCode = 1;
}
