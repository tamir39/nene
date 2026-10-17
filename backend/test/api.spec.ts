import 'reflect-metadata';
import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, it } from 'node:test';
import {
  Controller,
  Get,
  ServiceUnavailableException,
  UnauthorizedException,
  type INestApplication,
} from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import type { Server } from 'node:http';
import { AppModule } from '../src/app.module.js';
import { configureApp } from '../src/configure-app.js';
import { ENVIRONMENT } from '../src/config/config.module.js';
import { readEnvironment } from '../src/config/environment.js';
import { DatabaseService } from '../src/database/database.service.js';
import { SupabaseAuthService } from '../src/auth/supabase-auth.service.js';
import type { UserProfileRow } from '../src/profiles/profiles.repository.js';

@Controller('private-probe')
class PrivateProbeController {
  @Get()
  probe() {
    return { reached: true };
  }
}

void describe('HTTP authentication foundation (dependency fakes; no Supabase connection)', () => {
  let app: INestApplication;
  let server: Server;
  const id = '5cc38e39-0f25-4a87-9fa8-48feae23f563';
  let profile: UserProfileRow | undefined;
  let verifiedTokens: string[];
  let queries: { text: string; values: unknown[] }[];
  let authUnavailable: boolean;
  let databaseUnavailable: boolean;

  before(async () => {
    const module = await Test.createTestingModule({
      imports: [AppModule],
      controllers: [PrivateProbeController],
    })
      .overrideProvider(ENVIRONMENT)
      .useValue(
        readEnvironment({
          NODE_ENV: 'test',
          SUPABASE_URL: 'http://127.0.0.1:54321',
          SUPABASE_PUBLISHABLE_KEY: 'test-public-key',
          DATABASE_URL: 'postgresql://nene_api:test@127.0.0.1:54322/postgres',
          DATABASE_SSL_MODE: 'disable',
        }),
      )
      .overrideProvider(SupabaseAuthService)
      .useValue({
        verifyAccessToken: (token: string) => {
          verifiedTokens.push(token);
          if (authUnavailable) throw new ServiceUnavailableException();
          if (token !== 'valid-session') throw new UnauthorizedException();
          // A user-controlled role claim must not determine application permissions.
          return {
            id,
            email: 'synthetic@example.test',
            user_metadata: { role: 'officer' },
          };
        },
      })
      .overrideProvider(DatabaseService)
      .useValue({
        query: (text: string, values: unknown[]) => {
          queries.push({ text, values });
          if (databaseUnavailable) throw new ServiceUnavailableException();
          return profile ? [profile] : [];
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
      id,
      display_name: 'Synthetic Customer',
      role: 'customer',
      status: 'active',
    };
    verifiedTokens = [];
    queries = [];
    authUnavailable = false;
    databaseUnavailable = false;
  });

  after(async () => {
    await app.close();
  });

  void it('reports liveness without claiming dependency availability', async () => {
    authUnavailable = true;
    databaseUnavailable = true;
    const result = await request(server).get('/api/v1/health').expect(200);
    assert.deepEqual(result.body, {
      status: 'ok',
      service: 'nene-api',
      check: 'liveness',
    });
    assert.equal(queries.length, 0);
    assert.equal(verifiedTokens.length, 0);
  });

  void it('protects routes by default and rejects missing authorization', async () => {
    await request(server).get('/api/v1/me').expect(401);
    await request(server).get('/api/v1/private-probe').expect(401);
    assert.equal(queries.length, 0);
  });

  void it('rejects malformed or ambiguous bearer headers before calling dependencies', async () => {
    for (const authorization of [
      'Basic valid-session',
      'Bearer',
      'Bearer one two',
      'Bearer one,Bearer two',
    ]) {
      await request(server)
        .get('/api/v1/me')
        .set('Authorization', authorization)
        .expect(401);
    }
    assert.equal(verifiedTokens.length, 0);
    assert.equal(queries.length, 0);
  });

  void it('rejects an invalid token before loading a profile', async () => {
    await request(server)
      .get('/api/v1/me')
      .auth('invalid-session', { type: 'bearer' })
      .expect(401);
    assert.deepEqual(verifiedTokens, ['invalid-session']);
    assert.equal(queries.length, 0);
  });

  void it('rejects a missing application profile', async () => {
    profile = undefined;
    await request(server)
      .get('/api/v1/me')
      .auth('valid-session', { type: 'bearer' })
      .expect(403);
  });

  void it('rejects a disabled application profile', async () => {
    profile!.status = 'disabled';
    await request(server)
      .get('/api/v1/me')
      .auth('valid-session', { type: 'bearer' })
      .expect(403);
  });

  void it('returns server-controlled customer role despite a forged metadata officer claim', async () => {
    const result = await request(server)
      .get('/api/v1/me')
      .auth('valid-session', { type: 'bearer' })
      .expect(200);
    assert.equal(result.headers['cache-control'], 'no-store');
    assert.equal(result.body.role, 'customer');
    assert.equal(result.body.id, id);
    assert.equal(result.body.displayName, 'Synthetic Customer');
    assert.equal(result.body.user_metadata, undefined);
    assert.deepEqual(queries, [
      {
        text: 'SELECT id, display_name, role, status FROM bank.user_profiles WHERE id = $1',
        values: [id],
      },
    ]);
  });

  void it('recognizes an active officer only from the database profile', async () => {
    profile!.role = 'officer';
    const result = await request(server)
      .get('/api/v1/me')
      .auth('valid-session', { type: 'bearer' })
      .expect(200);
    assert.equal(result.body.role, 'officer');
  });

  void it('denies access when authentication or application data is unavailable', async () => {
    authUnavailable = true;
    await request(server)
      .get('/api/v1/me')
      .auth('valid-session', { type: 'bearer' })
      .expect(503);
    authUnavailable = false;
    databaseUnavailable = true;
    await request(server)
      .get('/api/v1/me')
      .auth('valid-session', { type: 'bearer' })
      .expect(503);
  });
});
