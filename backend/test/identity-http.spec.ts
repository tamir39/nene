import 'reflect-metadata';
import assert from 'node:assert/strict';
import { before, after, beforeEach, describe, it } from 'node:test';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import type { Server } from 'node:http';
import request from 'supertest';
import { AppModule } from '../src/app.module.js';
import { ENVIRONMENT } from '../src/config/config.module.js';
import { readEnvironment } from '../src/config/environment.js';
import { configureApp } from '../src/configure-app.js';
import { DatabaseService } from '../src/database/database.service.js';
import { SupabaseAuthService } from '../src/auth/supabase-auth.service.js';
import { IdentityService } from '../src/identity/identity.service.js';
import { notice } from '../src/identity/identity.validation.js';
import type { UserProfileRow } from '../src/profiles/profiles.repository.js';

const id = 'b4000000-0000-4000-8000-000000000001';
const other = 'b4000000-0000-4000-8000-000000000002';
const auth = { Authorization: 'Bearer synthetic-session' };

void describe('reference HTTP boundaries (guard real; identity persistence faked)', () => {
  let app: INestApplication;
  let server: Server;
  let profile: UserProfileRow;
  let calls: string[];
  before(async () => {
    const module = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(ENVIRONMENT)
      .useValue(
        readEnvironment({
          NODE_ENV: 'test',
          SUPABASE_URL: 'http://127.0.0.1:45321',
          SUPABASE_PUBLISHABLE_KEY: 'test',
          DATABASE_URL: 'postgresql://nene_api:test@127.0.0.1:45322/postgres',
          DATABASE_SSL_MODE: 'disable',
        }),
      )
      .overrideProvider(SupabaseAuthService)
      .useValue({
        verifyAccessToken: () => ({ id, email: 'synthetic@example.invalid' }),
      })
      .overrideProvider(DatabaseService)
      .useValue({ query: () => [profile] })
      .overrideProvider(IdentityService)
      .useValue({
        customer: IdentityService.prototype.customer,
        officer: IdentityService.prototype.officer,
        status: () => {
          calls.push('status');
          return { status: 'not_started', notice };
        },
        start: () => {
          calls.push('start');
          return { status: 'draft', notice };
        },
        caseStatus: () => {
          calls.push('caseStatus');
          return { status: 'draft' };
        },
        upload: () => {
          calls.push('upload');
          return { status: 'draft' };
        },
        submit: () => {
          calls.push('submit');
          return { status: 'submitted' };
        },
        review: () => {
          calls.push('review');
          return { status: 'reference_accepted' };
        },
        readEvidence: () => ({
          bytes: Buffer.from([1, 2, 3]),
          contentType: 'image/png',
        }),
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
      display_name: 'Synthetic',
      role: 'customer',
      status: 'active',
      phone: null,
      address: null,
    };
    calls = [];
  });
  after(async () => {
    await app.close();
  });
  void it('requires authentication and blocks customer officer commands before calling service', async () => {
    await request(server).get('/api/v1/me/identity').expect(401);
    await request(server)
      .get(`/api/v1/officer/customers/${other}/identity`)
      .set(auth)
      .expect(403);
    await request(server)
      .post(`/api/v1/officer/customers/${other}/identity/cases`)
      .set(auth)
      .send({})
      .expect(403);
    await request(server)
      .post(`/api/v1/officer/identity/cases/${other}/reviews`)
      .set(auth)
      .send({})
      .expect(403);
    assert.deepEqual(calls, []);
  });
  void it('returns no-store status and a no-store binary preview', async () => {
    const status = await request(server)
      .get('/api/v1/me/identity')
      .set(auth)
      .expect(200);
    assert.equal(status.headers['cache-control'], 'no-store');
    const photo = await request(server)
      .get(`/api/v1/identity/cases/${id}/evidence/${other}`)
      .set(auth)
      .expect(200);
    assert.equal(photo.headers['cache-control'], 'no-store');
    assert.equal(photo.headers['x-content-type-options'], 'nosniff');
    assert.equal(photo.headers['content-type'], 'image/png');
  });
  void it('requires exact fields and idempotency key; refuses fabricated verification fields', async () => {
    await request(server)
      .post('/api/v1/me/identity/cases')
      .set(auth)
      .send({ noticeVersion: notice.version, acknowledged: true })
      .expect(400);
    await request(server)
      .post('/api/v1/me/identity/cases')
      .set(auth)
      .set('Idempotency-Key', other)
      .send({
        noticeVersion: notice.version,
        acknowledged: true,
        isVerified: true,
      })
      .expect(400);
    await request(server)
      .post(`/api/v1/identity/cases/${id}/submit`)
      .set(auth)
      .set('Idempotency-Key', other)
      .send({ expectedVersion: 1, evidenceId: other })
      .expect(400);
    assert.deepEqual(calls, []);
    await request(server)
      .post('/api/v1/me/identity/cases')
      .set(auth)
      .set('Idempotency-Key', other)
      .send({ noticeVersion: notice.version, acknowledged: true })
      .expect(201);
    assert.deepEqual(calls, ['start']);
  });
  void it('accepts a bounded photo envelope above default JSON limit only on the upload route', async () => {
    const photo = {
      expectedVersion: 1,
      contentType: 'image/png',
      dataBase64: Buffer.alloc(200000, 255).toString('base64'),
    };
    await request(server)
      .post(`/api/v1/identity/cases/${id}/evidence`)
      .set(auth)
      .set('Idempotency-Key', other)
      .send(photo)
      .expect(201);
    await request(server)
      .post(`/api/v1/identity/cases/${id}/submit`)
      .set(auth)
      .set('Idempotency-Key', other)
      .send(photo)
      .expect(413);
    assert.deepEqual(calls, ['upload']);
  });
  void it('accepts only explicitly confirmed officer association, never customer review', async () => {
    profile.role = 'officer';
    await request(server)
      .post(`/api/v1/officer/identity/cases/${id}/reviews`)
      .set(auth)
      .set('Idempotency-Key', other)
      .send({
        expectedVersion: 1,
        action: 'accept_reference',
        associationConfirmed: false,
        reason: null,
      })
      .expect(400);
    await request(server)
      .post(`/api/v1/officer/identity/cases/${id}/reviews`)
      .set(auth)
      .set('Idempotency-Key', other)
      .send({
        expectedVersion: 1,
        action: 'accept_reference',
        associationConfirmed: true,
        reason: null,
      })
      .expect(201);
    assert.deepEqual(calls, ['review']);
  });
});
