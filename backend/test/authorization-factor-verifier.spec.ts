import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { SupabaseFactorVerifier } from '../src/authorization-prototype/factor-verifier.js';

const factorId = 'c2000000-0000-4000-8000-000000000001';
const challengeId = 'c2000000-0000-4000-8000-000000000002';
const userId = 'c2000000-0000-4000-8000-000000000003';
const code = '123456';
const session = 'synthetic-access-token';
const returnedSession = {
  access_token: 'synthetic-new-access-token',
  refresh_token: 'synthetic-new-refresh-token',
  token_type: 'bearer',
  user: { id: userId },
};
const verifier = (fetchImpl: typeof fetch) =>
  new SupabaseFactorVerifier(
    'http://127.0.0.1:3001',
    'test-public-key',
    fetchImpl,
  );

void describe('prototype factor adapter (provider responses mocked)', () => {
  void it('permits only local HTTP Auth endpoints and suppresses unsafe configuration', () => {
    for (const url of [
      'https://project.supabase.co/auth/v1',
      'http://192.168.1.20:3001',
      'http://127.0.0.1:3001/other',
      'http://user:secret@127.0.0.1:3001',
      'http://127.0.0.1:3001?secret=value',
      'http://127.0.0.1:3001#value',
      'not a URL',
    ]) {
      assert.throws(() => new SupabaseFactorVerifier(url, 'public-key'), {
        message: 'The factor prototype requires a local Auth endpoint.',
      });
    }
    assert.throws(
      () =>
        new SupabaseFactorVerifier(
          'http://127.0.0.1:3001',
          'key\r\nInjected: value',
        ),
    );
  });

  void it('creates a TOTP challenge with explicit request credentials and a bounded request', async () => {
    const instance = new SupabaseFactorVerifier(
      'http://127.0.0.1:3001/auth/v1/',
      'test-public-key',
      async (input, init) => {
        assert.equal(
          String(input),
          `http://127.0.0.1:3001/auth/v1/factors/${factorId}/challenge`,
        );
        assert.equal(init?.method, 'POST');
        assert.equal(init?.redirect, 'error');
        assert.equal(init?.cache, 'no-store');
        assert.ok(init?.signal instanceof AbortSignal);
        assert.equal(
          new Headers(init?.headers).get('Authorization'),
          `Bearer ${session}`,
        );
        assert.equal(
          new Headers(init?.headers).get('apikey'),
          'test-public-key',
        );
        assert.deepEqual(JSON.parse(init?.body as string), {});
        return Response.json({
          id: challengeId,
          type: 'totp',
          expires_at: 1_900_000_000,
        });
      },
    );
    assert.deepEqual(await instance.challenge(session, factorId), {
      challengeId,
    });
  });

  void it('returns verified identity only and never caches a returned session for another request', async () => {
    const tokens: string[] = [];
    const instance = verifier(async (input, init) => {
      assert.equal(
        String(input),
        `http://127.0.0.1:3001/factors/${factorId}/verify`,
      );
      assert.deepEqual(JSON.parse(init?.body as string), {
        challenge_id: challengeId,
        code,
      });
      tokens.push(new Headers(init?.headers).get('Authorization')!);
      return Response.json(returnedSession);
    });
    const result = await instance.verify(session, factorId, challengeId, code);
    assert.deepEqual(result, { status: 'verified', userId });
    await instance.verify(
      'another-synthetic-session',
      factorId,
      challengeId,
      code,
    );
    assert.deepEqual(tokens, [
      `Bearer ${session}`,
      'Bearer another-synthetic-session',
    ]);
    assert.equal(JSON.stringify(result).includes('token'), false);
  });

  void it('classifies only the provider invalid-code response as a definite rejection', async () => {
    const rejected = verifier(async () =>
      Response.json(
        {
          error_code: 'mfa_verification_failed',
          message: 'private provider detail',
        },
        { status: 422 },
      ),
    );
    assert.deepEqual(
      await rejected.verify(session, factorId, challengeId, code),
      { status: 'rejected' },
    );
    for (const [status, errorCode] of [
      [422, 'mfa_ip_address_mismatch'],
      [422, 'mfa_challenge_expired'],
      [404, 'mfa_factor_not_found'],
      [401, 'bad_jwt'],
      [429, 'over_request_rate_limit'],
      [500, 'unexpected_failure'],
      [503, 'mfa_verification_failed'],
    ] as const) {
      const instance = verifier(async () =>
        Response.json(
          { error_code: errorCode, message: 'private provider detail' },
          { status },
        ),
      );
      assert.deepEqual(
        await instance.verify(session, factorId, challengeId, code),
        { status: 'unknown' },
      );
    }
  });

  void it('does not authorize a malformed success or a login assurance claim', async () => {
    for (const body of [
      { aal: 'aal2' },
      { ...returnedSession, user: { id: 'not-a-user-id' } },
      { ...returnedSession, access_token: '' },
      { ...returnedSession, refresh_token: undefined },
      { ...returnedSession, token_type: 'other' },
      null,
      [],
    ]) {
      const instance = verifier(async () => Response.json(body));
      assert.deepEqual(
        await instance.verify(session, factorId, challengeId, code),
        { status: 'unknown' },
      );
    }
  });

  void it('fails closed on transport timeout, redirects, malformed JSON or oversized response', async () => {
    const failures: Array<typeof fetch> = [
      async () => {
        throw new DOMException('synthetic secret detail', 'TimeoutError');
      },
      async () =>
        new Response(null, {
          status: 302,
          headers: { Location: 'https://elsewhere.invalid' },
        }),
      async () =>
        new Response('{broken', {
          headers: { 'Content-Type': 'application/json' },
        }),
      async () =>
        Response.json({ ...returnedSession, extra: 'a'.repeat(65536) }),
      async () =>
        new Response('{}', {
          headers: {
            'Content-Type': 'application/json',
            'Content-Length': '65537',
          },
        }),
    ];
    for (const fetchImpl of failures) {
      const instance = verifier(fetchImpl);
      assert.deepEqual(
        await instance.verify(session, factorId, challengeId, code),
        { status: 'unknown' },
      );
      await assert.rejects(instance.challenge(session, factorId), {
        message: 'Factor verification is unavailable.',
      });
    }
  });

  void it('rejects invalid IDs, malformed proof and header injection before contacting Auth', async () => {
    let calls = 0;
    const instance = verifier(async () => {
      calls += 1;
      return Response.json(returnedSession);
    });
    for (const [token, factor, challenge, proof] of [
      ['bad\r\nHeader: value', factorId, challengeId, code],
      ['a'.repeat(16385), factorId, challengeId, code],
      [session, '../user', challengeId, code],
      [session, factorId, '../user', code],
      [session, factorId, challengeId, '1234567'],
      [session, factorId, challengeId, '12 456'],
      [session, factorId, challengeId, 123456 as unknown as string],
    ]) {
      assert.deepEqual(
        await instance.verify(token!, factor!, challenge!, proof!),
        { status: 'unknown' },
      );
    }
    await assert.rejects(instance.challenge(session, '../user'), {
      message: 'Factor verification is unavailable.',
    });
    assert.equal(calls, 0);
  });

  void it('rejects non-TOTP or malformed challenge responses without exposing provider detail', async () => {
    for (const body of [
      { id: challengeId, type: 'phone', secret: 'synthetic-private-value' },
      { id: 'invalid', type: 'totp' },
      { status: 'success' },
    ]) {
      await assert.rejects(
        verifier(async () => Response.json(body)).challenge(session, factorId),
        { message: 'Factor verification is unavailable.' },
      );
    }
  });
});
