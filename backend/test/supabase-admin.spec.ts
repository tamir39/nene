import 'reflect-metadata';
import assert from 'node:assert/strict';
import { afterEach, describe, it, mock } from 'node:test';
import {
  BadRequestException,
  ConflictException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { readEnvironment } from '../src/config/environment.js';
import { SupabaseAdminService } from '../src/auth/supabase-admin.service.js';

const id = 'b2000000-0000-4000-8000-000000000001';
const email = 'synthetic@example.invalid';
const password = 'Synthetic-initial-password';

function admin(overrides: NodeJS.ProcessEnv = {}) {
  return new SupabaseAdminService(
    readEnvironment({
      NODE_ENV: 'test',
      SUPABASE_URL: 'http://127.0.0.1:54321',
      SUPABASE_PUBLISHABLE_KEY: 'test-public-key',
      SUPABASE_SECRET_KEY: 'test-admin-key',
      DATABASE_URL: 'postgresql://nene_api:test@127.0.0.1:54322/postgres',
      DATABASE_SSL_MODE: 'disable',
      ...overrides,
    }),
  );
}
const missing = () =>
  Response.json(
    { message: 'User not found', code: 'user_not_found' },
    { status: 404, headers: { 'X-Supabase-Api-Version': '2024-01-01' } },
  );

void describe('local demo Auth provisioning adapter (HTTP responses mocked)', () => {
  afterEach(() => mock.restoreAll());

  void it('requires a secret and restricts implicit demo activation to local development', async () => {
    const fetchMock = mock.method(globalThis, 'fetch', async () =>
      Response.json({}),
    );
    for (const instance of [
      admin({ SUPABASE_SECRET_KEY: '' }),
      admin({ SUPABASE_URL: 'https://hosted.example' }),
    ]) {
      await assert.rejects(
        instance.ensureUser(id, email, password),
        ServiceUnavailableException,
      );
    }
    assert.equal(fetchMock.mock.callCount(), 0);
  });

  void it('uses the durable ID and local password activation without sending invitations', async () => {
    const requests: string[] = [];
    mock.method(
      globalThis,
      'fetch',
      async (input: string | URL | Request, init?: RequestInit) => {
        requests.push(String(input));
        assert.equal(
          new Headers(init?.headers).get('Authorization'),
          'Bearer test-admin-key',
        );
        if (init?.method === 'GET') return missing();
        assert.equal(
          String(input),
          'http://127.0.0.1:54321/auth/v1/admin/users',
        );
        assert.deepEqual(JSON.parse(init?.body as string), {
          id,
          email,
          password,
          email_confirm: true,
        });
        return Response.json({ id, email }, { status: 201 });
      },
    );
    await admin().ensureUser(id, email, password);
    assert.equal(requests.length, 2);
    assert.equal(
      requests.some((url) => url.includes('invite')),
      false,
    );
  });

  void it('reuses an existing reserved identity without changing its credentials', async () => {
    const methods: string[] = [];
    mock.method(
      globalThis,
      'fetch',
      async (_input: string | URL | Request, init?: RequestInit) => {
        methods.push(init?.method ?? 'GET');
        return Response.json({ id, email });
      },
    );
    await admin().ensureUser(id, email, password);
    assert.deepEqual(methods, ['GET']);
  });

  void it('reconciles when create commits but the response is unavailable', async () => {
    let exists = false;
    mock.method(
      globalThis,
      'fetch',
      async (_input: string | URL | Request, init?: RequestInit) => {
        if (init?.method === 'POST') {
          exists = true;
          return Response.json({ message: 'unavailable' }, { status: 503 });
        }
        return exists ? Response.json({ id, email }) : missing();
      },
    );
    await admin().ensureUser(id, email, password);
  });

  void it('rejects a conflicting reserved identity without altering it', async () => {
    mock.method(globalThis, 'fetch', async () =>
      Response.json({ id, email: 'unrelated@example.invalid' }),
    );
    await assert.rejects(
      admin().ensureUser(id, email, password),
      ConflictException,
    );
  });

  void it('reports an already used email without adopting or deleting that user', async () => {
    const methods: string[] = [];
    mock.method(
      globalThis,
      'fetch',
      async (_input: string | URL | Request, init?: RequestInit) => {
        methods.push(init?.method ?? 'GET');
        return init?.method === 'POST'
          ? Response.json(
              { message: 'duplicate', code: 'email_exists' },
              {
                status: 422,
                headers: { 'X-Supabase-Api-Version': '2024-01-01' },
              },
            )
          : missing();
      },
    );
    await assert.rejects(
      admin().ensureUser(id, email, password),
      (error: unknown) =>
        error instanceof ConflictException &&
        (error.getResponse() as { code: string }).code ===
          'CUSTOMER_EMAIL_EXISTS',
    );
    assert.deepEqual(methods, ['GET', 'POST', 'GET']);
  });

  void it('permits correction of definite Auth validation failures only after reconciliation', async () => {
    for (const code of ['email_address_invalid', 'weak_password']) {
      mock.method(
        globalThis,
        'fetch',
        async (_input: string | URL | Request, init?: RequestInit) =>
          init?.method === 'POST'
            ? Response.json(
                { message: 'private provider validation text', code },
                {
                  status: 422,
                  headers: { 'X-Supabase-Api-Version': '2024-01-01' },
                },
              )
            : missing(),
      );
      await assert.rejects(
        admin().ensureUser(id, email, password),
        (error: unknown) =>
          error instanceof BadRequestException &&
          !error.message.includes('private'),
      );
      mock.restoreAll();
    }
  });

  void it('returns a safe unavailable response for provider errors', async () => {
    mock.method(globalThis, 'fetch', async () => {
      throw new Error('private provider data');
    });
    await assert.rejects(
      admin().ensureUser(id, email, password),
      (error: unknown) =>
        error instanceof ServiceUnavailableException &&
        !error.message.includes('private'),
    );
  });
});
