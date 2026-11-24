import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Inject,
  Injectable,
  ServiceUnavailableException,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { ENVIRONMENT } from '../config/config.module.js';
import type { Environment } from '../config/environment.js';
import { DatabaseService } from '../database/database.service.js';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { reserveSecurityProof } from './security-proof.js';

const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
type Row = {
  customer_id: string;
  request_id: string;
  session_id: string;
  factor_id: string | null;
  state: string;
  revision: number;
  attempts: number;
  expires_at: Date;
};

@Injectable()
export class SecurityService {
  constructor(
    private readonly db: DatabaseService,
    @Inject(ENVIRONMENT) private readonly env: Environment,
  ) {}

  // SessionGuard has already validated this exact bearer at Auth /user.
  identity(req: AuthenticatedRequest) {
    if (req.user.role !== 'customer') throw new ForbiddenException();
    const token = req.headers.authorization!.slice(7);
    try {
      const claims = JSON.parse(
        Buffer.from(token.split('.')[1]!, 'base64url').toString(),
      ) as {
        sub: string;
        session_id: string;
        amr?: { method: string; timestamp: number }[];
      };
      if (claims.sub !== req.user.id || !uuid.test(claims.session_id))
        throw new Error();
      return {
        token,
        session: claims.session_id,
        passwordAt: Math.max(
          0,
          ...(claims.amr ?? [])
            .filter((x) => x.method === 'password')
            .map((x) => x.timestamp),
        ),
      };
    } catch {
      throw new ForbiddenException();
    }
  }

  async provider(
    path: string,
    token: string,
    body?: object,
    method?: 'GET' | 'POST' | 'DELETE',
  ): Promise<Record<string, unknown>> {
    try {
      const response = await fetch(`${this.env.supabaseUrl}/auth/v1${path}`, {
        method: method ?? (body ? 'POST' : 'GET'),
        redirect: 'error',
        signal: AbortSignal.timeout(8000),
        headers: {
          apikey: this.env.supabasePublishableKey,
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      if (response.ok && response.status === 204) return {};
      if (response.status === 404 && path === '/factors/recovery-codes')
        return { remaining: 0, total: 0 };
      const reader = response.body!.getReader();
      const chunks: Uint8Array[] = [];
      let size = 0;
      try {
        for (;;) {
          const part = await reader.read();
          if (part.done) break;
          size += part.value.length;
          if (size > 2 * 1024 * 1024) throw new Error();
          chunks.push(part.value);
        }
      } finally {
        await reader.cancel();
        reader.releaseLock();
      }
      const data: unknown = JSON.parse(Buffer.concat(chunks).toString());
      if (!response.ok) {
        if (
          path.endsWith('/verify') &&
          [400, 422].includes(response.status) &&
          (data as { error_code?: string })?.error_code ===
            'mfa_verification_failed'
        )
          throw new BadRequestException('Incorrect authenticator code.');
        throw new Error();
      }
      if (!data || typeof data !== 'object' || Array.isArray(data))
        throw new Error();
      return data as Record<string, unknown>;
    } catch (error) {
      if (error instanceof BadRequestException) throw error;
      throw new ServiceUnavailableException(
        'Authenticator request could not be confirmed. Check status before retrying.',
      );
    }
  }

  async status(req: AuthenticatedRequest) {
    const identity = this.identity(req);
    const [row] = await this.db.query<Row>(
      'select * from bank.authenticator_setup where customer_id=$1',
      [req.user.id],
    );
    if (!row) return { state: 'not_set_up' };
    if (row.state === 'restricted') return { state: 'restricted' };
    const user = await this.provider('/user', identity.token);
    const factors = Array.isArray(user.factors)
      ? (user.factors as Record<string, unknown>[])
      : [];
    const own = factors.find(
      (f) => f.id === row.factor_id && f.factor_type === 'totp',
    );
    // Reconcile verification success after a lost direct response. Never replay its tokens.
    if (
      own?.status === 'verified' &&
      ['verifying', 'ready'].includes(row.state)
    ) {
      await this.db.query(
        "update bank.authenticator_setup set state='ready' where customer_id=$1 and request_id=$2 and state in ('verifying','ready')",
        [req.user.id, row.request_id],
      );
      return { state: 'ready' };
    }
    return {
      state:
        row.state === 'pending' &&
        row.expires_at > new Date() &&
        row.session_id === identity.session
          ? 'pending'
          : 'blocked',
      requestId: row.request_id,
      revision: row.revision,
    };
  }

  async start(req: AuthenticatedRequest) {
    const identity = this.identity(req);
    const now = Date.now() / 1000;
    if (
      !Number.isFinite(identity.passwordAt) ||
      identity.passwordAt < now - 300 ||
      identity.passwordAt > now + 30
    )
      throw new ForbiddenException('Sign out and sign in again before setup.');
    const requestId = randomUUID();
    // Persist ownership before provider effects; unknown enrollment must never duplicate.
    const reserved = await this.db.query<Row>(
      "insert into bank.authenticator_setup(customer_id,request_id,session_id,state) values($1,$2,$3,'starting') on conflict do nothing returning *",
      [req.user.id, requestId, identity.session],
    );
    if (!reserved.length)
      throw new ConflictException('Setup already exists. Check status.');
    const user = await this.provider('/user', identity.token);
    if (Array.isArray(user.factors) && user.factors.length)
      throw new ConflictException('Existing factors require recovery support.');
    const factor = await this.provider('/factors', identity.token, {
      factor_type: 'totp',
      friendly_name: 'Nene authenticator',
      issuer: 'Nene',
    });
    const totp = factor.totp as { secret?: unknown } | undefined;
    if (
      typeof factor.id !== 'string' ||
      !uuid.test(factor.id) ||
      typeof totp?.secret !== 'string' ||
      !/^[A-Z2-7]{16,128}$/.test(totp.secret)
    )
      throw new ServiceUnavailableException();
    await this.db.query(
      "update bank.authenticator_setup set factor_id=$2,state='pending' where customer_id=$1 and request_id=$3 and state='starting'",
      [req.user.id, factor.id, requestId],
    );
    return { requestId, revision: 1, secret: totp.secret };
  }

  async verify(req: AuthenticatedRequest, body: unknown) {
    const identity = this.identity(req);
    const input = body as { requestId?: unknown; code?: unknown } | null;
    if (
      !input ||
      typeof input.requestId !== 'string' ||
      !uuid.test(input.requestId) ||
      typeof input.code !== 'string' ||
      !/^\d{6}$/.test(input.code) ||
      Object.keys(input).some((k) => !['requestId', 'code'].includes(k))
    )
      throw new BadRequestException();
    const [row] = await this.db.query<Row>(
      "update bank.authenticator_setup set state='verifying',attempts=attempts+1 where customer_id=$1 and request_id=$2 and session_id=$3 and state='pending' and expires_at>now() and attempts<5 returning *",
      [req.user.id, input.requestId, identity.session],
    );
    if (!row?.factor_id) throw new ConflictException('Check setup status.');
    // One attempt per pending setup: any uncertainty remains blocked/reconcilable.
    // Never put an uncertain request back into pending or re-submit its code.
    try {
      await reserveSecurityProof(
        this.db,
        req.user.id,
        row.factor_id,
        input.code,
        'enroll',
      );
    } catch (error) {
      await this.db.query(
        "update bank.authenticator_setup set state=case when attempts<5 then 'pending' else 'blocked' end where customer_id=$1 and request_id=$2 and state='verifying'",
        [req.user.id, row.request_id],
      );
      throw error;
    }
    const challenge = await this.provider(
      `/factors/${row.factor_id}/challenge`,
      identity.token,
      {},
    );
    if (typeof challenge.id !== 'string' || !uuid.test(challenge.id))
      throw new ServiceUnavailableException();
    let pair: Record<string, unknown>;
    try {
      pair = await this.provider(
        `/factors/${row.factor_id}/verify`,
        identity.token,
        { challenge_id: challenge.id, code: input.code },
      );
    } catch (error) {
      if (error instanceof BadRequestException) {
        await this.db.query(
          "update bank.authenticator_setup set state=case when attempts<5 then 'pending' else 'blocked' end where customer_id=$1 and request_id=$2 and state='verifying'",
          [req.user.id, row.request_id],
        );
      }
      throw error;
    }
    if (
      typeof pair.access_token !== 'string' ||
      typeof pair.refresh_token !== 'string'
    )
      throw new ServiceUnavailableException();
    const user = await this.provider('/user', pair.access_token);
    if (user.id !== req.user.id) throw new ForbiddenException();
    if (
      !Array.isArray(user.factors) ||
      !user.factors.some(
        (f: { id?: string; status?: string; factor_type?: string }) =>
          f.id === row.factor_id &&
          f.status === 'verified' &&
          f.factor_type === 'totp',
      )
    )
      throw new ForbiddenException();
    const claims = JSON.parse(
      Buffer.from(pair.access_token.split('.')[1]!, 'base64url').toString(),
    ) as { session_id: string; aal: string };
    if (claims.session_id !== identity.session || claims.aal !== 'aal2')
      throw new ForbiddenException();
    await this.db.query(
      "update bank.authenticator_setup set state='ready' where customer_id=$1 and request_id=$2 and state='verifying'",
      [req.user.id, row.request_id],
    );
    return {
      accessToken: pair.access_token,
      refreshToken: pair.refresh_token,
      requestId: row.request_id,
      revision: row.revision,
    };
  }
}
