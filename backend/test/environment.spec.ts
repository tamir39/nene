import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { readEnvironment } from '../src/config/environment.js';

const localEnvironment = {
  NODE_ENV: 'test',
  SUPABASE_URL: 'http://127.0.0.1:54321',
  SUPABASE_PUBLISHABLE_KEY: 'test-public-key',
  DATABASE_URL: 'postgresql://nene_api:test-password@127.0.0.1:54322/postgres',
  DATABASE_SSL_MODE: 'disable',
};

void describe('environment boundaries', () => {
  void it('fails closed when authentication configuration is missing', () => {
    assert.throws(
      () =>
        readEnvironment({ ...localEnvironment, SUPABASE_PUBLISHABLE_KEY: '' }),
      /SUPABASE_PUBLISHABLE_KEY is required/,
    );
  });

  void it('allows explicit local development without PostgreSQL TLS', () => {
    assert.equal(readEnvironment(localEnvironment).database.ssl, false);
  });

  void it('requires certificate verification for a hosted PostgreSQL connection', () => {
    const environment = readEnvironment({
      ...localEnvironment,
      SUPABASE_URL: 'https://example.supabase.co',
      DATABASE_URL:
        'postgresql://nene_api:example@database.example:5432/postgres',
      DATABASE_SSL_MODE: 'verify-full',
    });
    assert.deepEqual(environment.database.ssl, { rejectUnauthorized: true });
  });

  void it('preserves a restricted Supabase pooler URL with encoded credentials', () => {
    const connectionString =
      'postgresql://nene_api.project-ref:synthetic%3Fp%40ss%26word@pooler.example:6543/postgres';
    const environment = readEnvironment({
      ...localEnvironment,
      DATABASE_URL: connectionString,
      DATABASE_SSL_MODE: 'verify-full',
    });
    assert.equal(environment.database.connectionString, connectionString);
    assert.deepEqual(environment.database.ssl, { rejectUnauthorized: true });
  });

  void it('rejects remote TLS disable', () => {
    assert.throws(
      () =>
        readEnvironment({
          ...localEnvironment,
          DATABASE_URL:
            'postgresql://nene_api:example@database.example:5432/postgres',
        }),
      /TLS may be disabled only/,
    );
  });

  void it('rejects query parameters that override the validated database role', () => {
    for (const query of ['user=postgres', '%75ser=postgres']) {
      assert.throws(
        () =>
          readEnvironment({
            ...localEnvironment,
            DATABASE_URL: `${localEnvironment.DATABASE_URL}?${query}`,
          }),
        /DATABASE_URL must not contain query parameters/,
      );
    }
  });

  void it('rejects query parameters that redirect a loopback connection', () => {
    for (const query of [
      'host=remote.example',
      'port=6543',
      'user=postgres&host=remote.example',
    ]) {
      assert.throws(
        () =>
          readEnvironment({
            ...localEnvironment,
            DATABASE_URL: `${localEnvironment.DATABASE_URL}?${query}`,
          }),
        /DATABASE_URL must not contain query parameters/,
      );
    }
  });

  void it('rejects query parameters that override explicit TLS settings', () => {
    for (const query of ['sslmode=no-verify', 'ssl=false']) {
      assert.throws(
        () =>
          readEnvironment({
            ...localEnvironment,
            DATABASE_URL: `${localEnvironment.DATABASE_URL}?${query}`,
            DATABASE_SSL_MODE: 'verify-full',
          }),
        /configure TLS with DATABASE_SSL_MODE and DATABASE_SSL_CA_FILE/,
      );
    }
  });

  void it('rejects other query options instead of allowing implicit driver overrides', () => {
    for (const query of [
      'statement_timeout=0',
      'options=-c%20statement_timeout%3D0',
      'application_name=unexpected',
    ]) {
      assert.throws(
        () =>
          readEnvironment({
            ...localEnvironment,
            DATABASE_URL: `${localEnvironment.DATABASE_URL}?${query}`,
          }),
        /DATABASE_URL must not contain query parameters/,
      );
    }
  });

  void it('rejects plaintext connections in production', () => {
    assert.throws(
      () => readEnvironment({ ...localEnvironment, NODE_ENV: 'production' }),
      /SUPABASE_URL requires HTTPS/,
    );
    assert.throws(
      () =>
        readEnvironment({
          ...localEnvironment,
          NODE_ENV: 'production',
          SUPABASE_URL: 'https://example.supabase.co',
        }),
      /TLS may be disabled only/,
    );
  });

  void it('rejects an administrative database login', () => {
    assert.throws(
      () =>
        readEnvironment({
          ...localEnvironment,
          DATABASE_URL:
            'postgresql://postgres:example@127.0.0.1:54322/postgres',
        }),
      /restricted nene_api role/,
    );
  });
});
