import 'reflect-metadata';
import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';
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
const testEnvironment = {
  NODE_ENV: 'test',
  SUPABASE_URL: 'http://127.0.0.1:54321',
  SUPABASE_PUBLISHABLE_KEY: 'test',
  DATABASE_URL: 'postgresql://nene_api:test@127.0.0.1:54322/postgres',
  DATABASE_SSL_MODE: 'disable',
};
void describe('assistant HTTP session boundary (Auth/profile fakes)', () => {
  let app: INestApplication, server: Server;
  let role = 'customer';
  let profileReads = 0;
  before(async () => {
    const module = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(ENVIRONMENT)
      .useValue(readEnvironment(testEnvironment))
      .overrideProvider(SupabaseAuthService)
      .useValue({
        verifyAccessToken: () => ({ id: 'synthetic-customer', email: null }),
      })
      .overrideProvider(DatabaseService)
      .useValue({
        query: (sql: string) => {
          assert.match(sql, /^SELECT id, display_name, role/); // No banking read/write is allowed here.
          profileReads++;
          return [
            {
              id: 'synthetic-customer',
              display_name: 'Synthetic',
              role,
              status: 'active',
              phone: null,
              address: null,
            },
          ];
        },
      })
      .compile();
    app = module.createNestApplication();
    configureApp(app);
    await app.init();
    server = app.getHttpServer() as Server;
  });
  after(async () => app?.close());
  void it('requires a session, denies officers, returns no-store activity descriptors only', async () => {
    await request(server)
      .post('/api/v1/me/assistant/messages')
      .send({ message: 'history 2026-10' })
      .expect(401);
    assert.equal(profileReads, 0);
    role = 'officer';
    await request(server)
      .post('/api/v1/me/assistant/messages')
      .set('Authorization', 'Bearer synthetic')
      .send({ message: 'history 2026-10' })
      .expect(403);
    role = 'customer';
    const response = await request(server)
      .post('/api/v1/me/assistant/messages')
      .set('Authorization', 'Bearer synthetic')
      .send({ message: 'history 2026-10' })
      .expect(200)
      .expect('Cache-Control', 'no-store');
    assert.deepEqual((response.body as { actions: unknown[] }).actions, [
      { type: 'history', month: '2026-10' },
    ]);
    await request(server)
      .post('/api/v1/me/assistant/messages')
      .set('Authorization', 'Bearer synthetic')
      .send({ message: 'send money', role: 'officer' })
      .expect(400);
  });
});
void describe('assistant HTTP with the AI fallback enabled (Messages API mocked)', () => {
  let app: INestApplication, server: Server;
  before(async () => {
    const module = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(ENVIRONMENT)
      .useValue(
        readEnvironment({
          ...testEnvironment,
          ASSISTANT_AI_ENABLED: 'true',
          ANTHROPIC_API_KEY: 'test-only-placeholder-key-0123456789',
        }),
      )
      .overrideProvider(SupabaseAuthService)
      .useValue({
        verifyAccessToken: () => ({ id: 'synthetic-customer', email: null }),
      })
      .overrideProvider(DatabaseService)
      .useValue({
        query: (sql: string) => {
          assert.match(sql, /^SELECT id, display_name, role/);
          return [
            {
              id: 'synthetic-customer',
              display_name: 'Synthetic',
              role: 'customer',
              status: 'active',
              phone: null,
              address: null,
            },
          ];
        },
      })
      .compile();
    app = module.createNestApplication();
    configureApp(app);
    await app.init();
    server = app.getHttpServer() as Server;
  });
  after(async () => app?.close());
  void it('keeps the response contract and calls the model only for unrecognised messages', async (t) => {
    const fetchMock = t.mock.method(globalThis, 'fetch', async () =>
      Response.json({
        id: 'msg_synthetic',
        type: 'message',
        role: 'assistant',
        model: 'claude-haiku-5-5',
        content: [
          {
            type: 'text',
            text: JSON.stringify({
              reply:
                'I can open the demo phone top-up screen. It only opens the form; nothing has been created or sent.',
              actions: [{ type: 'phone' }],
            }),
          },
        ],
        stop_reason: 'end_turn',
        stop_sequence: null,
        usage: { input_tokens: 1, output_tokens: 1 },
      }),
    );
    const send = (message: string) =>
      request(server)
        .post('/api/v1/me/assistant/messages')
        .set('Authorization', 'Bearer synthetic')
        .send({ message })
        .expect(200)
        .expect('Cache-Control', 'no-store');
    const supported = await send('history 2026-10');
    assert.equal(fetchMock.mock.callCount(), 0);
    assert.deepEqual(supported.body, {
      reply: (supported.body as { reply: string }).reply,
      actions: [{ type: 'history', month: '2026-10' }],
      context: null,
    });
    const fallback = await send('My prepaid SIM has run out of credit');
    assert.equal(fetchMock.mock.callCount(), 1);
    assert.deepEqual(fallback.body, {
      reply:
        'I can open the demo phone top-up screen. It only opens the form; nothing has been created or sent.',
      actions: [{ type: 'phone' }],
      context: null,
    });
  });
});
