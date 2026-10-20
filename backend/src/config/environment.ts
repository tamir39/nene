import { readFileSync } from 'node:fs';
import type { PoolConfig } from 'pg';

export interface Environment {
  nodeEnv: 'development' | 'test' | 'production';
  host: string;
  port: number;
  supabaseUrl: string;
  supabasePublishableKey: string;
  supabaseSecretKey?: string;
  database: PoolConfig;
}

function required(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
}

function parseUrl(value: string, name: string): URL {
  try {
    return new URL(value);
  } catch {
    throw new Error(`${name} must be a valid URL.`);
  }
}

function isLoopback(hostname: string): boolean {
  return ['localhost', '127.0.0.1', '[::1]'].includes(hostname);
}

export function readEnvironment(env: NodeJS.ProcessEnv): Environment {
  const nodeEnv = env.NODE_ENV ?? 'development';
  if (!['development', 'test', 'production'].includes(nodeEnv)) {
    throw new Error('NODE_ENV must be development, test, or production.');
  }
  const port = Number(env.PORT ?? 3000);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('PORT must be an integer between 1 and 65535.');
  }
  const supabaseUrl = parseUrl(required(env, 'SUPABASE_URL'), 'SUPABASE_URL');
  if (
    supabaseUrl.protocol !== 'https:' &&
    !(
      supabaseUrl.protocol === 'http:' &&
      isLoopback(supabaseUrl.hostname) &&
      nodeEnv !== 'production'
    )
  ) {
    throw new Error('SUPABASE_URL requires HTTPS, except local development.');
  }
  if (
    supabaseUrl.username ||
    supabaseUrl.password ||
    supabaseUrl.search ||
    supabaseUrl.hash
  ) {
    throw new Error(
      'SUPABASE_URL must not contain credentials, a query, or a fragment.',
    );
  }

  const connectionString = required(env, 'DATABASE_URL');
  const databaseUrl = parseUrl(connectionString, 'DATABASE_URL');
  if (!['postgres:', 'postgresql:'].includes(databaseUrl.protocol)) {
    throw new Error('DATABASE_URL must use postgres or postgresql.');
  }
  if (!/^nene_api(?:\.[A-Za-z0-9-]+)?$/.test(databaseUrl.username)) {
    throw new Error('DATABASE_URL must use the restricted nene_api role.');
  }
  if (databaseUrl.search) {
    // pg gives query parameters precedence over the authority and pool options.
    throw new Error(
      'DATABASE_URL must not contain query parameters. Put the user and host in the URL authority; configure TLS with DATABASE_SSL_MODE and DATABASE_SSL_CA_FILE.',
    );
  }
  const sslMode = required(env, 'DATABASE_SSL_MODE');
  if (!['verify-full', 'disable'].includes(sslMode)) {
    throw new Error('DATABASE_SSL_MODE must be verify-full or disable.');
  }
  if (
    sslMode === 'disable' &&
    (!isLoopback(databaseUrl.hostname) || nodeEnv === 'production')
  ) {
    throw new Error(
      'PostgreSQL TLS may be disabled only for local development.',
    );
  }
  let ca: string | undefined;
  if (env.DATABASE_SSL_CA_FILE?.trim()) {
    if (sslMode !== 'verify-full')
      throw new Error('A PostgreSQL CA requires verify-full TLS.');
    try {
      ca = readFileSync(env.DATABASE_SSL_CA_FILE.trim(), 'utf8');
    } catch {
      throw new Error('DATABASE_SSL_CA_FILE could not be read.');
    }
  }

  return {
    nodeEnv: nodeEnv as Environment['nodeEnv'],
    host: env.HOST?.trim() || '127.0.0.1',
    port,
    supabaseUrl: supabaseUrl.toString().replace(/\/$/, ''),
    supabasePublishableKey: required(env, 'SUPABASE_PUBLISHABLE_KEY'),
    ...(env.SUPABASE_SECRET_KEY?.trim()
      ? { supabaseSecretKey: env.SUPABASE_SECRET_KEY.trim() }
      : {}),
    database: {
      connectionString,
      ssl:
        sslMode === 'disable'
          ? false
          : { rejectUnauthorized: true, ...(ca ? { ca } : {}) },
      max: 5,
      connectionTimeoutMillis: 5000,
      idleTimeoutMillis: 30000,
      statement_timeout: 5000,
      application_name: 'nene-api',
    },
  };
}
