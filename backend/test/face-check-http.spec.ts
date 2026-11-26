import 'reflect-metadata';
import assert from 'node:assert/strict';
import { before, after, beforeEach, describe, it } from 'node:test';
import { Test } from '@nestjs/testing';
import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  type INestApplication,
} from '@nestjs/common';
import type { Server } from 'node:http';
import type { PoolClient } from 'pg';
import sharp from 'sharp';
import request from 'supertest';
import { AppModule } from '../src/app.module.js';
import { ENVIRONMENT } from '../src/config/config.module.js';
import { readEnvironment } from '../src/config/environment.js';
import { configureApp } from '../src/configure-app.js';
import { ConfirmationService } from '../src/confirmation/confirmation.service.js';
import { DatabaseService } from '../src/database/database.service.js';
import { SupabaseAuthService } from '../src/auth/supabase-auth.service.js';
import { IdentityStorageService } from '../src/identity/identity-storage.service.js';
import { FaceMatcher, type FaceComparison } from '../src/face/face-matcher.js';
import type { UserProfileRow } from '../src/profiles/profiles.repository.js';

// Guard, controller, validation and FaceCheckService are real. Persistence,
// review decoding, private Storage and the matcher are fakes: no face images.
const customer = 'fa000000-0000-4000-8000-000000000001';
const reviewId = 'fa000000-0000-4000-8000-000000000002';
const otherReview = 'fa000000-0000-4000-8000-000000000003';
const factor = 'fa000000-0000-4000-8000-000000000004';
const reference = {
  id: 'fa000000-0000-4000-8000-000000000005',
  version: 3,
  revision: 1,
  evidence_id: 'fa000000-0000-4000-8000-000000000006',
};
const auth = { Authorization: 'Bearer synthetic-session' };
const liveness = '{"blink":true,"turn":true}';
type Row = {
  id: string;
  customer_id: string;
  idempotency_key: string;
  review_id: string;
  review_digest: string;
  purpose: string;
  threshold: number;
  liveness: string;
  outcome: string;
  score: number | null;
  antispoof_score: number | null;
  expires_at: Date | null;
  created_at: number;
};

void describe('face-check HTTP boundary (matcher, storage and persistence faked)', () => {
  let app: INestApplication;
  let server: Server;
  let profile: UserProfileRow;
  let rows: Row[];
  let required: boolean;
  let referenceReady: boolean;
  let confirmationExists: boolean;
  let comparison: FaceComparison | Error;
  let compareCalls: number;
  let reviewDenial: Error | undefined;
  let png: Buffer;
  const key = () => crypto.randomUUID();

  const execute = (sql: string, values: unknown[]): unknown[] => {
    if (sql.includes('FROM bank.user_profiles WHERE id')) return [profile];
    if (sql.startsWith('select factor_id,revision,state'))
      return [{ factor_id: factor, revision: 2, state: 'ready' }];
    if (sql.startsWith('select id,customer_id,review_id,outcome,expires_at'))
      return rows.filter(
        (r) => r.customer_id === values[0] && r.idempotency_key === values[1],
      );
    if (sql.startsWith('select bank.transfer_face_check_required'))
      return [{ required }];
    if (sql.startsWith('select id from bank.transaction_confirmations'))
      return confirmationExists ? [{ id: values[0] }] : [];
    if (sql.startsWith('select e.object_key')) {
      assert.deepEqual(values, [
        customer,
        reference.id,
        reference.version,
        reference.revision,
        reference.evidence_id,
      ]);
      return referenceReady ? [{ object_key: 'synthetic/reference' }] : [];
    }
    if (sql.startsWith('select count(*)')) {
      const own = rows.filter((r) => r.customer_id === values[0]);
      return [
        {
          failed: own.filter(
            (r) =>
              r.review_id === values[1] &&
              ['not_matched', 'no_face', 'multiple_faces'].includes(r.outcome),
          ).length,
          recent: own.filter((r) => r.created_at > Date.now() - 900000).length,
        },
      ];
    }
    if (sql.startsWith('insert into bank.face_checks')) {
      const [id, customer_id, idempotency_key, review_id, review_digest] =
        values as string[];
      rows.push({
        id: id!,
        customer_id: customer_id!,
        idempotency_key: idempotency_key!,
        review_id: review_id!,
        review_digest: review_digest!,
        purpose: values[5] as string,
        threshold: values[6] as number,
        liveness: values[7] as string,
        outcome: 'pending',
        score: null,
        antispoof_score: null,
        expires_at: null,
        created_at: Date.now(),
      });
      return [];
    }
    if (sql.startsWith('update bank.face_checks')) {
      const row = rows.find(
        (r) => r.id === values[0] && r.outcome === 'pending',
      );
      if (!row) return [];
      row.outcome = values[1] as string;
      row.score = values[2] as number | null;
      row.antispoof_score = values[3] as number | null;
      row.expires_at =
        row.outcome === 'matched' ? new Date(Date.now() + 300000) : null;
      return [row];
    }
    throw new Error('Unhandled fixture SQL: ' + sql);
  };

  before(async () => {
    png = await sharp({
      create: { width: 32, height: 32, channels: 3, background: '#808080' },
    })
      .png()
      .toBuffer();
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
        verifyAccessToken: () => ({
          id: customer,
          email: 'synthetic@example.invalid',
        }),
      })
      .overrideProvider(DatabaseService)
      .useValue({
        query: async (sql: string, values: unknown[]) => execute(sql, values),
        transaction: async <T>(work: (client: PoolClient) => Promise<T>) => {
          const snapshot = rows.map((r) => ({ ...r }));
          try {
            return await work({
              query: async (sql: string, values: unknown[]) => ({
                rows: execute(sql, values),
              }),
            } as unknown as PoolClient);
          } catch (error) {
            rows = snapshot;
            throw error;
          }
        },
      })
      .overrideProvider(ConfirmationService)
      .useValue({
        faceReview: (_req: unknown, token: unknown) => {
          if (reviewDenial) throw reviewDenial;
          return {
            review: {
              id: token === 'other-review' ? otherReview : reviewId,
              customer,
              factor,
              revision: 2,
              amountMinor: '12000000',
              reference,
            },
            digest: 'synthetic-digest',
            purpose: 'local_transfer',
          };
        },
      })
      .overrideProvider(IdentityStorageService)
      .useValue({ read: async () => Buffer.from('synthetic-reference') })
      .overrideProvider(FaceMatcher)
      .useValue({
        compare: async (selfie: Buffer, ref: Buffer) => {
          compareCalls++;
          assert.ok(selfie.length > 0);
          assert.equal(ref.toString(), 'synthetic-reference');
          if (comparison instanceof Error) throw comparison;
          return comparison;
        },
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
      id: customer,
      display_name: 'Synthetic',
      role: 'customer',
      status: 'active',
      phone: null,
      address: null,
    };
    rows = [];
    required = true;
    referenceReady = true;
    confirmationExists = false;
    comparison = { outcome: 'matched', score: 0.61, antispoof: 0.9 };
    compareCalls = 0;
    reviewDenial = undefined;
  });
  after(async () => {
    await app.close();
  });

  const post = (idempotencyKey: string | null = key(), token = 'review') => {
    const call = request(server).post('/api/v1/me/face-checks').set(auth);
    if (idempotencyKey) call.set('Idempotency-Key', idempotencyKey);
    return call
      .field('reviewToken', token)
      .field('liveness', liveness)
      .attach('selfie', png, {
        filename: 'selfie.png',
        contentType: 'image/png',
      });
  };

  void it('requires authentication and a customer before reading the upload', async () => {
    await request(server).post('/api/v1/me/face-checks').expect(401);
    profile = { ...profile, role: 'officer' };
    await post().expect(403);
    assert.equal(compareCalls, 0);
    assert.equal(rows.length, 0);
  });

  void it('returns only the id, match flag and expiry on a match, and stores no image', async () => {
    const response = await post().expect(200);
    assert.equal(response.headers['cache-control'], 'no-store');
    assert.deepEqual(Object.keys(response.body as object).sort(), [
      'expiresAt',
      'faceCheckId',
      'matched',
    ]);
    const body = response.body as Record<string, unknown>;
    assert.equal(body.matched, true);
    assert.equal(body.faceCheckId, rows[0]!.id);
    assert.ok(Date.parse(body.expiresAt as string) > Date.now());
    assert.equal(rows[0]!.review_id, reviewId);
    assert.equal(rows[0]!.review_digest, 'synthetic-digest');
    assert.equal(rows[0]!.threshold, 0.4);
    assert.equal(rows[0]!.antispoof_score, 0.9);
    assert.deepEqual(JSON.parse(rows[0]!.liveness), {
      blink: true,
      turn: true,
    });
    assert.ok(!Object.values(rows[0]!).some((value) => Buffer.isBuffer(value)));
  });

  void it('returns 422 with a reason and message, never a score', async () => {
    for (const outcome of [
      'no_face',
      'multiple_faces',
      'not_matched',
    ] as const) {
      comparison = {
        outcome,
        score: outcome === 'not_matched' ? 0.2 : null,
        antispoof: 0.5,
      };
      const response = await post().expect(422);
      const body = response.body as Record<string, unknown>;
      assert.equal(body.matched, false);
      assert.equal(body.reason, outcome);
      assert.equal(typeof body.message, 'string');
      assert.equal(JSON.stringify(body).includes('0.2'), false);
      assert.equal(body.score, undefined);
    }
  });

  void it('allows at most five failed attempts per review and ten attempts per customer window', async () => {
    comparison = { outcome: 'not_matched', score: 0.1, antispoof: null };
    for (let i = 0; i < 5; i++) await post().expect(422);
    await post().expect(429);
    assert.equal(compareCalls, 5);
    comparison = { outcome: 'matched', score: 0.7, antispoof: null };
    for (let i = 0; i < 5; i++) await post(key(), 'other-review').expect(200);
    await post(key(), 'other-review').expect(429);
    assert.equal(compareCalls, 10);
  });

  void it('replays an idempotency key without comparing again and rejects reuse for another review', async () => {
    const id = key();
    const first = await post(id).expect(200);
    const second = await post(id).expect(200);
    assert.deepEqual(second.body, first.body);
    assert.equal(compareCalls, 1);
    await post(id, 'other-review').expect(409);
    comparison = { outcome: 'no_face', score: null, antispoof: null };
    const failed = key();
    await post(failed).expect(422);
    await post(failed).expect(422);
    assert.equal(compareCalls, 2);
  });

  void it('re-evaluates the rule now and refuses a check that is not required', async () => {
    required = false;
    await post().expect(409);
    assert.equal(rows.length, 0);
    required = true;
    await post().expect(200);
  });

  void it('refuses used reviews, missing references and invalid review tokens before matching', async () => {
    confirmationExists = true;
    await post().expect(409);
    confirmationExists = false;
    referenceReady = false;
    await post().expect(400);
    referenceReady = true;
    reviewDenial = new BadRequestException();
    await post().expect(400);
    reviewDenial = new ForbiddenException();
    await post().expect(403);
    reviewDenial = new ConflictException();
    await post().expect(409);
    assert.equal(compareCalls, 0);
    assert.equal(rows.length, 0);
  });

  void it('validates the multipart fields, file type, size and request key', async () => {
    await post(null).expect(400);
    await request(server)
      .post('/api/v1/me/face-checks')
      .set(auth)
      .set('Idempotency-Key', key())
      .field('reviewToken', 'review')
      .field('liveness', liveness)
      .expect(400);
    for (const bad of ['{"blink":true}', '{"blink":"yes","turn":true}', 'x'])
      await request(server)
        .post('/api/v1/me/face-checks')
        .set(auth)
        .set('Idempotency-Key', key())
        .field('reviewToken', 'review')
        .field('liveness', bad)
        .attach('selfie', png, {
          filename: 's.png',
          contentType: 'image/png',
        })
        .expect(400);
    await request(server)
      .post('/api/v1/me/face-checks')
      .set(auth)
      .set('Idempotency-Key', key())
      .field('reviewToken', 'review')
      .field('liveness', liveness)
      .field('score', '1')
      .attach('selfie', png, { filename: 's.png', contentType: 'image/png' })
      .expect(400);
    await request(server)
      .post('/api/v1/me/face-checks')
      .set(auth)
      .set('Idempotency-Key', key())
      .field('reviewToken', 'review')
      .field('liveness', liveness)
      .attach('selfie', Buffer.from('not an image'), {
        filename: 's.txt',
        contentType: 'text/plain',
      })
      .expect(400);
    // Declared JPEG but PNG bytes: the re-encoding check refuses it.
    await request(server)
      .post('/api/v1/me/face-checks')
      .set(auth)
      .set('Idempotency-Key', key())
      .field('reviewToken', 'review')
      .field('liveness', liveness)
      .attach('selfie', png, { filename: 's.jpg', contentType: 'image/jpeg' })
      .expect(400);
    await request(server)
      .post('/api/v1/me/face-checks')
      .set(auth)
      .set('Idempotency-Key', key())
      .field('reviewToken', 'review')
      .field('liveness', liveness)
      .attach('selfie', Buffer.alloc(10 * 1024 * 1024 + 1), {
        filename: 's.png',
        contentType: 'image/png',
      })
      .expect(413);
    assert.equal(compareCalls, 0);
    assert.equal(rows.length, 0);
  });

  void it('records matcher failures as errors and an unusable reference as 409', async () => {
    comparison = new Error('synthetic matcher failure');
    await post().expect(503);
    assert.equal(rows[0]!.outcome, 'error');
    comparison = {
      outcome: 'reference_unusable',
      score: null,
      antispoof: null,
    };
    const response = await post().expect(409);
    assert.equal(
      (response.body as Record<string, unknown>).code,
      'REFERENCE_UNUSABLE',
    );
    assert.equal(rows[1]!.outcome, 'error');
    assert.equal(rows[1]!.expires_at, null);
  });
});
