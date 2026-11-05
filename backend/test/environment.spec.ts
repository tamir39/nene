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
  void it('keeps VNPay disabled until complete sandbox configuration is explicitly enabled', () => {
    assert.equal(readEnvironment(localEnvironment).vnpaySandbox, undefined);
    const configured = {
      ...localEnvironment,
      VNPAY_SANDBOX_ENABLED: 'true',
      VNPAY_TMN_CODE: 'TEST1234',
      VNPAY_HASH_SECRET: 'synthetic-signing-secret-for-tests',
      VNPAY_RETURN_URL: 'https://nene.example.com/api/v1/payments/vnpay/return',
    };
    assert.deepEqual(readEnvironment(configured).vnpaySandbox, {
      terminalCode: configured.VNPAY_TMN_CODE,
      hashSecret: configured.VNPAY_HASH_SECRET,
      returnUrl: configured.VNPAY_RETURN_URL,
    });
    for (const override of [
      { VNPAY_SANDBOX_ENABLED: 'yes' },
      { VNPAY_TMN_CODE: '' },
      { VNPAY_TMN_CODE: 'invalid-terminal' },
      { VNPAY_HASH_SECRET: '' },
      { VNPAY_HASH_SECRET: 'short' },
      { VNPAY_RETURN_URL: '' },
      {
        VNPAY_RETURN_URL:
          'http://nene.example.com/api/v1/payments/vnpay/return',
      },
      { VNPAY_RETURN_URL: 'https://localhost/api/v1/payments/vnpay/return' },
      { VNPAY_RETURN_URL: 'https://127.0.0.1/api/v1/payments/vnpay/return' },
      { VNPAY_RETURN_URL: 'https://nene.local/api/v1/payments/vnpay/return' },
      { VNPAY_RETURN_URL: 'https://nene.example.com/' },
      {
        VNPAY_RETURN_URL:
          'https://nene.example.com/api/v1/payments/vnpay/return?token=x',
      },
      {
        VNPAY_RETURN_URL:
          'https://user:secret@nene.example.com/api/v1/payments/vnpay/return',
      },
      { SUPABASE_URL: 'https://example.supabase.co' },
      {
        DATABASE_URL:
          'postgresql://nene_api:example@remote.example:5432/postgres',
        DATABASE_SSL_MODE: 'verify-full',
      },
      {
        NODE_ENV: 'production',
        SUPABASE_URL: 'https://localhost',
        DATABASE_SSL_MODE: 'verify-full',
      },
    ])
      assert.throws(() => readEnvironment({ ...configured, ...override }));
  });
  void it('keeps cash simulation off by default and refuses remote or production activation', () => {
    assert.equal(readEnvironment(localEnvironment).localCashEnabled, false);
    assert.equal(
      readEnvironment({ ...localEnvironment, LOCAL_CASH_ENABLED: 'true' })
        .localCashEnabled,
      true,
    );
    for (const override of [
      { LOCAL_CASH_ENABLED: 'yes' },
      { SUPABASE_URL: 'https://example.supabase.co' },
      {
        DATABASE_URL:
          'postgresql://nene_api:example@database.example:5432/postgres',
        DATABASE_SSL_MODE: 'verify-full',
      },
      {
        NODE_ENV: 'production',
        SUPABASE_URL: 'https://localhost',
        DATABASE_SSL_MODE: 'verify-full',
      },
    ])
      assert.throws(() =>
        readEnvironment({
          ...localEnvironment,
          LOCAL_CASH_ENABLED: 'true',
          ...override,
        }),
      );
  });
  void it('enables synthetic transfers only with explicit non-production loopback configuration', () => {
    assert.equal(
      readEnvironment(localEnvironment).localTransfersEnabled,
      false,
    );
    assert.equal(
      readEnvironment({ ...localEnvironment, LOCAL_TRANSFERS_ENABLED: 'true' })
        .localTransfersEnabled,
      true,
    );
    for (const override of [
      { LOCAL_TRANSFERS_ENABLED: 'yes' },
      { SUPABASE_URL: 'https://example.supabase.co' },
      {
        DATABASE_URL:
          'postgresql://nene_api:example@database.example:5432/postgres',
        DATABASE_SSL_MODE: 'verify-full',
      },
      {
        NODE_ENV: 'production',
        SUPABASE_URL: 'https://localhost',
        DATABASE_SSL_MODE: 'verify-full',
      },
    ]) {
      assert.throws(() =>
        readEnvironment({
          ...localEnvironment,
          LOCAL_TRANSFERS_ENABLED: 'true',
          ...override,
        }),
      );
    }
  });
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
