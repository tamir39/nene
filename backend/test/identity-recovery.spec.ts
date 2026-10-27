import 'reflect-metadata';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { afterEach, describe, it, mock } from 'node:test';
import { ServiceUnavailableException } from '@nestjs/common';
import { readEnvironment } from '../src/config/environment.js';
import { IdentityStorageService } from '../src/identity/identity-storage.service.js';

const key = 'synthetic-customer/synthetic-case/reserved-object';
const objectUrl = `http://127.0.0.1:54321/storage/v1/object/identity-evidence/${key}`;
// Transport-only bytes; actual image decoding is covered separately.
const bytes = Buffer.from('synthetic-reference-bytes');
const digest = createHash('sha256').update(bytes).digest('hex');

function storage(secret = 'test-storage-secret') {
  return new IdentityStorageService(
    readEnvironment({
      NODE_ENV: 'test',
      SUPABASE_URL: 'http://127.0.0.1:54321',
      SUPABASE_PUBLISHABLE_KEY: 'test-public-key',
      SUPABASE_SECRET_KEY: secret,
      DATABASE_URL: 'postgresql://nene_api:test@127.0.0.1:54322/postgres',
      DATABASE_SSL_MODE: 'disable',
    }),
  );
}

void describe('private reference Storage recovery (HTTP responses mocked)', () => {
  afterEach(() => mock.restoreAll());

  void it('writes only the reserved private object without overwrite and with a bounded request', async () => {
    const requests: string[] = [];
    mock.method(
      globalThis,
      'fetch',
      async (input: string | URL | Request, init?: RequestInit) => {
        requests.push(String(input));
        assert.equal(init?.method, 'POST');
        const headers = new Headers(init?.headers);
        assert.equal(
          headers.get('Authorization'),
          'Bearer test-storage-secret',
        );
        assert.equal(headers.get('x-upsert'), 'false');
        assert.equal(headers.get('content-type'), 'image/png');
        assert.ok(init?.signal instanceof AbortSignal);
        return Response.json(
          { Key: `identity-evidence/${key}` },
          { status: 200 },
        );
      },
    );
    await storage().write(key, bytes, 'image/png', digest);
    assert.deepEqual(requests, [objectUrl]);
  });

  void it('reconciles a committed upload with a lost reply using the same key and matching bytes', async () => {
    const requests: { method: string; url: string }[] = [];
    let committed: Buffer | undefined;
    mock.method(
      globalThis,
      'fetch',
      async (input: string | URL | Request, init?: RequestInit) => {
        const method = init?.method ?? 'GET';
        requests.push({ method, url: String(input) });
        assert.equal(
          new Headers(init?.headers).get('Authorization'),
          'Bearer test-storage-secret',
        );
        if (method === 'POST') {
          committed = bytes;
          throw new TypeError('Synthetic lost upload reply');
        }
        assert.ok(committed);
        return new Response(Uint8Array.from(committed), {
          headers: { 'Content-Type': 'image/png' },
        });
      },
    );
    await storage().write(key, bytes, 'image/png', digest);
    assert.deepEqual(requests, [
      { method: 'POST', url: objectUrl },
      { method: 'GET', url: objectUrl },
    ]);
  });

  void it('does not adopt mismatching bytes or overwrite a conflicting reserved object', async () => {
    const methods: string[] = [];
    mock.method(
      globalThis,
      'fetch',
      async (_input: string | URL | Request, init?: RequestInit) => {
        const method = init?.method ?? 'GET';
        methods.push(method);
        return method === 'POST'
          ? Response.json({ message: 'Object already exists' }, { status: 409 })
          : new Response('unrelated synthetic bytes');
      },
    );
    await assert.rejects(
      storage().write(key, bytes, 'image/png', digest),
      (error: unknown) =>
        error instanceof ServiceUnavailableException &&
        error.message ===
          'The reference upload could not be reconciled. Check status before retrying.',
    );
    assert.deepEqual(methods, ['POST', 'GET']);
  });

  void it('reports an unavailable reconciliation without returning provider diagnostics or a success', async () => {
    const methods: string[] = [];
    mock.method(
      globalThis,
      'fetch',
      async (_input: string | URL | Request, init?: RequestInit) => {
        methods.push(init?.method ?? 'GET');
        return Response.json(
          { message: 'Synthetic internal provider diagnostic' },
          { status: 503 },
        );
      },
    );
    await assert.rejects(
      storage().write(key, bytes, 'image/png', digest),
      (error: unknown) =>
        error instanceof ServiceUnavailableException &&
        error.message ===
          'The private reference photo is temporarily unavailable.',
    );
    assert.deepEqual(methods, ['POST', 'GET']);
  });

  void it('fails cleanup safely for the exact reserved object when Storage refuses deletion', async () => {
    const methods: string[] = [];
    mock.method(
      globalThis,
      'fetch',
      async (input: string | URL | Request, init?: RequestInit) => {
        methods.push(init?.method ?? 'GET');
        assert.equal(
          String(input),
          'http://127.0.0.1:54321/storage/v1/object/identity-evidence',
        );
        assert.deepEqual(JSON.parse(init?.body as string), { prefixes: [key] });
        return Response.json({ message: 'Synthetic failure' }, { status: 503 });
      },
    );
    await assert.rejects(
      storage().remove(key),
      (error: unknown) =>
        error instanceof ServiceUnavailableException &&
        error.message ===
          'Expired reference cleanup is temporarily unavailable.',
    );
    assert.deepEqual(methods, ['DELETE']);
  });

  void it('makes no Storage request when backend credentials are absent', async () => {
    const fetchMock = mock.method(globalThis, 'fetch', async () =>
      Response.json({}),
    );
    const unavailable = storage('');
    await assert.rejects(
      unavailable.write(key, bytes, 'image/png', digest),
      ServiceUnavailableException,
    );
    await assert.rejects(unavailable.read(key), ServiceUnavailableException);
    await assert.rejects(unavailable.remove(key), ServiceUnavailableException);
    assert.equal(fetchMock.mock.callCount(), 0);
  });
});
