import assert from "node:assert/strict";
import test from "node:test";
import { generateTotp } from "./lib/totp-fixture.mjs";

// Public RFC 6238 Appendix B SHA-1 vectors, not credentials for any user.
// https://www.rfc-editor.org/info/rfc6238/
const secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
const vectors = [
  [59, "94287082"],
  [1111111109, "07081804"],
  [1111111111, "14050471"],
  [1234567890, "89005924"],
  [2000000000, "69279037"],
  [20000000000, "65353130"],
];

test("synthetic authenticator matches every RFC 6238 SHA-1 vector and six-digit projection", () => {
  for (const [timestampSeconds, expected] of vectors) {
    assert.equal(
      generateTotp(secret, { timestampSeconds, digits: 8 }),
      expected,
    );
    assert.equal(
      generateTotp(secret, { timestampSeconds }),
      expected.slice(-6),
    );
  }
});

test("time steps are stable within a window and support safe timestamps beyond 32 bits", () => {
  assert.equal(generateTotp(secret, { timestampSeconds: 30 }), "287082");
  assert.equal(generateTotp(secret, { timestampSeconds: 59 }), "287082");
  assert.equal(generateTotp(secret, { timestampSeconds: 60 }), "359152");
  assert.equal(
    generateTotp(secret, { timestampSeconds: 118, stepSeconds: 60 }),
    "287082",
  );
  assert.match(generateTotp(secret, { timestampSeconds: 0 }), /^\d{6}$/);
  assert.match(
    generateTotp(secret, { timestampSeconds: Number.MAX_SAFE_INTEGER }),
    /^\d{6}$/,
  );
});

test("canonical padded, unpadded and lowercase base32 forms decode consistently", () => {
  for (const padded of [
    "MY======",
    "MZXQ====",
    "MZXW6===",
    "MZXW6YQ=",
    "MZXW6YTB",
  ]) {
    const options = { timestampSeconds: 59 };
    const expected = generateTotp(padded, options);
    assert.equal(generateTotp(padded.replace(/=+$/, ""), options), expected);
    assert.equal(generateTotp(padded.toLowerCase(), options), expected);
  }
});

test("malformed base32 is rejected without echoing the input", () => {
  for (const invalid of [
    undefined,
    null,
    123,
    "",
    "A",
    "ABC",
    "ABCDEF",
    "MZ",
    "MZ======",
    "MY=",
    "MY=======",
    "M=Y=====",
    "MZXW6YTB=",
    "MY  ",
    "MY\n",
    "M0",
    "M1",
    "M8",
    "M9",
    "M!",
    "A".repeat(1025),
  ]) {
    assert.throws(() => generateTotp(invalid, { timestampSeconds: 59 }), {
      message: "Invalid synthetic base32 secret.",
    });
  }
});

test("invalid timestamp, time step and digit parameters fail safely", () => {
  for (const timestampSeconds of [
    -1,
    0.5,
    NaN,
    Infinity,
    Number.MAX_SAFE_INTEGER + 1,
    "59",
    59n,
  ]) {
    assert.throws(() => generateTotp(secret, { timestampSeconds }), {
      message: "Invalid synthetic TOTP parameters.",
    });
  }
  for (const stepSeconds of [
    0,
    -1,
    0.5,
    NaN,
    Infinity,
    Number.MAX_SAFE_INTEGER + 1,
    "30",
  ]) {
    assert.throws(
      () => generateTotp(secret, { timestampSeconds: 59, stepSeconds }),
      {
        message: "Invalid synthetic TOTP parameters.",
      },
    );
  }
  for (const digits of [0, 5, 7, 9, "6", NaN]) {
    assert.throws(
      () => generateTotp(secret, { timestampSeconds: 59, digits }),
      {
        message: "Invalid synthetic TOTP parameters.",
      },
    );
  }
});
