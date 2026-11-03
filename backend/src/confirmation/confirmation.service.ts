import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Inject,
  Optional,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import type { PoolClient } from 'pg';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { DatabaseService } from '../database/database.service.js';
import { SecurityService } from '../security/security.service.js';
import { reserveSecurityProof } from '../security/security-proof.js';
import { uuid } from '../customers/customer.validation.js';
import { ENVIRONMENT } from '../config/config.module.js';
import type { Environment } from '../config/environment.js';

const policy = 'same-bank-confirmation-only-v1';
const transferPolicy = 'local-vnd-under-5000000-v1';
type Reference = {
  id: string;
  version: number;
  revision: number;
  evidence_id: string;
};
type Review = {
  id: string;
  customer: string;
  session: string;
  factor: string;
  revision: number;
  policy: string;
  source: string;
  sourceNumber: string;
  destination: string;
  destinationNumber: string;
  amountMinor: string;
  currency: 'VND';
  feeMinor: '0';
  expires: number;
  reference?: Reference;
};
type Account = {
  id: string;
  owner_id: string;
  number: string;
  type: string;
  currency: string;
  status: string;
  profile_status: string;
  balance: string;
};
type Binding = { factor_id: string; revision: number; state: string };
type Confirmation = {
  id: string;
  customer_id: string;
  session_id: string;
  review_digest: string;
  factor_id: string;
  security_revision: number;
  state: string;
  expires_at: Date;
  lease_until: Date;
  confirmed_until: Date | null;
  purpose: string;
};
export function exact(body: unknown, keys: string[]) {
  if (
    !body ||
    typeof body !== 'object' ||
    Array.isArray(body) ||
    Object.keys(body).length !== keys.length ||
    keys.some((k) => !Object.hasOwn(body, k))
  )
    throw new BadRequestException('Invalid confirmation fields.');
  return body as Record<string, unknown>;
}
export function transferInput(body: unknown) {
  const data = exact(body, [
    'sourceAccountId',
    'destinationAccountNumber',
    'amountMinor',
  ]);
  const source = uuid(data.sourceAccountId, 'Source account');
  if (
    typeof data.destinationAccountNumber !== 'string' ||
    !/^\d{12}$/.test(data.destinationAccountNumber) ||
    typeof data.amountMinor !== 'string' ||
    !/^[1-9]\d{0,15}$/.test(data.amountMinor) ||
    BigInt(data.amountMinor) > 9000000000000000n
  )
    throw new BadRequestException(
      'Enter a valid account number and positive whole VND amount.',
    );
  return {
    source,
    destinationNumber: data.destinationAccountNumber,
    amountMinor: data.amountMinor,
  };
}
@Injectable()
export class ConfirmationService {
  constructor(
    private readonly db: DatabaseService,
    private readonly security: SecurityService,
    @Optional() @Inject(ENVIRONMENT) private readonly env?: Environment,
  ) {}
  async configuration(req: AuthenticatedRequest) {
    this.security.identity(req);
    const enabled =
      this.env?.localTransfersEnabled === true &&
      this.env.nodeEnv !== 'production';
    const rows = enabled
      ? await this.db.query<{ enabled: boolean }>(
          'select enabled from bank.local_transfer_settings where id',
          [],
        )
      : [];
    return {
      enabled: enabled && rows[0]?.enabled === true,
      highValueThresholdMinor: '5000000',
      currency: 'VND',
    };
  }
  private async requireTransfers(req: AuthenticatedRequest) {
    if (!(await this.configuration(req)).enabled)
      throw new ConflictException('Local transfer demo is not enabled.');
  }
  private async reference(
    client: PoolClient,
    customer: string,
    expected?: Reference,
  ) {
    const result = await client.query<Reference>(
      "select i.id,i.version,i.revision,i.evidence_id from bank.identity_cases i join bank.identity_evidence e on e.id=i.evidence_id join bank.user_profiles p on p.id=i.customer_id where i.customer_id=$1 and i.state='reference_accepted' and i.profile_name=p.display_name and i.expires_at>clock_timestamp() and e.case_id=i.id and e.revision=i.revision and e.status='ready' and e.deleted_at is null and e.expires_at>clock_timestamp()",
      [customer],
    );
    const found = result.rows[0];
    if (
      !found ||
      (expected && JSON.stringify(found) !== JSON.stringify(expected))
    )
      throw new BadRequestException(
        'An unchanged, unexpired accepted reference is required.',
      );
    return found;
  }
  private async key() {
    return (
      await this.db.query<{ secret: string }>(
        'select secret from bank.security_proof_key where id',
        [],
      )
    )[0]!.secret;
  }
  private mac(key: string, text: string) {
    return createHmac('sha256', key)
      .update('nene-review-v1\0' + text)
      .digest('base64url');
  }
  private async decode(
    req: AuthenticatedRequest,
    raw: unknown,
    transfer = false,
  ) {
    const identity = this.security.identity(req);
    if (typeof raw !== 'string' || raw.length > 4096)
      throw new BadRequestException();
    const parts = raw.split('.'),
      key = await this.key();
    if (
      parts.length !== 2 ||
      !/^[A-Za-z0-9_-]+$/.test(parts[0]!) ||
      !/^[A-Za-z0-9_-]{43}$/.test(parts[1]!)
    )
      throw new BadRequestException();
    if (
      !timingSafeEqual(
        Buffer.from(this.mac(key, parts[0]!)),
        Buffer.from(parts[1]!),
      )
    )
      throw new BadRequestException('Review was changed. Review again.');
    let review: Review;
    try {
      review = JSON.parse(
        Buffer.from(parts[0]!, 'base64url').toString(),
      ) as Review;
    } catch {
      throw new BadRequestException();
    }
    if (review.customer !== req.user.id || review.session !== identity.session)
      throw new ForbiddenException('This review belongs to another sign-in.');
    if (review.policy !== (transfer ? transferPolicy : policy))
      throw new ConflictException('Review policy changed.');
    return { identity, review, digest: this.mac(key, raw) };
  }
  private async accounts(
    client: PoolClient,
    customer: string,
    source: string,
    destinationNumber: string,
  ) {
    const result = await client.query<Account>(
      `select a.id,a.owner_id,a.account_number::text number,a.type,a.currency,a.status,p.status profile_status,a.balance_minor::text balance from bank.banking_accounts a join bank.user_profiles p on p.id=a.owner_id where a.id=$1 or a.account_number=$2::bigint order by a.id`,
      [source, destinationNumber],
    );
    const from = result.rows.find(
        (a) => a.id === source && a.owner_id === customer,
      ),
      to = result.rows.find((a) => a.number === destinationNumber);
    if (
      !from ||
      !to ||
      from.id === to.id ||
      [from, to].some(
        (a) =>
          a.type !== 'checking' ||
          a.currency !== 'VND' ||
          a.status !== 'active' ||
          a.profile_status !== 'active',
      )
    )
      throw new BadRequestException(
        'Choose two different active VND checking accounts, with your own account as source.',
      );
    return { from, to };
  }
  private async binding(client: PoolClient, customer: string, review?: Review) {
    const result = await client.query<Binding>(
      'select factor_id,revision,state from bank.authenticator_setup where customer_id=$1 for update',
      [customer],
    );
    const b = result.rows[0];
    if (
      !b ||
      b.state !== 'ready' ||
      (review &&
        (b.factor_id !== review.factor || b.revision !== review.revision))
    )
      throw new ConflictException(
        'Authenticator changed or is restricted. Review again after completing security setup.',
      );
    return b;
  }
  private async activeProvider(
    token: string,
    customer: string,
    factor: string,
  ) {
    const data = await this.security.provider('/user', token);
    if (
      data.id !== customer ||
      !Array.isArray(data.factors) ||
      !data.factors.some(
        (f: { id: string; status: string; factor_type: string }) =>
          f.id === factor &&
          f.status === 'verified' &&
          f.factor_type === 'totp',
      )
    )
      throw new ConflictException('Registered authenticator is unavailable.');
  }
  async review(req: AuthenticatedRequest, body: unknown, transfer = false) {
    if (transfer) await this.requireTransfers(req);
    if (
      transfer &&
      (
        await this.db.query(
          "select id from bank.transaction_confirmations where customer_id=$1 and purpose='local_transfer' and state='checking' and lease_until>clock_timestamp() limit 1",
          [req.user.id],
        )
      ).length
    )
      throw new ConflictException(
        'Check the pending transfer before starting another.',
      );
    const identity = this.security.identity(req),
      input = transferInput(body),
      key = await this.key();
    const result = await this.db.transaction(async (client) => {
      const binding = await this.binding(client, req.user.id);
      const { from, to } = await this.accounts(
        client,
        req.user.id,
        input.source,
        input.destinationNumber,
      );
      const time = await client.query<{ expires: number }>(
        'select (extract(epoch from now())*1000+600000)::float8 expires',
      );
      const reference = transfer
        ? await this.reference(client, req.user.id)
        : undefined;
      if (
        transfer &&
        (BigInt(input.amountMinor) >= 5000000n ||
          BigInt(from.balance) < BigInt(input.amountMinor))
      )
        throw new BadRequestException(
          'Insufficient funds, or amount requires the unavailable high-value identity check.',
        );
      if (transfer) {
        const eligible = await client.query(
          "select a.id from bank.banking_accounts a join bank.user_profiles p on p.id=a.owner_id where a.id=any($1::uuid[]) and a.is_demo and p.email like '%@example.invalid'",
          [[from.id, to.id]],
        );
        if (eligible.rows.length !== 2)
          throw new BadRequestException(
            'Prepare both synthetic accounts with the local seed command first.',
          );
      }
      const review: Review = {
        id: randomUUID(),
        customer: req.user.id,
        session: identity.session,
        factor: binding.factor_id,
        revision: binding.revision,
        policy: transfer ? transferPolicy : policy,
        ...(reference ? { reference } : {}),
        source: from.id,
        sourceNumber: from.number,
        destination: to.id,
        destinationNumber: to.number,
        amountMinor: input.amountMinor,
        currency: 'VND',
        feeMinor: '0',
        expires: time.rows[0]!.expires,
      };
      const encoded = Buffer.from(JSON.stringify(review)).toString('base64url');
      return {
        reviewToken: encoded + '.' + this.mac(key, encoded),
        review,
        sufficientFunds: BigInt(from.balance) >= BigInt(input.amountMinor),
      };
    });
    await this.activeProvider(
      identity.token,
      req.user.id,
      result.review.factor,
    );
    return {
      reviewToken: result.reviewToken,
      requestId: result.review.id,
      revision: result.review.revision,
      sourceAccountNumber: result.review.sourceNumber,
      destinationAccountNumber: result.review.destinationNumber,
      amountMinor: result.review.amountMinor,
      currency: 'VND',
      feeMinor: '0',
      expiresAt: new Date(result.review.expires),
      sufficientFunds: result.sufficientFunds,
      executionAvailable: transfer,
      identityCheck: 'not_implemented',
    };
  }
  async status(req: AuthenticatedRequest, rawId: unknown, transfer = false) {
    const identity = this.security.identity(req),
      id = uuid(rawId, 'Confirmation ID');
    const [row] = await this.db.query<Confirmation>(
      'select * from bank.transaction_confirmations where id=$1 and customer_id=$2',
      [id, req.user.id],
    );
    if (!row) throw new NotFoundException();
    if (row.purpose !== (transfer ? 'local_transfer' : 'preview'))
      throw new NotFoundException();
    if (row.state === 'posted') {
      const [receipt] = await this.db.query(
        'select id,amount_minor::text as "amountMinor",currency,posted_at as "postedAt" from bank.local_transfers where id=$1 and customer_id=$2',
        [id, req.user.id],
      );
      if (!receipt) throw new ServiceUnavailableException();
      return {
        requestId: id,
        state: 'posted',
        sent: true,
        executionAvailable: true,
        receipt,
      };
    }
    const [binding] = await this.db.query<Binding>(
      'select state,factor_id,revision from bank.authenticator_setup where customer_id=$1',
      [req.user.id],
    );
    const now = Date.now();
    let state = row.state;
    if (state === 'checking' && row.lease_until.getTime() <= now)
      state = 'unknown';
    if (!['cancelled', 'rejected', 'unknown'].includes(state)) {
      if (
        row.expires_at.getTime() <= now ||
        (row.confirmed_until && row.confirmed_until.getTime() <= now)
      )
        state = 'expired';
      else if (
        (!transfer && identity.session !== row.session_id) ||
        binding?.state !== 'ready' ||
        binding.factor_id !== row.factor_id ||
        binding.revision !== row.security_revision
      )
        state = 'invalidated';
    }
    return { requestId: id, state, executionAvailable: false, sent: false };
  }
  async recent(req: AuthenticatedRequest) {
    this.security.identity(req);
    const rows = await this.db.query<{ id: string }>(
      "select id from bank.transaction_confirmations where customer_id=$1 and purpose='local_transfer' order by created_at desc,id desc limit 10",
      [req.user.id],
    );
    return {
      transfers: await Promise.all(
        rows.map((r) => this.status(req, r.id, true)),
      ),
    };
  }
  async confirm(req: AuthenticatedRequest, body: unknown, transfer = false) {
    if (transfer) await this.requireTransfers(req);
    const data = exact(body, ['reviewToken', 'code']);
    if (typeof data.code !== 'string' || !/^\d{6}$/.test(data.code))
      throw new BadRequestException('Enter a six-digit authenticator code.');
    const {
      identity,
      review: r,
      digest,
    } = await this.decode(req, data.reviewToken, transfer);
    const reserved = await this.db.transaction(async (client) => {
      await this.binding(client, req.user.id, r);
      const prior = await client.query<Confirmation>(
        'select * from bank.transaction_confirmations where id=$1 for update',
        [r.id],
      );
      if (prior.rows[0]) {
        if (
          prior.rows[0].review_digest !== digest ||
          prior.rows[0].customer_id !== req.user.id
        )
          throw new ConflictException();
        return false;
      }
      const { to } = await this.accounts(
        client,
        req.user.id,
        r.source,
        r.destinationNumber,
      );
      if (to.id !== r.destination) throw new ConflictException();
      if (transfer) {
        if (!r.reference || BigInt(r.amountMinor) >= 5000000n)
          throw new BadRequestException();
        await this.reference(client, req.user.id, r.reference);
      }
      const inserted = await client.query(
        `insert into bank.transaction_confirmations(id,customer_id,session_id,review_digest,factor_id,security_revision,state,expires_at,purpose) select $1,$2,$3,$4,$5,$6,'checking',to_timestamp($7/1000.0),$8 where to_timestamp($7/1000.0)>clock_timestamp() returning id`,
        [
          r.id,
          req.user.id,
          identity.session,
          digest,
          r.factor,
          r.revision,
          r.expires,
          transfer ? 'local_transfer' : 'preview',
        ],
      );
      if (!inserted.rows.length) throw new ConflictException('Review expired.');
      return true;
    });
    if (!reserved)
      return { ...(await this.status(req, r.id, transfer)), replay: true };
    try {
      await reserveSecurityProof(
        this.db,
        req.user.id,
        r.factor,
        data.code,
        transfer ? 'same-bank-transfer' : 'transaction-confirmation',
      );
    } catch (error) {
      await this.db.query(
        "update bank.transaction_confirmations set state='rejected' where id=$1 and state='checking'",
        [r.id],
      );
      throw error;
    }
    let pair: Record<string, unknown>;
    try {
      await this.activeProvider(identity.token, req.user.id, r.factor);
      const challenge = await this.security.provider(
        `/factors/${r.factor}/challenge`,
        identity.token,
        {},
      );
      uuid(challenge.id, 'Challenge');
      pair = await this.security.provider(
        `/factors/${r.factor}/verify`,
        identity.token,
        { challenge_id: challenge.id, code: data.code },
      );
    } catch (error) {
      const rejected = error instanceof BadRequestException;
      await this.db.query(
        "update bank.transaction_confirmations set state=$2 where id=$1 and state='checking'",
        [r.id, rejected ? 'rejected' : 'unknown'],
      );
      if (rejected) throw error;
      throw new ServiceUnavailableException(
        'Confirmation is uncertain. Check status; do not submit the code again.',
      );
    }
    // A verified provider call can rotate credentials. Every later failure is uncertain.
    try {
      if (
        typeof pair.access_token !== 'string' ||
        typeof pair.refresh_token !== 'string'
      )
        throw new Error();
      await this.activeProvider(pair.access_token, req.user.id, r.factor);
      const claims = JSON.parse(
        Buffer.from(pair.access_token.split('.')[1]!, 'base64url').toString(),
      ) as { sub: string; session_id: string; aal: string };
      if (
        claims.sub !== req.user.id ||
        claims.session_id !== identity.session ||
        claims.aal !== 'aal2'
      )
        throw new Error();
      await this.db.transaction(async (client) => {
        await this.binding(client, req.user.id, r);
        const { to } = await this.accounts(
          client,
          req.user.id,
          r.source,
          r.destinationNumber,
        );
        if (to.id !== r.destination) throw new ConflictException();
        const updated = await client.query(
          "update bank.transaction_confirmations set state='factor_confirmed',confirmed_until=least(expires_at,clock_timestamp()+interval '2 minutes') where id=$1 and state='checking' and expires_at>clock_timestamp() and lease_until>clock_timestamp() returning id",
          [r.id],
        );
        if (!updated.rows.length) throw new ConflictException();
        if (transfer) {
          const reference = r.reference!;
          await client.query(
            'select bank.post_local_transfer($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)',
            [
              r.id,
              req.user.id,
              identity.session,
              digest,
              r.source,
              r.destination,
              r.amountMinor,
              reference.id,
              reference.version,
              reference.revision,
              reference.evidence_id,
            ],
          );
        }
      });
      return {
        requestId: r.id,
        revision: r.revision,
        purpose: transfer ? 'same-bank-transfer' : 'transaction-confirmation',
        accessToken: pair.access_token,
        refreshToken: pair.refresh_token,
        ...(transfer
          ? await this.status(req, r.id, true)
          : {
              state: 'factor_confirmed',
              executionAvailable: false,
              sent: false,
            }),
        replay: false,
      };
    } catch {
      throw new ServiceUnavailableException(
        transfer
          ? 'Transfer outcome is unconfirmed. Check transfer history/status before trying again.'
          : 'Confirmation could not be finalized. No money was sent. Sign in again and check security.',
      );
    }
  }
  async cancel(req: AuthenticatedRequest, body: unknown, transfer = false) {
    const data = exact(body, ['reviewToken']),
      {
        identity,
        review: r,
        digest,
      } = await this.decode(req, data.reviewToken, transfer);
    await this.db.transaction(async (client) => {
      // Same customer binding lock as confirmation; cancellation also works after restriction.
      await client.query(
        'select customer_id from bank.authenticator_setup where customer_id=$1 for update',
        [req.user.id],
      );
      const changed = await client.query(
        "insert into bank.transaction_confirmations(id,customer_id,session_id,review_digest,factor_id,security_revision,state,expires_at,purpose) values($1,$2,$3,$4,$5,$6,'cancelled',to_timestamp($7/1000.0),$8) on conflict(id) do update set state='cancelled' where bank.transaction_confirmations.customer_id=$2 and bank.transaction_confirmations.review_digest=$4 and bank.transaction_confirmations.state<>'posted' returning id",
        [
          r.id,
          req.user.id,
          identity.session,
          digest,
          r.factor,
          r.revision,
          r.expires,
          transfer ? 'local_transfer' : 'preview',
        ],
      );
      if (!changed.rows.length)
        throw new ConflictException(
          'Transfer already posted. Check its result.',
        );
    });
    return {
      requestId: r.id,
      state: 'cancelled',
      sent: false,
      executionAvailable: false,
    };
  }
}
