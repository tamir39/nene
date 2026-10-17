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

  void it('rejects remote TLS disable and URL parameters that override TLS settings', () => {
    assert.throws(
      () =>
        readEnvironment({
          ...localEnvironment,
          DATABASE_URL:
            'postgresql://nene_api:example@database.example:5432/postgres',
        }),
      /TLS may be disabled only/,
    );
    assert.throws(
      () =>
        readEnvironment({
          ...localEnvironment,
          DATABASE_URL: `${localEnvironment.DATABASE_URL}?sslmode=no-verify`,
        }),
      /not URL ssl parameters/,
    );
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
