import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  allowsSyntheticDemo,
  readEnvironment,
} from '../src/config/environment.js';

const localEnvironment = {
  NODE_ENV: 'test',
  SUPABASE_URL: 'http://127.0.0.1:54321',
  SUPABASE_PUBLISHABLE_KEY: 'test-public-key',
  DATABASE_URL: 'postgresql://nene_api:test-password@127.0.0.1:54322/postgres',
  DATABASE_SSL_MODE: 'disable',
};

void describe('environment boundaries', () => {
  void it('keeps interbank simulation independently disabled and rejects remote or production enablement', () => {
    assert.equal(
      readEnvironment(localEnvironment).localInterbankEnabled,
      false,
    );
    const enabled = readEnvironment({
      ...localEnvironment,
      LOCAL_INTERBANK_ENABLED: 'true',
    });
    assert.equal(enabled.localInterbankEnabled, true);
    assert.equal(enabled.localTransfersEnabled, false);
    assert.equal(enabled.localCashEnabled, false);
    for (const override of [
      { LOCAL_INTERBANK_ENABLED: 'yes' },
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
          LOCAL_INTERBANK_ENABLED: 'true',
          ...override,
        }),
      );
  });
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
  void it('keeps the assistant AI fallback off unless explicitly enabled with a key', () => {
    const apiKey = 'test-only-placeholder-key-0123456789';
    assert.equal(readEnvironment(localEnvironment).assistantAi, undefined);
    assert.equal(
      readEnvironment({
        ...localEnvironment,
        ASSISTANT_AI_ENABLED: 'false',
        ANTHROPIC_API_KEY: apiKey,
      }).assistantAi,
      undefined,
    );
    assert.deepEqual(
      readEnvironment({
        ...localEnvironment,
        ASSISTANT_AI_ENABLED: 'true',
        ANTHROPIC_API_KEY: ` ${apiKey} `,
      }).assistantAi,
      { apiKey },
    );
    assert.throws(
      () =>
        readEnvironment({ ...localEnvironment, ASSISTANT_AI_ENABLED: 'yes' }),
      { message: 'ASSISTANT_AI_ENABLED must be true or false.' },
    );
    assert.throws(
      () =>
        readEnvironment({ ...localEnvironment, ASSISTANT_AI_ENABLED: 'true' }),
      { message: 'ANTHROPIC_API_KEY is required.' },
    );
    for (const invalid of ['short-key', 'test-only has a space-0123456789'])
      assert.throws(
        () =>
          readEnvironment({
            ...localEnvironment,
            ASSISTANT_AI_ENABLED: 'true',
            ANTHROPIC_API_KEY: invalid,
          }),
        (error: Error) => !error.message.includes(invalid),
      );
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

  const hostedSandbox = {
    NODE_ENV: 'production',
    DEMO_DEPLOYMENT: 'hosted-sandbox',
    SUPABASE_URL: 'https://project-ref.supabase.co',
    SUPABASE_PUBLISHABLE_KEY: 'test-public-key',
    DATABASE_URL:
      'postgresql://nene_api.project-ref:example@pooler.example:5432/postgres',
    DATABASE_SSL_MODE: 'verify-full',
  };

  void it('enables synthetic money movement and VNPay sandbox only on an explicit hosted sandbox', () => {
    const vnpay = {
      VNPAY_TMN_CODE: 'TEST1234',
      VNPAY_HASH_SECRET: 'synthetic-signing-secret-for-tests',
      VNPAY_RETURN_URL: 'https://nene.example.com/api/v1/payments/vnpay/return',
    };
    const flags = [
      'LOCAL_TRANSFERS_ENABLED',
      'LOCAL_CASH_ENABLED',
      'LOCAL_INTERBANK_ENABLED',
      'VNPAY_SANDBOX_ENABLED',
    ];
    const allOn = Object.fromEntries(flags.map((flag) => [flag, 'true']));
    const hosted = readEnvironment({ ...hostedSandbox, ...vnpay, ...allOn });
    assert.equal(hosted.demoDeployment, 'hosted-sandbox');
    assert.equal(hosted.localTransfersEnabled, true);
    assert.equal(hosted.localCashEnabled, true);
    assert.equal(hosted.localInterbankEnabled, true);
    assert.equal(hosted.vnpaySandbox?.terminalCode, 'TEST1234');
    assert.deepEqual(hosted.database.ssl, { rejectUnauthorized: true });
    // Without the explicit marker, each hosted enablement still fails closed.
    for (const flag of flags)
      assert.throws(
        () =>
          readEnvironment({
            ...hostedSandbox,
            ...vnpay,
            DEMO_DEPLOYMENT: '',
            [flag]: 'true',
          }),
        /DEMO_DEPLOYMENT=hosted-sandbox/,
      );
    // Off by default even when hosted.
    const quiet = readEnvironment(hostedSandbox);
    assert.equal(quiet.localTransfersEnabled, false);
    assert.equal(quiet.vnpaySandbox, undefined);
  });

  void it('accepts only the exact hosted-sandbox marker under production TLS rules', () => {
    for (const value of ['true', 'hosted', 'HOSTED-SANDBOX', 'local'])
      assert.throws(
        () => readEnvironment({ ...hostedSandbox, DEMO_DEPLOYMENT: value }),
        /DEMO_DEPLOYMENT must be hosted-sandbox/,
      );
    assert.throws(
      () =>
        readEnvironment({
          ...localEnvironment,
          DEMO_DEPLOYMENT: 'hosted-sandbox',
        }),
      /requires NODE_ENV=production/,
    );
    assert.throws(
      () => readEnvironment({ ...hostedSandbox, DATABASE_SSL_MODE: 'disable' }),
      /TLS may be disabled only/,
    );
    assert.throws(
      () =>
        readEnvironment({
          ...hostedSandbox,
          SUPABASE_URL: 'http://project-ref.supabase.co',
        }),
      /requires HTTPS/,
    );
    assert.equal(
      readEnvironment({ ...hostedSandbox, DEMO_DEPLOYMENT: '' }).demoDeployment,
      undefined,
    );
  });

  void it('allows synthetic demo provisioning only locally or on the hosted sandbox', () => {
    assert.equal(allowsSyntheticDemo(readEnvironment(localEnvironment)), true);
    assert.equal(allowsSyntheticDemo(readEnvironment(hostedSandbox)), true);
    assert.equal(
      allowsSyntheticDemo(
        readEnvironment({ ...hostedSandbox, DEMO_DEPLOYMENT: '' }),
      ),
      false,
    );
    assert.equal(
      allowsSyntheticDemo(
        readEnvironment({
          ...localEnvironment,
          SUPABASE_URL: 'https://project-ref.supabase.co',
        }),
      ),
      false,
    );
  });
});
