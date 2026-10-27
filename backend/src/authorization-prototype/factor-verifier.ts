// Local prototype adapter only. Deliberately absent from AppModule and routes.
// This verifies a factor; the caller must bind userId to a reserved operation.
export type VerificationResult =
  | { status: 'verified'; userId: string }
  | { status: 'rejected' }
  | { status: 'unknown' };

export interface FactorVerifier {
  challenge(
    accessToken: string,
    factorId: string,
  ): Promise<{ challengeId: string }>;
  verify(
    accessToken: string,
    factorId: string,
    challengeId: string,
    code: string,
  ): Promise<VerificationResult>;
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const maxResponseBytes = 64 * 1024;
const unavailable = () => new Error('Factor verification is unavailable.');

function credential(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= 16384 &&
    /^[\x21-\x7e]+$/.test(value) &&
    !value.includes(',')
  );
}

function identifier(value: unknown): value is string {
  return typeof value === 'string' && uuid.test(value);
}

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

async function readJson(response: Response): Promise<Record<string, unknown>> {
  const declaredLength = response.headers.get('content-length');
  if (
    !response.headers
      .get('content-type')
      ?.toLowerCase()
      .startsWith('application/json') ||
    (declaredLength !== null &&
      (!/^\d+$/.test(declaredLength) ||
        Number(declaredLength) > maxResponseBytes))
  ) {
    await response.body?.cancel();
    throw unavailable();
  }
  if (!response.body) throw unavailable();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxResponseBytes) {
        await reader.cancel();
        throw unavailable();
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!object(parsed)) throw unavailable();
  return parsed;
}

export class SupabaseFactorVerifier implements FactorVerifier {
  private readonly authBaseUrl: string;

  constructor(
    authBaseUrl: string,
    private readonly publicKey: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {
    try {
      const url = new URL(authBaseUrl);
      if (
        url.protocol !== 'http:' ||
        !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) ||
        url.username ||
        url.password ||
        url.search ||
        url.hash ||
        !['/', '/auth/v1', '/auth/v1/'].includes(url.pathname) ||
        !credential(publicKey)
      ) {
        throw unavailable();
      }
      this.authBaseUrl = url.href.replace(/\/$/, '');
    } catch {
      throw new Error('The factor prototype requires a local Auth endpoint.');
    }
  }

  private async post(
    path: string,
    accessToken: string,
    body: Record<string, string>,
  ): Promise<{ status: number; data: Record<string, unknown> }> {
    const response = await this.fetchImpl(`${this.authBaseUrl}${path}`, {
      method: 'POST',
      redirect: 'error',
      cache: 'no-store',
      signal: AbortSignal.timeout(5000),
      headers: {
        apikey: this.publicKey,
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    });
    return { status: response.status, data: await readJson(response) };
  }

  async challenge(
    accessToken: string,
    factorId: string,
  ): Promise<{ challengeId: string }> {
    try {
      if (!credential(accessToken) || !identifier(factorId))
        throw unavailable();
      const response = await this.post(
        `/factors/${factorId}/challenge`,
        accessToken,
        {},
      );
      if (
        response.status !== 200 ||
        response.data.type !== 'totp' ||
        !identifier(response.data.id)
      ) {
        throw unavailable();
      }
      return { challengeId: response.data.id };
    } catch {
      // Provider details can contain tokens and operational data. Never expose them.
      throw unavailable();
    }
  }

  async verify(
    accessToken: string,
    factorId: string,
    challengeId: string,
    code: string,
  ): Promise<VerificationResult> {
    try {
      if (
        !credential(accessToken) ||
        !identifier(factorId) ||
        !identifier(challengeId) ||
        typeof code !== 'string' ||
        !/^\d{6}$/.test(code)
      ) {
        return { status: 'unknown' };
      }
      const response = await this.post(
        `/factors/${factorId}/verify`,
        accessToken,
        { challenge_id: challengeId, code },
      );
      if (
        response.status === 422 &&
        response.data.error_code === 'mfa_verification_failed'
      ) {
        return { status: 'rejected' };
      }
      const user = response.data.user;
      if (
        response.status === 200 &&
        credential(response.data.access_token) &&
        credential(response.data.refresh_token) &&
        response.data.token_type === 'bearer' &&
        object(user) &&
        identifier(user.id)
      ) {
        // Returned session tokens are deliberately not cached, logged or returned.
        // Session handoff/recovery remains outside this no-money prototype.
        return { status: 'verified', userId: user.id };
      }
      return { status: 'unknown' };
    } catch {
      // A timeout may follow successful provider verification. Do not call it denied.
      return { status: 'unknown' };
    }
  }
}
