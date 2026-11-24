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
void describe('assistant HTTP session boundary (Auth/profile fakes)', () => {
  let app: INestApplication, server: Server;
  let role = 'customer';
  let profileReads = 0;
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
