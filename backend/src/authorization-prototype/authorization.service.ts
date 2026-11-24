import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  HttpException,
  Injectable,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { createHash, createHmac, randomUUID } from 'node:crypto';
import type { Pool, PoolClient, QueryResultRow } from 'pg';
import type { FactorVerifier, VerificationResult } from './factor-verifier.js';

// Unregistered experimental service. The caller must supply a server-verified
// actor. There are no HTTP routes, bank tables, balance writes or production DI.
export interface PrototypeActor {
  id: string;
  accessToken: string;
}
interface Principal extends QueryResultRow {
  id: string;
  role: string;
  active: boolean;
  eligible: boolean;
  factor_id: string;
  policy_revision: number;
}
interface Operation extends QueryResultRow {
  id: string;
  owner_id: string;
  version: number;
  source_id: string;
  destination_id: string;
  amount_minor: string;
  currency: string;
  policy_revision: number;
  requires_identity_comparison: boolean;
  current: boolean;
  state: string;
  authorization_id: string | null;
  authorization_attempt_id: string | null;
  authorization_current: boolean;
  receipt_id: string | null;
  receipt_request_key: string | null;
}
interface Attempt extends QueryResultRow {
  id: string;
  operation_id: string;
  owner_id: string;
  operation_version: number;
  details_digest: string;
  policy_revision: number;
  factor_id: string;
  request_key: string;
  challenge_id: string | null;
  proof_digest: string | null;
  state: string;
  current: boolean;
}
export interface PrototypeResult {
  operationId: string;
  version: number;
  state: string;
  authorizationUsable: boolean;
  attemptId?: string;
  attemptState?: string;
  authorizationId?: string;
  syntheticReceiptId?: string;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function uuid(value: string): void {
  if (typeof value !== 'string' || !uuidPattern.test(value))
    throw new BadRequestException('Invalid identifier.');
}
function version(value: number): void {
  if (!Number.isSafeInteger(value) || value < 1)
    throw new BadRequestException('Invalid operation version.');
}
function details(op: Operation): string {
  return createHash('sha256')
    .update(
      JSON.stringify([
        op.id,
        op.owner_id,
        op.version,
        op.source_id,
        op.destination_id,
        op.amount_minor,
        op.currency,
        op.policy_revision,
        op.requires_identity_comparison,
      ]),
    )
    .digest('hex');
}

@Injectable()
export class AuthorizationPrototypeService {
  private readonly key: Buffer;
  private readonly keyId: string;
  constructor(
    private readonly pool: Pool,
    private readonly verifier: FactorVerifier,
    key: Buffer,
  ) {
    if (!Buffer.isBuffer(key) || key.length !== 32)
      throw new Error('A 32-byte prototype fingerprint key is required.');
    this.key = Buffer.from(key);
    this.keyId = createHash('sha256').update(this.key).digest('hex');
  }

  private async tx<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect().catch(() => {
      throw new ServiceUnavailableException('Prototype data unavailable.');
    });
    try {
      await client.query('begin');
      await client.query("set local lock_timeout = '3s'");
      await client.query("set local statement_timeout = '5s'");
      await client.query(
        'insert into authorization_prototype.settings(singleton,fingerprint_key_id) values(true,$1) on conflict do nothing',
        [this.keyId],
      );
      const config = await client.query<{ fingerprint_key_id: string }>(
        'select fingerprint_key_id from authorization_prototype.settings where singleton',
      );
      if (config.rows[0]?.fingerprint_key_id !== this.keyId)
        throw new ServiceUnavailableException(
          'Prototype fingerprint key changed.',
        );
      const result = await work(client);
      await client.query('commit');
      return result;
    } catch (error) {
      await client.query('rollback').catch(() => undefined);
      if (error instanceof HttpException) throw error;
      throw new ServiceUnavailableException(
        'Prototype data unavailable; check existing status.',
      );
    } finally {
      client.release();
    }
  }

  private async load(
    client: PoolClient,
    actor: PrototypeActor,
    id: string,
    expected: number,
  ): Promise<[Principal, Operation]> {
    uuid(actor.id);
    uuid(id);
    version(expected);
    const principal = (
      await client.query<Principal>(
        'select * from authorization_prototype.principals where id=$1 for update',
        [actor.id],
      )
    ).rows[0];
    if (!principal || principal.role !== 'customer' || !principal.active)
      throw new ForbiddenException('An active customer is required.');
    const op = (
      await client.query<Operation>(
        `select *, expires_at > clock_timestamp() as current,
      authorized_until > clock_timestamp() as authorization_current
      from authorization_prototype.operations where id=$1 and owner_id=$2 for update`,
        [id, actor.id],
      )
    ).rows[0];
    if (!op) throw new NotFoundException('Operation not found.');
    if (op.version !== expected)
      throw new ConflictException('Review the changed operation.');
    return [principal, op];
  }

  private eligible(principal: Principal, op: Operation): boolean {
    return (
      principal.eligible &&
      op.current &&
      !op.requires_identity_comparison &&
      op.policy_revision === principal.policy_revision
    );
  }

  private async attempt(
    client: PoolClient,
    actor: PrototypeActor,
    op: Operation,
    id: string,
  ): Promise<Attempt> {
    uuid(id);
    const attempt = (
      await client.query<Attempt>(
        `select *, deadline > clock_timestamp() as current
      from authorization_prototype.attempts where id=$1 and owner_id=$2 and operation_id=$3 for update`,
        [id, actor.id, op.id],
      )
    ).rows[0];
    if (!attempt) throw new NotFoundException('Attempt not found.');
    return attempt;
  }

  private bound(
    principal: Principal,
    op: Operation,
    attempt: Attempt,
  ): boolean {
    return (
      this.eligible(principal, op) &&
      attempt.current &&
      op.version === attempt.operation_version &&
      details(op) === attempt.details_digest &&
      principal.factor_id === attempt.factor_id &&
      principal.policy_revision === attempt.policy_revision
    );
  }

  private usable(
    principal: Principal,
    op: Operation,
    attempt?: Attempt,
  ): boolean {
    return (
      op.state === 'authorized' &&
      this.eligible(principal, op) &&
      op.authorization_current &&
      !!attempt &&
      attempt.id === op.authorization_attempt_id &&
      attempt.state === 'verified' &&
      attempt.details_digest === details(op) &&
      attempt.operation_version === op.version &&
      attempt.factor_id === principal.factor_id &&
      attempt.policy_revision === principal.policy_revision
    );
  }

  private result(
    op: Operation,
    attempt?: Attempt,
    usable = false,
  ): PrototypeResult {
    return {
      operationId: op.id,
      version: op.version,
      state: op.state,
      authorizationUsable: Boolean(usable),
      ...(attempt
        ? { attemptId: attempt.id, attemptState: attempt.state }
        : {}),
      ...(usable && op.authorization_id
        ? { authorizationId: op.authorization_id }
        : {}),
      ...(op.receipt_id ? { syntheticReceiptId: op.receipt_id } : {}),
    };
  }

  async status(
    actor: PrototypeActor,
    id: string,
    expected: number,
  ): Promise<PrototypeResult> {
    return this.tx(async (client) => {
      const [principal, op] = await this.load(client, actor, id, expected);
      const attempt = op.authorization_attempt_id
        ? await this.attempt(client, actor, op, op.authorization_attempt_id)
        : undefined;
      return this.result(op, undefined, this.usable(principal, op, attempt));
    });
  }

  async prepare(
    actor: PrototypeActor,
    id: string,
    expected: number,
    requestKey: string,
  ): Promise<PrototypeResult> {
    uuid(requestKey);
    const reservation = await this.tx(async (client) => {
      const [principal, op] = await this.load(client, actor, id, expected);
      const prior = (
        await client.query<Attempt>(
          `select *, deadline > clock_timestamp() as current
        from authorization_prototype.attempts where owner_id=$1 and request_key=$2`,
          [actor.id, requestKey],
        )
      ).rows[0];
      if (prior) {
        if (
          prior.operation_id !== id ||
          prior.operation_version !== expected ||
          prior.details_digest !== details(op)
        )
          throw new ConflictException(
            'Request key belongs to other reviewed details.',
          );
        return { op, attempt: prior, call: false };
      }
      if (
        !this.eligible(principal, op) ||
        op.state !== 'awaiting_authorization'
      )
        throw new ConflictException('Operation cannot be authorized.');
      const live = await client.query(
        `select id from authorization_prototype.attempts where operation_id=$1
        and state in ('challenge_pending','ready','verifying') and deadline > clock_timestamp()`,
        [id],
      );
      if (live.rowCount)
        throw new ConflictException('An attempt is already active.');
      const budgets = (
        await client.query<{ per_operation: number; per_customer: number }>(
          `select
        count(*) filter(where operation_id=$2)::integer as per_operation,
        count(*) filter(where created_at > clock_timestamp() - interval '15 minutes')::integer as per_customer
        from authorization_prototype.attempts where owner_id=$1`,
          [actor.id, id],
        )
      ).rows[0]!;
      if (budgets.per_operation >= 5 || budgets.per_customer >= 10)
        throw new HttpException('Prototype attempt limit reached.', 429);
      await client.query(
        `update authorization_prototype.attempts set state='superseded'
        where operation_id=$1 and state in ('challenge_pending','ready','verifying','unknown')`,
        [id],
      );
      const attempt = (
        await client.query<Attempt>(
          `insert into authorization_prototype.attempts
        (id,operation_id,owner_id,operation_version,details_digest,policy_revision,factor_id,request_key,state)
        values($1,$2,$3,$4,$5,$6,$7,$8,'challenge_pending') returning *, true as current`,
          [
            randomUUID(),
            id,
            actor.id,
            expected,
            details(op),
            principal.policy_revision,
            principal.factor_id,
            requestKey,
          ],
        )
      ).rows[0]!;
      return { op, attempt, call: true };
    });
    if (!reservation.call)
      return this.result(reservation.op, reservation.attempt);
    let challengeId: string | undefined;
    try {
      challengeId = (
        await this.verifier.challenge(
          actor.accessToken,
          reservation.attempt.factor_id,
        )
      ).challengeId;
      uuid(challengeId);
    } catch {
      challengeId = undefined;
    }
    return this.tx(async (client) => {
      const [principal, op] = await this.load(client, actor, id, expected);
      const attempt = await this.attempt(
        client,
        actor,
        op,
        reservation.attempt.id,
      );
      if (attempt.state !== 'challenge_pending')
        return this.result(op, attempt);
      const state =
        this.bound(principal, op, attempt) &&
        op.state === 'awaiting_authorization'
          ? challengeId
            ? 'ready'
            : 'unknown'
          : 'superseded';
      await client.query(
        'update authorization_prototype.attempts set state=$2, challenge_id=$3 where id=$1',
        [attempt.id, state, state === 'ready' ? challengeId : null],
      );
      attempt.state = state;
      return this.result(op, attempt);
    });
  }

  async confirm(
    actor: PrototypeActor,
    id: string,
    expected: number,
    attemptId: string,
    code: string,
  ): Promise<PrototypeResult> {
    if (typeof code !== 'string' || !/^\d{6}$/.test(code))
      throw new BadRequestException('Enter a six-digit code.');
    const reservation = await this.tx(async (client) => {
      const [principal, op] = await this.load(client, actor, id, expected);
      const attempt = await this.attempt(client, actor, op, attemptId);
      const digest = createHmac('sha256', this.key)
        .update(
          JSON.stringify([
            'nene-authz-prototype-v1',
            principal.id,
            attempt.factor_id,
            code,
          ]),
        )
        .digest('hex');
      if (attempt.proof_digest) {
        if (
          attempt.operation_version !== expected ||
          attempt.details_digest !== details(op)
        )
          throw new ConflictException('Reviewed details changed.');
        if (attempt.proof_digest !== digest)
          throw new ConflictException(
            'Attempt proof changed; use the reviewed retry flow.',
          );
        if (attempt.state === 'verifying' && !attempt.current) {
          await client.query(
            "update authorization_prototype.attempts set state='unknown' where id=$1",
            [attempt.id],
          );
          attempt.state = 'unknown';
        }
        return { op, attempt, principal, call: false };
      }
      if (
        op.state !== 'awaiting_authorization' ||
        attempt.state !== 'ready' ||
        !attempt.challenge_id ||
        !this.bound(principal, op, attempt)
      )
        throw new ConflictException(
          'Attempt is unavailable or details changed.',
        );
      await client.query(
        'delete from authorization_prototype.proof_claims where owner_id=$1 and expires_at <= clock_timestamp()',
        [actor.id],
      );
      const claim = await client.query(
        `insert into authorization_prototype.proof_claims(owner_id,factor_id,proof_digest)
        values($1,$2,$3) on conflict do nothing`,
        [actor.id, attempt.factor_id, digest],
      );
      if (!claim.rowCount)
        throw new ConflictException(
          'Code already reserved; wait for a fresh code.',
        );
      await client.query(
        `update authorization_prototype.attempts set proof_digest=$2,state='verifying',
        deadline=clock_timestamp()+interval '30 seconds' where id=$1`,
        [attempt.id, digest],
      );
      attempt.proof_digest = digest;
      attempt.state = 'verifying';
      return { op, attempt, principal, call: true };
    });
    if (!reservation.call)
      return this.result(
        reservation.op,
        reservation.attempt,
        this.usable(reservation.principal, reservation.op, reservation.attempt),
      );
    let proof: VerificationResult;
    try {
      proof = await this.verifier.verify(
        actor.accessToken,
        reservation.attempt.factor_id,
        reservation.attempt.challenge_id!,
        code,
      );
    } catch {
      proof = { status: 'unknown' };
    }
    return this.tx(async (client) => {
      const [principal, op] = await this.load(client, actor, id, expected);
      const attempt = await this.attempt(client, actor, op, attemptId);
      if (attempt.state !== 'verifying')
        return this.result(op, attempt, this.usable(principal, op, attempt));
      const state =
        !this.bound(principal, op, attempt) ||
        op.state !== 'awaiting_authorization'
          ? 'superseded'
          : proof.status === 'verified' && proof.userId === principal.id
            ? 'verified'
            : proof.status === 'rejected'
              ? 'rejected'
              : 'unknown';
      await client.query(
        'update authorization_prototype.attempts set state=$2 where id=$1',
        [attempt.id, state],
      );
      attempt.state = state;
      if (state === 'verified') {
        const updated = await client.query<Operation>(
          `update authorization_prototype.operations
          set state='authorized',authorization_id=$2,authorization_attempt_id=$3,
          authorized_until=least(expires_at,clock_timestamp()+interval '2 minutes')
          where id=$1 and expires_at > clock_timestamp()
          and exists(select 1 from authorization_prototype.attempts where id=$3 and state='verified' and deadline > clock_timestamp())
          returning *, expires_at > clock_timestamp() as current,
          authorized_until > clock_timestamp() as authorization_current`,
          [id, randomUUID(), attemptId],
        );
        if (updated.rowCount) Object.assign(op, updated.rows[0]);
        else {
          await client.query(
            "update authorization_prototype.attempts set state='superseded' where id=$1",
            [attempt.id],
          );
          attempt.state = 'superseded';
        }
      }
      return this.result(op, attempt, this.usable(principal, op, attempt));
    });
  }

  async cancel(
    actor: PrototypeActor,
    id: string,
    expected: number,
  ): Promise<PrototypeResult> {
    return this.tx(async (client) => {
      const [, op] = await this.load(client, actor, id, expected);
      if (op.state === 'consumed')
        throw new ConflictException('Synthetic receipt already consumed.');
      await client.query(
        "update authorization_prototype.operations set state='cancelled' where id=$1",
        [id],
      );
      await client.query(
        `update authorization_prototype.attempts set state='superseded'
        where operation_id=$1 and state in ('challenge_pending','ready','verifying','verified','unknown')`,
        [id],
      );
      op.state = 'cancelled';
      return this.result(op);
    });
  }

  async consume(
    actor: PrototypeActor,
    id: string,
    expected: number,
    authorizationId: string,
    requestKey: string,
  ): Promise<PrototypeResult> {
    uuid(authorizationId);
    uuid(requestKey);
    return this.tx(async (client) => {
      const [principal, op] = await this.load(client, actor, id, expected);
      if (op.authorization_id !== authorizationId)
        throw new ConflictException(
          'Authorization does not match this operation.',
        );
      if (!op.authorization_attempt_id)
        throw new ConflictException('Authorization unavailable.');
      const attempt = await this.attempt(
        client,
        actor,
        op,
        op.authorization_attempt_id,
      );
      if (
        attempt.details_digest !== details(op) ||
        attempt.operation_version !== expected
      )
        throw new ConflictException('Authorization details changed.');
      if (op.state === 'consumed') {
        if (op.receipt_request_key !== requestKey)
          throw new ConflictException('Authorization already consumed.');
        return this.result(op);
      }
      if (
        op.state !== 'authorized' ||
        !this.eligible(principal, op) ||
        !op.authorization_current ||
        !op.authorization_attempt_id
      )
        throw new ConflictException('Authorization unavailable.');
      if (
        attempt.state !== 'verified' ||
        attempt.details_digest !== details(op) ||
        attempt.factor_id !== principal.factor_id
      )
        throw new ConflictException('Authorization details changed.');
      const receiptId = randomUUID();
      const consumed = await client.query(
        "update authorization_prototype.operations set state='consumed',receipt_id=$2,receipt_request_key=$3 where id=$1 and state='authorized' and expires_at > clock_timestamp() and authorized_until > clock_timestamp() returning id",
        [id, receiptId, requestKey],
      );
      if (!consumed.rowCount)
        throw new ConflictException(
          'Authorization expired before consumption.',
        );
      op.state = 'consumed';
      op.receipt_id = receiptId;
      return this.result(op);
    });
  }
}
