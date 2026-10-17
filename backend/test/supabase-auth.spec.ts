import 'reflect-metadata';
import assert from 'node:assert/strict';
import { afterEach, describe, it, mock } from 'node:test';
import {
  UnauthorizedException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { readEnvironment } from '../src/config/environment.js';
import { SupabaseAuthService } from '../src/auth/supabase-auth.service.js';

function createAuth() {
  return new SupabaseAuthService(
    readEnvironment({
      NODE_ENV: 'test',
      SUPABASE_URL: 'http://127.0.0.1:54321',
      SUPABASE_PUBLISHABLE_KEY: 'test-public-key',
      DATABASE_URL: 'postgresql://nene_api:test@127.0.0.1:54322/postgres',
      DATABASE_SSL_MODE: 'disable',
    }),
  );
}

void describe('Supabase token validation adapter (HTTP responses mocked)', () => {
  afterEach(() => mock.restoreAll());

  void it('validates through the Auth user endpoint and returns identity only', async () => {
    mock.method(
      globalThis,
      'fetch',
      async (input: string | URL | Request, init?: RequestInit) => {
        assert.equal(String(input), 'http://127.0.0.1:54321/auth/v1/user');
        assert.equal(
          new Headers(init?.headers).get('Authorization'),
          'Bearer supplied-session',
        );
        return Response.json({
          id: 'synthetic-id',
          email: 'synthetic@example.test',
          user_metadata: { role: 'officer' },
        });
      },
    );
    assert.deepEqual(await createAuth().verifyAccessToken('supplied-session'), {
      id: 'synthetic-id',
      email: 'synthetic@example.test',
    });
  });

  void it('rejects an expired or invalid session response', async () => {
    mock.method(globalThis, 'fetch', async () =>
      Response.json(
        { message: 'invalid JWT', code: 'bad_jwt' },
        { status: 401 },
      ),
    );
    await assert.rejects(
      createAuth().verifyAccessToken('expired-session'),
      UnauthorizedException,
    );
  });

  void it('fails closed on an authentication service failure', async () => {
    mock.method(globalThis, 'fetch', async () =>
      Response.json({ message: 'unavailable' }, { status: 503 }),
    );
    await assert.rejects(
      createAuth().verifyAccessToken('supplied-session'),
      ServiceUnavailableException,
    );
  });
});
