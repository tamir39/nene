import 'reflect-metadata';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { after, before, beforeEach, describe, it } from 'node:test';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import type { Server } from 'node:http';
import request from 'supertest';
import { AppModule } from '../src/app.module.js';
import { configureApp } from '../src/configure-app.js';
import { ENVIRONMENT } from '../src/config/config.module.js';
import { readEnvironment } from '../src/config/environment.js';
import { DatabaseService } from '../src/database/database.service.js';
import { SupabaseAuthService } from '../src/auth/supabase-auth.service.js';

const customerId = '10000000-0000-4000-8000-000000000001';
const paymentId = '20000000-0000-4000-8000-000000000002';
const token = `synthetic.${Buffer.from(
  JSON.stringify({
    sub: customerId,
    session_id: '30000000-0000-4000-8000-000000000003',
  }),
).toString('base64url')}.signature`;
const sandboxConfig = {
  terminalCode: 'DEMO1234',
  hashSecret: 'synthetic-http-test-secret-only',
  returnUrl: 'https://callback.example.invalid/api/v1/payments/vnpay/return',
};

function signedCallback(): string {
  const query = new URLSearchParams({
    vnp_Amount: '20000000',
    vnp_BankCode: 'NCB',
    vnp_OrderInfo: 'Nene sandbox electricity',
    vnp_ResponseCode: '00',
    vnp_TmnCode: sandboxConfig.terminalCode,
    vnp_TransactionNo: '12345',
    vnp_TransactionStatus: '00',
    vnp_TxnRef: 'DEMO123',
  });
  query.sort();
  query.set(
    'vnp_SecureHash',
    createHmac('sha512', sandboxConfig.hashSecret)
      .update(query.toString())
      .digest('hex'),
  );
  return query.toString();
}

void describe('payment HTTP session and callback boundary (Auth/database fakes)', () => {
  let app: INestApplication;
  let server: Server;
  let role = 'customer';
  let profileReads = 0;
  let authReads = 0;
  let transactionAttempts = 0;
  const environment = readEnvironment({
    NODE_ENV: 'test',
    SUPABASE_URL: 'http://127.0.0.1:54321',
    SUPABASE_PUBLISHABLE_KEY: 'test',
    DATABASE_URL: 'postgresql://nene_api:test@127.0.0.1:54322/postgres',
    DATABASE_SSL_MODE: 'disable',
  });

  before(async () => {
    const module = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(ENVIRONMENT)
      .useValue(environment)
      .overrideProvider(SupabaseAuthService)
      .useValue({
        verifyAccessToken: () => {
          authReads++;
          return { id: customerId, email: 'synthetic@example.invalid' };
        },
      })
      .overrideProvider(DatabaseService)
      .useValue({
        query: (sql: string) => {
          // Only SessionGuard's profile read is allowed by this HTTP fixture.
          assert.match(sql, /^SELECT id, display_name, role/);
          profileReads++;
          return [
            {
              id: customerId,
              display_name: 'Synthetic customer',
              role,
              status: 'active',
              phone: null,
              address: null,
            },
          ];
        },
        transaction: () => {
          transactionAttempts++;
          throw new Error('This fixture refuses banking reads and writes.');
        },
      })
      .compile();
    app = module.createNestApplication();
    configureApp(app);
    await app.init();
    server = app.getHttpServer() as Server;
  });
  beforeEach(() => {
    role = 'customer';
    profileReads = 0;
    authReads = 0;
    transactionAttempts = 0;
    environment.vnpaySandbox = undefined;
  });
  after(async () => app?.close());

  void it('requires customer sessions for configuration, history, status, review and confirmation', async () => {
    for (const path of ['configuration', '', paymentId])
      await request(server).get(`/api/v1/me/payments/${path}`).expect(401);
    for (const path of ['review', 'confirm'])
      await request(server)
        .post(`/api/v1/me/payments/${path}`)
        .send({ serviceId: 'electricity' })
        .expect(401);
    assert.equal(authReads, 0);
    assert.equal(profileReads, 0);
    assert.equal(transactionAttempts, 0);

    role = 'officer';
    for (const path of ['configuration', '', paymentId])
      await request(server)
        .get(`/api/v1/me/payments/${path}`)
        .set('Authorization', `Bearer ${token}`)
        .expect(403);
    for (const path of ['review', 'confirm'])
      await request(server)
        .post(`/api/v1/me/payments/${path}`)
        .set('Authorization', `Bearer ${token}`)
        .send({ serviceId: 'electricity' })
        .expect(403);
    assert.equal(profileReads, 5);
    assert.equal(transactionAttempts, 0);
  });

  void it('returns disabled no-store configuration without provider or banking calls', async () => {
    const response = await request(server)
      .get('/api/v1/me/payments/configuration')
      .set('Authorization', `Bearer ${token}`)
      .expect(200)
      .expect('Cache-Control', 'no-store');
    const body = response.body as {
      enabled: boolean;
      fulfillment: string;
      services: { id: string }[];
    };
    assert.equal(body.enabled, false);
    assert.equal(body.fulfillment, 'not_available');
    assert.deepEqual(
      body.services.map((service) => service.id),
      ['electricity', 'water', 'phone'],
    );
    assert.equal(profileReads, 1);
    assert.equal(transactionAttempts, 0);
  });

  void it('public return ignores attacker query values and never records payment', async () => {
    environment.vnpaySandbox = sandboxConfig;
    const baseline = await request(server)
      .get('/api/v1/payments/vnpay/return')
      .expect(200)
      .expect('Cache-Control', 'no-store')
      .expect('Content-Type', /text\/plain/)
      .expect('X-Content-Type-Options', 'nosniff')
      .expect('Referrer-Policy', 'no-referrer');
    const attacker = await request(server)
      .get(
        `/api/v1/payments/vnpay/return?${signedCallback()}&html=%3Cscript%3Ealert(1)%3C%2Fscript%3E`,
      )
      .expect(200);
    assert.equal(attacker.text, baseline.text);
    assert.match(attacker.text, /does not confirm payment/);
    assert.doesNotMatch(attacker.text, /<script>|DEMO123/);
    assert.equal(authReads, 0);
    assert.equal(profileReads, 0);
    assert.equal(transactionAttempts, 0);
  });

  void it('public forged IPN returns protocol rejection before any database access', async () => {
    environment.vnpaySandbox = sandboxConfig;
    const forged = signedCallback().replace(
      'vnp_Amount=20000000',
      'vnp_Amount=30000000',
    );
    const response = await request(server)
      .get(`/api/v1/payments/vnpay/ipn?${forged}`)
      .expect(200)
      .expect('Cache-Control', 'no-store');
    assert.equal((response.body as { RspCode: string }).RspCode, '97');
    assert.equal(authReads, 0);
    assert.equal(profileReads, 0);
    assert.equal(transactionAttempts, 0);
  });

  void it('forwards raw duplicate/array queries to strict verification without normalizing them away', async () => {
    environment.vnpaySandbox = sandboxConfig;
    // Positive control: this valid signature reaches the deliberately refused
    // transaction. Duplicate variants below must be rejected before that point.
    const control = await request(server)
      .get(`/api/v1/payments/vnpay/ipn?${signedCallback()}`)
      .expect(200);
    assert.equal((control.body as { RspCode: string }).RspCode, '99');
    assert.equal(transactionAttempts, 1);
    transactionAttempts = 0;
    for (const suffix of [
      '&vnp_Amount=20000000',
      '&%76np_Amount=20000000',
      '&vnp_Amount%5B%5D=20000000',
      '&vnp_TxnRef=DEMO123',
    ]) {
      const response = await request(server)
        .get(`/api/v1/payments/vnpay/ipn?${signedCallback()}${suffix}`)
        .expect(200);
      assert.equal((response.body as { RspCode: string }).RspCode, '97');
    }
    assert.equal(authReads, 0);
    assert.equal(profileReads, 0);
    assert.equal(transactionAttempts, 0);
  });

  void it('does not register POST IPN or return handlers', async () => {
    environment.vnpaySandbox = sandboxConfig;
    for (const route of ['ipn', 'return'])
      await request(server)
        .post(`/api/v1/payments/vnpay/${route}`)
        .send({ vnp_ResponseCode: '00', vnp_TransactionStatus: '00' })
        .expect(404);
    assert.equal(authReads, 0);
    assert.equal(profileReads, 0);
    assert.equal(transactionAttempts, 0);
  });
});
