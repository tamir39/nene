import 'reflect-metadata';
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import type { Server } from 'node:http';
import type { PoolClient } from 'pg';
import request from 'supertest';
import { AppModule } from '../src/app.module.js';
import { configureApp } from '../src/configure-app.js';
import { ENVIRONMENT } from '../src/config/config.module.js';
import { readEnvironment } from '../src/config/environment.js';
import { DatabaseService } from '../src/database/database.service.js';
import { SupabaseAuthService } from '../src/auth/supabase-auth.service.js';
import type { UserProfileRow } from '../src/profiles/profiles.repository.js';

const id = 'b3000000-0000-4000-8000-000000000001';
const targetId = 'b3000000-0000-4000-8000-000000000002';
const validCreate = {
  email: 'new@example.invalid',
  displayName: 'New Customer',
  phone: null,
  address: null,
  initialPassword: 'Synthetic-initial-password',
};

void describe('customer HTTP permission/input boundaries (database/Auth fakes)', () => {
  let app: INestApplication;
  let server: Server;
  let profile: UserProfileRow;
  let mutations: { sql: string; values: unknown[] }[];

  before(async () => {
    const module = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(ENVIRONMENT)
      .useValue(
        readEnvironment({
          NODE_ENV: 'test',
          SUPABASE_URL: 'http://127.0.0.1:54321',
          SUPABASE_PUBLISHABLE_KEY: 'test',
          DATABASE_URL: 'postgresql://nene_api:test@127.0.0.1:54322/postgres',
          DATABASE_SSL_MODE: 'disable',
        }),
      )
      .overrideProvider(SupabaseAuthService)
      .useValue({
        verifyAccessToken: () => ({ id, email: 'self@example.invalid' }),
      })
      .overrideProvider(DatabaseService)
      .useValue({
        query: (sql: string, values: unknown[]) => {
          if (sql.startsWith('SELECT id, display_name, role')) return [profile];
          if (sql.includes('FROM bank.banking_accounts')) {
            assert.deepEqual(values, [id]);
            return [
              {
                id: targetId,
                accountNumber: '100000000001',
                type: 'checking',
                currency: 'VND',
                balanceMinor: '0',
                status: 'active',
              },
            ];
          }
          if (sql.includes('FROM bank.user_profiles')) {
            assert.ok(sql.includes("role = 'customer'"));
            assert.ok(sql.includes('LIMIT 20'));
            return [
              {
                id: targetId,
                email: 'other@example.invalid',
                displayName: 'Other Customer',
                phone: null,
                address: null,
              },
            ];
          }
          throw new Error('Unexpected query');
        },
        transaction: async <T>(work: (client: PoolClient) => Promise<T>) =>
          work({
            query: async (sql: string, values: unknown[]) => {
              mutations.push({ sql, values });
              if (sql.startsWith('UPDATE bank.user_profiles')) {
                assert.ok(sql.includes("role = 'customer'"));
                if (values[0] === targetId) return { rows: [] };
                return {
                  rows: [
                    {
                      displayName: profile.display_name,
                      phone: values[1],
                      address: values[2],
                    },
                  ],
                };
              }
              if (sql.includes('INSERT INTO bank.profile_edit_audit'))
                return { rows: [] };
              if (sql.includes('FROM bank.user_profiles')) return { rows: [] };
              throw new Error('Unexpected mutation');
            },
          } as unknown as PoolClient),
      })
      .compile();
    app = module.createNestApplication();
    app.useLogger(false);
    configureApp(app);
    await app.init();
    server = app.getHttpServer() as Server;
  });
  beforeEach(() => {
    profile = {
      id,
      display_name: 'Self Customer',
      role: 'customer',
      status: 'active',
      phone: null,
      address: null,
    };
    mutations = [];
  });
  after(async () => {
    await app.close();
  });
  const auth = { Authorization: 'Bearer verified-test-session' };

  void it('blocks customer access to every officer operation', async () => {
    await request(server)
      .post('/api/v1/officer/customers')
      .set(auth)
      .send(validCreate)
      .expect(403);
    await request(server)
      .get('/api/v1/officer/customers?query=test')
      .set(auth)
      .expect(403);
    await request(server)
      .get(`/api/v1/officer/customers/${targetId}`)
      .set(auth)
      .expect(403);
    await request(server)
      .patch(`/api/v1/officer/customers/${targetId}`)
      .set(auth)
      .send({})
      .expect(403);
    assert.equal(mutations.length, 0);
  });

  void it('returns own accounts with string money and disables caching', async () => {
    const result = await request(server)
      .get('/api/v1/me/accounts')
      .set(auth)
      .expect(200);
    assert.equal(result.body.accounts[0].balanceMinor, '0');
    assert.equal(result.headers['cache-control'], 'no-store');
    profile.role = 'officer';
    await request(server).get('/api/v1/me/accounts').set(auth).expect(403);
  });

  void it('updates only the verified customer contact and writes the audit atomically', async () => {
    const result = await request(server)
      .patch('/api/v1/me/contact')
      .set(auth)
      .send({ phone: '+84 900 123 456', address: 'Demo address' })
      .expect(200);
    assert.equal(result.body.id, id);
    assert.equal(result.body.email, 'self@example.invalid');
    assert.equal(result.body.phone, '+84 900 123 456');
    assert.equal(result.headers['cache-control'], 'no-store');
    assert.equal(mutations.length, 2);
    assert.equal(mutations[0]?.values[0], id);
    assert.equal(mutations[1]?.values[0], id);
  });

  void it('rejects customer attempts to set IDs, roles, names, email or balance', async () => {
    for (const key of [
      'id',
      'customerId',
      'role',
      'displayName',
      'email',
      'balanceMinor',
    ]) {
      await request(server)
        .patch('/api/v1/me/contact')
        .set(auth)
        .send({ phone: null, address: null, [key]: 'unauthorized' })
        .expect(400);
    }
    assert.equal(mutations.length, 0);
  });

  void it('permits clearing contact and rejects malformed or overlong fields', async () => {
    await request(server)
      .patch('/api/v1/me/contact')
      .set(auth)
      .send({ phone: null, address: null })
      .expect(200);
    for (const body of [
      { phone: 'abc', address: null },
      { phone: null, address: 'x'.repeat(301) },
      { phone: null },
      { phone: null, address: '\nDemo' },
      [],
    ]) {
      await request(server)
        .patch('/api/v1/me/contact')
        .set(auth)
        .send(body)
        .expect(400);
    }
  });

  void it('requires exact creation fields, a request UUID and valid initial password', async () => {
    profile.role = 'officer';
    await request(server)
      .post('/api/v1/officer/customers')
      .set(auth)
      .send(validCreate)
      .expect(400);
    for (const body of [
      { ...validCreate, role: 'officer' },
      { ...validCreate, currency: 'USD' },
      { ...validCreate, initialPassword: 'short' },
      { ...validCreate, initialPassword: 'x'.repeat(129) },
      { ...validCreate, email: 'bad-email' },
      { ...validCreate, displayName: '' },
    ]) {
      await request(server)
        .post('/api/v1/officer/customers')
        .set(auth)
        .set('Idempotency-Key', targetId)
        .send(body)
        .expect(400);
    }
    await request(server)
      .post('/api/v1/officer/customers')
      .set(auth)
      .set('Idempotency-Key', targetId)
      .send(validCreate)
      .expect(503);
  });

  void it('requires an officer edit reason and rejects changes to sign-in email', async () => {
    profile.role = 'officer';
    const body = {
      displayName: 'Changed',
      phone: null,
      address: null,
      requestReason: 'Customer requested correction',
    };
    await request(server)
      .patch(`/api/v1/officer/customers/${targetId}`)
      .set(auth)
      .send({ ...body, requestReason: '' })
      .expect(400);
    await request(server)
      .patch(`/api/v1/officer/customers/${targetId}`)
      .set(auth)
      .send({ ...body, email: 'other@example.invalid' })
      .expect(400);
    await request(server)
      .patch(`/api/v1/officer/customers/${targetId}`)
      .set(auth)
      .send(body)
      .expect(404);
    await request(server)
      .get(`/api/v1/officer/customers/${targetId}`)
      .set(auth)
      .expect(404);
  });

  void it('does not enumerate customers for blank search and validates query/id', async () => {
    profile.role = 'officer';
    const empty = await request(server)
      .get('/api/v1/officer/customers')
      .set(auth)
      .expect(200);
    assert.deepEqual(empty.body, { customers: [] });
    await request(server)
      .get('/api/v1/officer/customers?query=demo')
      .set(auth)
      .expect(200);
    await request(server)
      .get(`/api/v1/officer/customers?query=${'x'.repeat(101)}`)
      .set(auth)
      .expect(400);
    await request(server)
      .get('/api/v1/officer/customers/not-a-uuid')
      .set(auth)
      .expect(400);
  });
});
