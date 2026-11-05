import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { test } from 'node:test';
import {
  createSandboxCheckout,
  verifyVnpayNotification,
  VnpayValidationError,
  type VnpayCheckoutInput,
} from '../src/payments/vnpay.js';

const config = {
  terminalCode: 'DEMO1234',
  hashSecret: 'synthetic-test-secret-only-123456',
  returnUrl: 'https://callback.example.invalid/api/v1/payments/vnpay/return',
};
const input: VnpayCheckoutInput = {
  reference: 'DEMO123',
  amountVnd: '100000',
  orderInfo: 'Nene sandbox order: DEMO123',
  ipAddress: '127.0.0.1',
  createdAt: new Date('2026-11-06T23:55:00Z'),
  expiresAt: new Date('2026-11-07T00:10:00Z'),
};
const callback = {
  vnp_Amount: '10000000',
  vnp_BankCode: 'NCB',
  vnp_BankTranNo: 'VNP12345',
  vnp_CardType: 'ATM',
  vnp_OrderInfo: 'Nene sandbox order: DEMO123',
  vnp_PayDate: '20261107070000',
  vnp_ResponseCode: '00',
  vnp_TmnCode: 'DEMO1234',
  vnp_TransactionNo: '12345',
  vnp_TransactionStatus: '00',
  vnp_TxnRef: 'DEMO123',
};

// Test-side encoding uses URLSearchParams for these ordinary ASCII protocol
// fields. The production implementation never calls this fixture signer.
function signed(overrides: Record<string, string | undefined> = {}): string {
  const fields = new URLSearchParams();
  for (const [key, value] of Object.entries({ ...callback, ...overrides })) {
    if (value !== undefined) fields.set(key, value);
  }
  fields.sort();
  const hash = createHmac('sha512', config.hashSecret)
    .update(fields.toString())
    .digest('hex');
  fields.set('vnp_SecureHash', hash);
  return fields.toString();
}

const errorReason =
  (reason: VnpayValidationError['reason']) => (error: unknown) =>
    error instanceof VnpayValidationError && error.reason === reason;

void test('VNPay checkout is sandbox-only, exact whole VND, signed and GMT+7 across midnight', () => {
  const result = createSandboxCheckout(config, input);
  const url = new URL(result);
  assert.equal(url.origin, 'https://sandbox.vnpayment.vn');
  assert.equal(url.pathname, '/paymentv2/vpcpay.html');
  assert.equal(url.searchParams.get('vnp_Amount'), '10000000');
  assert.equal(url.searchParams.get('vnp_CreateDate'), '20261107065500');
  assert.equal(url.searchParams.get('vnp_ExpireDate'), '20261107071000');
  assert.equal(url.searchParams.get('vnp_ReturnUrl'), config.returnUrl);
  assert.equal(url.searchParams.get('vnp_TxnRef'), input.reference);
  assert.equal(url.searchParams.get('vnp_Version'), '2.1.0');
  assert.equal(url.searchParams.has('vnp_BankCode'), false);
  assert.equal(url.searchParams.has('vnp_SecureHashType'), false);
  assert.equal(result.includes(config.hashSecret), false);
  assert.ok(result.includes('vnp_OrderInfo=Nene+sandbox+order%3A+DEMO123'));
  // Independent .NET HMACSHA512 fixed vector over the documented sorted
  // query; this is not a signature recomputed with the production helper.
  assert.equal(
    url.searchParams.get('vnp_SecureHash'),
    'd0a8c08669c4ac09538d2176c1f4c858c39f241507e0924fe931580d8c59340cb949111d7f45e2daefe6cd1205ab6ea0b743efdafc5da201769f97951046108e',
  );
});

void test('checkout rejects malformed amount, reference, date, IP and return configuration', () => {
  for (const amountVnd of [
    '0',
    '-1',
    '01',
    '1.25',
    '1e4',
    '10000000000',
    ' 10000',
  ])
    assert.throws(() => createSandboxCheckout(config, { ...input, amountVnd }));
  for (const override of [
    { reference: 'order&extra=1' },
    { reference: 'a'.repeat(101) },
    { orderInfo: 'real@example.com' },
    { orderInfo: 'Thanh toán' },
    { orderInfo: '   ' },
    { ipAddress: '127.0.0.1, 1.2.3.4' },
    { ipAddress: 'not-an-ip' },
    { createdAt: new Date('invalid') },
    { expiresAt: input.createdAt },
    { expiresAt: new Date('2000-01-01') },
  ])
    assert.throws(() =>
      createSandboxCheckout(config, { ...input, ...override }),
    );
  for (const override of [
    { terminalCode: 'bad' },
    { hashSecret: '' },
    { returnUrl: 'http://callback.example.invalid/return' },
    { returnUrl: 'https://user:pass@callback.example.invalid/return' },
    { returnUrl: 'https://callback.example.invalid/return?token=secret' },
    { returnUrl: 'https://callback.example.invalid/return#token' },
    { returnUrl: 'https://callback.example.invalid/return\n' },
  ])
    assert.throws(() =>
      createSandboxCheckout({ ...config, ...override }, input),
    );
});

void test('valid signed notification preserves exact fields and accepts equivalent query encoding', () => {
  const result = verifyVnpayNotification(config, signed());
  assert.deepEqual(result, {
    reference: 'DEMO123',
    amountVnd: '100000',
    orderInfo: callback.vnp_OrderInfo,
    terminalCode: 'DEMO1234',
    transactionNo: '12345',
    responseCode: '00',
    transactionStatus: '00',
    successful: true,
    bankCode: 'NCB',
    payDate: '20261107070000',
  });
  assert.deepEqual(
    verifyVnpayNotification(
      config,
      signed().replace(/\+/g, '%20').split('&').reverse().join('&'),
    ),
    result,
  );
  assert.deepEqual(
    verifyVnpayNotification(
      config,
      `${signed()}&vnp_SecureHashType=HmacSHA512`,
    ),
    result,
  );
});

void test('notification requires both provider success codes, preserving non-success statuses', () => {
  for (const [responseCode, transactionStatus] of [
    ['00', '01'],
    ['00', '04'],
    ['24', '02'],
    ['07', '00'],
    ['51', '02'],
  ]) {
    const result = verifyVnpayNotification(
      config,
      signed({
        vnp_ResponseCode: responseCode,
        vnp_TransactionStatus: transactionStatus,
      }),
    );
    assert.equal(result.successful, false);
    assert.equal(result.responseCode, responseCode);
    assert.equal(result.transactionStatus, transactionStatus);
  }
  const cancelled = verifyVnpayNotification(
    config,
    signed({
      vnp_ResponseCode: '24',
      vnp_TransactionStatus: '02',
      vnp_TransactionNo: '0',
      vnp_BankTranNo: '',
      vnp_CardType: '',
      vnp_PayDate: '',
    }),
  );
  assert.equal(cancelled.successful, false);
  assert.equal(cancelled.payDate, undefined);
  assert.throws(
    () =>
      verifyVnpayNotification(
        config,
        signed().replace(/vnp_PayDate=[^&]*/, 'vnp_PayDate='),
      ),
    errorReason('signature'),
  );
});

void test('invalid signatures, altered amount and wrong terminal never authenticate', () => {
  assert.throws(
    () =>
      verifyVnpayNotification(
        config,
        signed().replace('vnp_Amount=10000000', 'vnp_Amount=20000000'),
      ),
    errorReason('signature'),
  );
  assert.throws(
    () =>
      verifyVnpayNotification(
        { ...config, hashSecret: 'another synthetic secret' },
        signed(),
      ),
    errorReason('signature'),
  );
  assert.throws(
    () => verifyVnpayNotification(config, signed({ vnp_TmnCode: 'OTHER123' })),
    errorReason('terminal'),
  );
  assert.throws(
    () =>
      verifyVnpayNotification(
        config,
        signed().replace(/vnp_SecureHash=.*/, 'vnp_SecureHash=abc'),
      ),
    errorReason('signature'),
  );
  assert.throws(
    () =>
      verifyVnpayNotification(config, `${signed()}&vnp_SecureHashType=SHA256`),
    errorReason('signature'),
  );
});

void test('duplicate/array parameters, unknown fields and malformed percent encodings fail closed', () => {
  for (const raw of [
    '',
    '?' + signed(),
    `${signed()}&vnp_Amount=10000000`,
    `${signed()}&%76np_Amount=10000000`,
    `${signed()}&vnp_SecureHash=abc`,
    `${signed()}&vnp_TxnRef%5B%5D=DEMO123`,
    `${signed()}&unexpected=value`,
    `${signed()}&`,
    `${signed()}&vnp_PayDate=%`,
    signed().replace('Nene+', '%C3%28+'),
    signed().replace('Nene+', '%ZZ+'),
    signed().replace('Nene+', '%00+'),
    signed().replace('Nene+', '%0A+'),
    'x'.repeat(8193),
  ])
    assert.throws(() => verifyVnpayNotification(config, raw));
  for (const raw of [{ vnp_TxnRef: ['one', 'two'] }, null, [], 1])
    assert.throws(() =>
      verifyVnpayNotification(config, raw as unknown as string),
    );
});

void test('even signed malformed monetary/status/date/transaction fields are refused', () => {
  for (const fields of [
    { vnp_Amount: '10000001' },
    { vnp_Amount: '010000000' },
    { vnp_Amount: '-100' },
    { vnp_Amount: '0' },
    { vnp_Amount: '1000000000000' },
    { vnp_TxnRef: 'DEMO-123' },
    { vnp_TxnRef: undefined },
    { vnp_TransactionNo: '0' },
    { vnp_TransactionNo: '123e4' },
    { vnp_TransactionStatus: undefined },
    { vnp_ResponseCode: '0' },
    { vnp_BankCode: undefined },
    { vnp_PayDate: '20260230010000' },
    { vnp_PayDate: '20261107250000' },
    { vnp_BankTranNo: 'value&unexpected=true' },
  ])
    assert.throws(() => verifyVnpayNotification(config, signed(fields)));
  assert.equal(
    verifyVnpayNotification(
      config,
      signed({
        vnp_TransactionNo: '0',
        vnp_ResponseCode: '24',
        vnp_TransactionStatus: '02',
        vnp_PayDate: undefined,
      }),
    ).successful,
    false,
  );
});
