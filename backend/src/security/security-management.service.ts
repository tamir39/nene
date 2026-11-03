import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  ServiceUnavailableException,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { DatabaseService } from '../database/database.service.js';
import { uuid } from '../customers/customer.validation.js';
import { SecurityService } from './security.service.js';
import { reserveSecurityProof } from './security-proof.js';

type Management = {
  id: string;
  customer_id: string;
  session_id: string;
  revision: number;
  purpose: 'replace' | 'recover' | 'codes';
  step: string;
  old_factor_id: string;
  new_factor_id: string | null;
  lease_id: string;
  attempts: number;
  expires_at: Date;
};
type Factor = {
  id: string;
  factor_type: string;
  status: string;
  friendly_name?: string;
};
function input(body: unknown, keys: string[]) {
  if (
    !body ||
    typeof body !== 'object' ||
    Array.isArray(body) ||
    Object.keys(body).length !== keys.length ||
    keys.some((k) => !Object.hasOwn(body, k))
  )
    throw new BadRequestException();
  return body as Record<string, unknown>;
}
function proof(value: unknown, recovery = false) {
  if (
    typeof value !== 'string' ||
    !(recovery ? /^[A-Za-z0-9-]{8,128}$/ : /^\d{6}$/).test(value)
  )
    throw new BadRequestException('Enter the requested security code.');
  return recovery ? value.replaceAll('-', '').toUpperCase() : value;
}
@Injectable()
export class SecurityManagementService {
  constructor(
    private readonly db: DatabaseService,
    private readonly security: SecurityService,
  ) {}
  private fresh(identity: ReturnType<SecurityService['identity']>) {
    const now = Date.now() / 1000;
    if (
      !Number.isFinite(identity.passwordAt) ||
      identity.passwordAt < now - 300 ||
      identity.passwordAt > now + 30
    )
      throw new ForbiddenException(
        'Sign out and sign in again before changing security.',
      );
  }
  private async inventory(token: string, customer: string) {
    const data = await this.security.provider('/user', token);
    if (data.id !== customer || !Array.isArray(data.factors))
      throw new ServiceUnavailableException();
    return data.factors as Factor[];
  }
  private known(factors: Factor[], row: Management) {
    if (
      factors.some(
        (f) =>
          f.factor_type === 'totp' &&
          ![row.old_factor_id, row.new_factor_id].includes(f.id),
      )
    )
      throw new ConflictException(
        'Unexpected authenticator. Security needs attention.',
      );
  }
  private async row(customer: string, id: string) {
    const [row] = await this.db.query<Management>(
      'select * from bank.security_management where customer_id=$1 and id=$2',
      [customer, id],
    );
    if (!row) throw new ConflictException('Check security status.');
    return row;
  }
  private async reserve(
    req: AuthenticatedRequest,
    body: unknown,
    keys: string[],
    steps: string[],
    next: string,
    allowFreshSession = false,
    expectedLease?: string,
  ) {
    const identity = this.security.identity(req),
      data = input(body, keys),
      id = uuid(data.requestId, 'Request ID');
    if (allowFreshSession) this.fresh(identity);
    const [row] = await this.db.query<Management>(
      `update bank.security_management set step=$4,lease_id=gen_random_uuid() where customer_id=$1 and id=$2 and ($5::boolean or session_id=$3) and step=any($6::text[]) and ($5::boolean or expires_at>now()) and ($7::uuid is null or lease_id=$7) returning *`,
      [
        req.user.id,
        id,
        identity.session,
        next,
        allowFreshSession,
        steps,
        expectedLease ?? null,
      ],
    );
    if (!row)
      throw new ConflictException('Check security status before continuing.');
    return { identity, data, row };
  }
  private async change(row: Management, from: string, to: string) {
    const result = await this.db.query(
      'update bank.security_management set step=$3 where id=$1 and step=$2 and lease_id=$4 returning id',
      [row.id, from, to, row.lease_id],
    );
    if (!result.length)
      throw new ServiceUnavailableException(
        'Security change needs reconciliation.',
      );
  }
  private async pair(
    identity: ReturnType<SecurityService['identity']>,
    customer: string,
    factor: string,
    code: string,
    recovery = false,
  ) {
    let pair: Record<string, unknown>;
    if (recovery)
      pair = await this.security.provider(
        '/factors/recovery-codes/verify',
        identity.token,
        { code },
      );
    else {
      const challenge = await this.security.provider(
        `/factors/${factor}/challenge`,
        identity.token,
        {},
      );
      if (typeof challenge.id !== 'string')
        throw new ServiceUnavailableException();
      pair = await this.security.provider(
        `/factors/${factor}/verify`,
        identity.token,
        { challenge_id: challenge.id, code },
      );
    }
    if (
      typeof pair.access_token !== 'string' ||
      typeof pair.refresh_token !== 'string'
    )
      throw new ServiceUnavailableException();
    const factors = await this.inventory(pair.access_token, customer);
    try {
      const claims = JSON.parse(
        Buffer.from(pair.access_token.split('.')[1]!, 'base64url').toString(),
      ) as { sub: string; session_id: string; aal: string };
      if (
        claims.sub !== customer ||
        claims.session_id !== identity.session ||
        claims.aal !== 'aal2' ||
        (!recovery &&
          !factors.some((f) => f.id === factor && f.status === 'verified'))
      )
        throw new Error();
    } catch {
      throw new ServiceUnavailableException();
    }
    return { accessToken: pair.access_token, refreshToken: pair.refresh_token };
  }
  private reply(
    row: Management,
    pair: { accessToken: string; refreshToken: string },
    purpose: string,
  ) {
    return { ...pair, requestId: row.id, revision: row.revision, purpose };
  }
  async status(req: AuthenticatedRequest) {
    const identity = this.security.identity(req);
    const [row] = await this.db.query<Management>(
      "select * from bank.security_management where customer_id=$1 and step not in ('completed','cancelled')",
      [req.user.id],
    );
    const codes = await this.security.provider(
      '/factors/recovery-codes',
      identity.token,
    );
    const remaining = typeof codes.remaining === 'number' ? codes.remaining : 0;
    if (!row) return { remaining, management: null };
    const factors = await this.inventory(identity.token, req.user.id);
    this.known(factors, row);
    const newVerified =
      !!row.new_factor_id &&
      factors.some(
        (f) => f.id === row.new_factor_id && f.status === 'verified',
      );
    const canResume =
      ['proof', 'authorized', 'pending', 'verified', 'codes_shown'].includes(
        row.step,
      ) ||
      (row.step === 'verifying' && newVerified);
    return {
      remaining,
      management: {
        requestId: row.id,
        revision: row.revision,
        purpose: row.purpose,
        step: row.step,
        expiresAt: row.expires_at,
        sameSession: row.session_id === identity.session,
        expired: row.expires_at <= new Date(),
        canResume,
        proofKind: newVerified
          ? 'new_authenticator'
          : row.purpose === 'recover'
            ? 'recovery_code'
            : 'current_authenticator',
      },
    };
  }
  async start(req: AuthenticatedRequest, body: unknown) {
    const identity = this.security.identity(req);
    this.fresh(identity);
    const data = input(body, ['purpose']);
    if (!['replace', 'recover', 'codes'].includes(String(data.purpose)))
      throw new BadRequestException();
    const factors = await this.inventory(identity.token, req.user.id);
    return this.db.transaction(async (client) => {
      const found = await client.query<{
        factor_id: string;
        state: string;
        revision: number;
        security_not_before: Date;
      }>(
        'select * from bank.authenticator_setup where customer_id=$1 for update',
        [req.user.id],
      );
      const binding = found.rows[0];
      if (
        !binding ||
        binding.state !== 'ready' ||
        identity.passwordAt < binding.security_not_before.getTime() / 1000 ||
        !factors.some(
          (f) => f.id === binding.factor_id && f.status === 'verified',
        ) ||
        factors.some(
          (f) => f.factor_type === 'totp' && f.id !== binding.factor_id,
        )
      )
        throw new ConflictException(
          'A ready registered authenticator and a fresh sign-in are required.',
        );
      const id = randomUUID(),
        revision = binding.revision + 1;
      const step = data.purpose === 'codes' ? 'verified' : 'proof';
      await client.query(
        'insert into bank.security_management(id,customer_id,session_id,revision,purpose,step,old_factor_id) values($1,$2,$3,$4,$5,$7,$6)',
        [
          id,
          req.user.id,
          identity.session,
          revision,
          data.purpose,
          binding.factor_id,
          step,
        ],
      );
      await client.query(
        "update bank.authenticator_setup set state='restricted',revision=$2 where customer_id=$1",
        [req.user.id, revision],
      );
      return { requestId: id, revision, purpose: data.purpose, step };
    });
  }
  async prove(req: AuthenticatedRequest, body: unknown, resume = false) {
    const data = input(body, ['requestId', 'code']),
      identity = this.security.identity(req);
    const original = await this.row(
      req.user.id,
      uuid(data.requestId, 'Request ID'),
    );
    let useNew = false;
    if (resume) {
      this.fresh(identity);
      const factors = await this.inventory(identity.token, req.user.id);
      this.known(factors, original);
      useNew =
        !!original.new_factor_id &&
        factors.some(
          (f) => f.id === original.new_factor_id && f.status === 'verified',
        );
    }
    const recovery = original.purpose === 'recover' && !useNew,
      code = proof(data.code, recovery),
      factor = useNew ? original.new_factor_id! : original.old_factor_id;
    const scope = recovery ? 'recovery' : factor;
    const resumable = [
      'proof',
      'authorized',
      'pending',
      'verified',
      'codes_shown',
      ...(useNew ? ['verifying'] : []),
    ];
    const { row } = await this.reserve(
      req,
      body,
      ['requestId', 'code'],
      resume ? resumable : ['proof'],
      'proving',
      resume,
      original.lease_id,
    );
    try {
      await reserveSecurityProof(
        this.db,
        req.user.id,
        scope,
        code,
        'manage-' + (resume ? 'resume' : row.purpose),
      );
      const attempt = await this.db.query(
        'update bank.security_management set attempts=attempts+1 where id=$1 and attempts<5 returning id',
        [row.id],
      );
      if (!attempt.length)
        throw new BadRequestException(
          'Too many codes. Security change needs attention.',
        );
    } catch (error) {
      await this.change(row, 'proving', original.step);
      throw error;
    }
    let pair;
    try {
      pair = await this.pair(identity, req.user.id, factor, code, recovery);
    } catch (error) {
      if (error instanceof BadRequestException)
        await this.change(row, 'proving', original.step);
      throw error;
    }
    const next = useNew
      ? 'verified'
      : original.step === 'pending'
        ? 'pending'
        : row.purpose === 'codes'
          ? 'verified'
          : 'authorized';
    const [updated] = await this.db.query<Management>(
      "update bank.security_management set step=$2,session_id=$3,expires_at=now()+interval '10 minutes',revision=revision+$4 where id=$1 and step='proving' and lease_id=$5 returning *",
      [row.id, next, identity.session, resume ? 1 : 0, row.lease_id],
    );
    if (!updated) throw new ServiceUnavailableException();
    await this.db.query(
      "update bank.authenticator_setup set revision=$2 where customer_id=$1 and state='restricted'",
      [req.user.id, updated.revision],
    );
    // Resume's handoff is bound to the pre-command revision; subsequent commands use status's revision.
    return this.reply(row, pair, resume ? 'manage-resume' : 'manage-proof');
  }
  async enroll(req: AuthenticatedRequest, body: unknown) {
    const { identity, row } = await this.reserve(
      req,
      body,
      ['requestId'],
      ['authorized'],
      'enrolling',
    );
    const factors = await this.inventory(identity.token, req.user.id);
    this.known(factors, row);
    if (
      row.purpose === 'codes' ||
      !factors.some(
        (f) => f.id === row.old_factor_id && f.status === 'verified',
      )
    )
      throw new ConflictException();
    const enrolled = await this.security.provider('/factors', identity.token, {
      factor_type: 'totp',
      friendly_name: 'Nene ' + row.id,
      issuer: 'Nene',
    });
    const secret = (enrolled.totp as { secret?: unknown } | undefined)?.secret;
    if (
      typeof enrolled.id !== 'string' ||
      typeof secret !== 'string' ||
      !/^[A-Z2-7]{16,128}$/.test(secret)
    )
      throw new ServiceUnavailableException();
    const changed = await this.db.query(
      "update bank.security_management set new_factor_id=$2,step='pending' where id=$1 and step='enrolling' and lease_id=$3 returning id",
      [row.id, enrolled.id, row.lease_id],
    );
    if (!changed.length) throw new ServiceUnavailableException();
    return { requestId: row.id, revision: row.revision, secret };
  }
  async verify(req: AuthenticatedRequest, body: unknown) {
    const data = input(body, ['requestId', 'code']),
      code = proof(data.code);
    const { identity, row } = await this.reserve(
      req,
      body,
      ['requestId', 'code'],
      ['pending'],
      'verifying',
    );
    if (!row.new_factor_id) throw new ConflictException();
    try {
      await reserveSecurityProof(
        this.db,
        req.user.id,
        row.new_factor_id,
        code,
        'manage-new',
      );
    } catch (error) {
      await this.change(row, 'verifying', 'pending');
      throw error;
    }
    const attempts = await this.db.query(
      'update bank.security_management set attempts=attempts+1 where id=$1 and attempts<5 returning id',
      [row.id],
    );
    if (!attempts.length) {
      await this.change(row, 'verifying', 'pending');
      throw new BadRequestException(
        'Too many codes. Security change needs attention.',
      );
    }
    let pair;
    try {
      pair = await this.pair(identity, req.user.id, row.new_factor_id, code);
    } catch (error) {
      if (error instanceof BadRequestException)
        await this.change(row, 'verifying', 'pending');
      throw error;
    }
    await this.change(row, 'verifying', 'verified');
    return this.reply(row, pair, 'manage-new');
  }
  async issue(req: AuthenticatedRequest, body: unknown) {
    const data = input(body, ['requestId', 'code']),
      code = proof(data.code);
    const { identity, row } = await this.reserve(
      req,
      body,
      ['requestId', 'code'],
      ['verified'],
      'issuing',
    );
    const factor =
      row.purpose === 'codes' ? row.old_factor_id : row.new_factor_id;
    if (!factor) throw new ConflictException();
    try {
      await reserveSecurityProof(
        this.db,
        req.user.id,
        factor,
        code,
        'manage-issue',
      );
    } catch (error) {
      await this.change(row, 'issuing', 'verified');
      throw error;
    }
    let pair;
    try {
      pair = await this.pair(identity, req.user.id, factor, code);
    } catch (error) {
      if (error instanceof BadRequestException)
        await this.change(row, 'issuing', 'verified');
      throw error;
    }
    // From here every failure is uncertain: never return a definite no-rotation error.
    try {
      let factors = await this.inventory(pair.accessToken, req.user.id);
      this.known(factors, row);
      if (
        row.purpose !== 'codes' &&
        factors.some((f) => f.id === row.old_factor_id)
      )
        await this.security.provider(
          `/factors/${row.old_factor_id}`,
          pair.accessToken,
          undefined,
          'DELETE',
        );
      factors = await this.inventory(pair.accessToken, req.user.id);
      if (
        !factors.some((f) => f.id === factor && f.status === 'verified') ||
        (row.purpose !== 'codes' &&
          factors.some((f) => f.id === row.old_factor_id))
      )
        throw new Error();
      const status = await this.security.provider(
        '/factors/recovery-codes',
        pair.accessToken,
      );
      const result = await this.security.provider(
        typeof status.id === 'string'
          ? '/factors/recovery-codes/regenerate'
          : '/factors/recovery-codes',
        pair.accessToken,
        {},
      );
      if (
        !Array.isArray(result.codes) ||
        !result.codes.length ||
        result.codes.some((c) => typeof c !== 'string' || c.length > 128)
      )
        throw new Error();
      await this.change(row, 'issuing', 'codes_shown');
      return { ...this.reply(row, pair, 'manage-issue'), codes: result.codes };
    } catch {
      throw new ServiceUnavailableException(
        'Recovery code issuance needs attention. Check status; do not repeat the request.',
      );
    }
  }
  async finish(req: AuthenticatedRequest, body: unknown) {
    const data = input(body, ['requestId', 'saved']);
    if (data.saved !== true)
      throw new BadRequestException(
        'Confirm that your new recovery codes are saved.',
      );
    const identity = this.security.identity(req),
      existing = await this.row(
        req.user.id,
        uuid(data.requestId, 'Request ID'),
      );
    const resumeFinish = existing.step === 'finishing';
    const { row } = await this.reserve(
      req,
      body,
      ['requestId', 'saved'],
      resumeFinish ? ['finishing'] : ['codes_shown'],
      'finishing',
      resumeFinish,
      existing.lease_id,
    );
    const factor =
      row.purpose === 'codes' ? row.old_factor_id : row.new_factor_id;
    const factors = await this.inventory(identity.token, req.user.id);
    this.known(factors, row);
    if (
      !factor ||
      !factors.some((f) => f.id === factor && f.status === 'verified') ||
      (row.purpose !== 'codes' &&
        factors.some((f) => f.id === row.old_factor_id))
    )
      throw new ConflictException();
    const codes = await this.security.provider(
      '/factors/recovery-codes',
      identity.token,
    );
    if (typeof codes.remaining !== 'number' || codes.remaining < 1)
      throw new ConflictException('Saved recovery codes are required.');
    await this.security.provider('/logout?scope=global', identity.token, {});
    await this.db.transaction(async (client) => {
      const locked = await client.query(
        "select id from bank.security_management where id=$1 and step='finishing' and lease_id=$2 for update",
        [row.id, row.lease_id],
      );
      if (!locked.rows.length) throw new ConflictException();
      await client.query(
        "update bank.authenticator_setup set factor_id=$2,state='ready',revision=$3,security_not_before=clock_timestamp() where customer_id=$1",
        [req.user.id, factor, row.revision],
      );
      await client.query(
        "update bank.security_management set step='completed' where id=$1",
        [row.id],
      );
    });
    return { signedOut: true };
  }
  async cancel(req: AuthenticatedRequest, body: unknown) {
    const { identity, row } = await this.reserve(
      req,
      body,
      ['requestId'],
      ['proof', 'authorized', 'pending', 'cancelling'],
      'cancelling',
      true,
    );
    const factors = await this.inventory(identity.token, req.user.id);
    this.known(factors, row);
    const pending = factors.find((f) => f.id === row.new_factor_id);
    if (
      pending?.status === 'verified' ||
      !factors.some(
        (f) => f.id === row.old_factor_id && f.status === 'verified',
      )
    )
      throw new ConflictException('Verified replacement cannot be cancelled.');
    if (pending)
      await this.security.provider(
        `/factors/${pending.id}`,
        identity.token,
        undefined,
        'DELETE',
      );
    const after = await this.inventory(identity.token, req.user.id);
    if (
      after.some((f) => f.id === row.new_factor_id) ||
      !after.some((f) => f.id === row.old_factor_id && f.status === 'verified')
    )
      throw new ServiceUnavailableException();
    await this.db.transaction(async (client) => {
      const changed = await client.query(
        "update bank.security_management set step='cancelled' where id=$1 and step='cancelling' and lease_id=$2 returning id",
        [row.id, row.lease_id],
      );
      if (!changed.rows.length) throw new ConflictException();
      await client.query(
        "update bank.authenticator_setup set state='ready',security_not_before=clock_timestamp() where customer_id=$1 and state='restricted'",
        [req.user.id],
      );
    });
    return { cancelled: true };
  }
}
