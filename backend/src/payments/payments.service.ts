import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Inject,
  Injectable,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import { isIP } from 'node:net';
import type { PoolClient } from 'pg';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { ENVIRONMENT } from '../config/config.module.js';
import type { Environment } from '../config/environment.js';
import { exact } from '../confirmation/confirmation.service.js';
import { uuid } from '../customers/customer.validation.js';
import { DatabaseService } from '../database/database.service.js';
import { reserveSecurityProof } from '../security/security-proof.js';
import { SecurityService } from '../security/security.service.js';
import {
  createSandboxCheckout,
  verifyVnpayNotification,
  type VnpaySandboxConfig,
} from './vnpay.js';

export const sandboxServices = [
  {
    id: 'electricity',
    name: 'Demo electricity bill',
    amountMinor: '200000',
    currency: 'VND',
    description: 'Fictional Nene electricity bill. No real bill will be paid.',
  },
  {
    id: 'water',
    name: 'Demo water bill',
    amountMinor: '100000',
    currency: 'VND',
    description: 'Fictional Nene water bill. No real bill will be paid.',
  },
  {
    id: 'phone',
    name: 'Demo phone top-up',
    amountMinor: '50000',
    currency: 'VND',
    description:
      'Fictional phone account. No real phone account will be credited.',
  },
  {
    id: 'movie_matinee_v1',
    name: 'Demo movie ticket · matinee',
    amountMinor: '90000',
    currency: 'VND',
    description:
      'One ticket for A Pocket of Sunshine at fictional Nene Cinema, demo session A. No real showing, seat reservation or admission is provided.',
  },
  {
    id: 'movie_evening_v1',
    name: 'Demo movie ticket · evening',
    amountMinor: '120000',
    currency: 'VND',
    description:
      'One ticket for The Little Comet at fictional Nene Cinema, demo session B. No real showing, seat reservation or admission is provided.',
  },
] as const;
type Offer = (typeof sandboxServices)[number];
const policy = 'vnpay-synthetic-services-v2';
const purpose = 'vnpay-checkout';
const offerKeys = [
  'id',
  'name',
  'description',
  'amountMinor',
  'currency',
] as const;
type Reference = {
  id: string;
  version: number;
  revision: number;
  evidence_id: string;
};
type Binding = { factor_id: string; revision: number; state: string };
type Review = {
  id: string;
  customer: string;
  session: string;
  factor: string;
  revision: number;
  policy: string;
  serviceId: Offer['id'];
  serviceSnapshot: Offer;
  amountMinor: string;
  expires: number;
  reference: Reference;
  ipAddress: string;
};
type Attempt = {
  id: string;
  customer_id: string;
  session_id: string;
  review_digest: string;
  state: string;
  lease_until: Date;
  expires_at: Date;
};
type Payment = {
  id: string;
  customer_id: string;
  service_id: Offer['id'];
  service_snapshot: unknown;
  amount_minor: string;
  currency: 'VND';
  provider_reference: string;
  terminal_code: string;
  order_info: string;
  ip_address: string;
  state: 'awaiting_payment' | 'paid' | 'failed';
  created_at: Date;
  expires_at: Date;
  paid_at: Date | null;
};

export function paymentInput(body: unknown): Offer {
  const data = exact(body, ['serviceId']);
  const offer = sandboxServices.find((s) => s.id === data.serviceId);
  if (!offer) throw new BadRequestException('Choose a supported demo service.');
  return offer;
}

function sameOffer(snapshot: unknown, offer: Offer): boolean {
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot))
    return false;
  const data = snapshot as Record<string, unknown>;
  return (
    Object.keys(data).length === offerKeys.length &&
    offerKeys.every((key) => data[key] === offer[key])
  );
}

@Injectable()
export class PaymentsService {
  constructor(
    private readonly db: DatabaseService,
    private readonly security: SecurityService,
    @Inject(ENVIRONMENT) private readonly env: Environment,
  ) {}
  private config(): VnpaySandboxConfig | undefined {
    return this.env.nodeEnv === 'production'
      ? undefined
      : this.env.vnpaySandbox;
  }
  private enabled(): VnpaySandboxConfig {
    const config = this.config();
    if (!config)
      throw new ConflictException(
        'VNPay sandbox credentials and callback setup are not configured.',
      );
    return config;
  }
  configuration(req: AuthenticatedRequest) {
    this.security.identity(req);
    return {
      enabled: Boolean(this.config()),
      services: sandboxServices,
      highValueThresholdMinor: '5000000',
      fulfillment: 'not_available',
    };
  }
  // Viewing a fixed offer is not an authorization or payment. SessionGuard
  // supplies the active profile; no extra database or MFA calls are needed.
  preview(req: AuthenticatedRequest, body: unknown) {
    this.security.identity(req);
    const service = paymentInput(body);
    return {
      service: { ...service },
      amountMinor: service.amountMinor,
      currency: 'VND',
      checkoutAvailable: Boolean(this.config()),
      fulfillment: 'not_available',
      previewOnly: true,
    };
  }
  private async key() {
    const [row] = await this.db.query<{ secret: string }>(
      'select secret from bank.security_proof_key where id',
      [],
    );
    if (!row) throw new ServiceUnavailableException();
    return row.secret;
  }
  private mac(key: string, text: string) {
    return createHmac('sha256', key)
      .update('nene-vnpay-review-v1\0' + text)
      .digest('base64url');
  }
  private async binding(client: PoolClient, customer: string, review?: Review) {
    const { rows } = await client.query<Binding>(
      'select factor_id,revision,state from bank.authenticator_setup where customer_id=$1 for update',
      [customer],
    );
    const b = rows[0];
    if (
      !b ||
      b.state !== 'ready' ||
      (review &&
        (review.factor !== b.factor_id || review.revision !== b.revision))
    )
      throw new ConflictException(
        'Authenticator changed or is restricted. Complete security setup and review again.',
      );
    return b;
  }
  private async eligibility(
    client: PoolClient,
    customer: string,
    expected?: Reference,
  ) {
    const profile = await client.query(
      "select id from bank.user_profiles where id=$1 and role='customer' and status='active' and email like '%@example.invalid' for share",
      [customer],
    );
    if (!profile.rows.length)
      throw new ForbiddenException(
        'Only a synthetic demo customer can start sandbox checkout.',
      );
    const { rows } = await client.query<Reference>(
      "select i.id,i.version,i.revision,i.evidence_id from bank.identity_cases i join bank.identity_evidence e on e.id=i.evidence_id join bank.user_profiles p on p.id=i.customer_id where i.customer_id=$1 and i.state='reference_accepted' and i.profile_name=p.display_name and i.expires_at>clock_timestamp() and e.case_id=i.id and e.revision=i.revision and e.status='ready' and e.deleted_at is null and e.expires_at>clock_timestamp() for share of i,e",
      [customer],
    );
    const ref = rows[0];
    if (!ref || (expected && JSON.stringify(ref) !== JSON.stringify(expected)))
      throw new BadRequestException(
        'An unchanged, unexpired accepted reference is required. This is not completed eKYC.',
      );
    return ref;
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
  private async available(
    client: PoolClient,
    customer: string,
    serviceId: Offer['id'],
  ) {
    const { rows } = await client.query(
      "select id from bank.sandbox_payments where customer_id=$1 and service_id=$2 and (state='awaiting_payment' or (state='paid' and service_id in ('electricity','water'))) limit 1",
      [customer, serviceId],
    );
    if (rows.length)
      throw new ConflictException(
        'Check the existing pending payment, or this demo bill has already been paid.',
      );
  }
  async review(req: AuthenticatedRequest, body: unknown) {
    const identity = this.security.identity(req),
      offer = paymentInput(body);
    this.enabled();
    const key = await this.key();
    const remote = req.socket?.remoteAddress ?? '127.0.0.1';
    const ip =
      remote === '::1'
        ? '127.0.0.1'
        : remote.startsWith('::ffff:') && isIP(remote.slice(7)) === 4
          ? remote.slice(7)
          : remote;
    if (!isIP(ip)) throw new BadRequestException();
    const review = await this.db.transaction(async (client) => {
      const b = await this.binding(client, req.user.id);
      await this.available(client, req.user.id, offer.id);
      const existing = await client.query(
        "select id from bank.sandbox_payment_authorizations where customer_id=$1 and state='checking' and lease_until>clock_timestamp() limit 1",
        [req.user.id],
      );
      if (existing.rows.length)
        throw new ConflictException(
          'A payment confirmation is being checked. Check its status first.',
        );
      const reference = await this.eligibility(client, req.user.id);
      const { rows } = await client.query<{ expires: number }>(
        'select (extract(epoch from clock_timestamp())*1000+600000)::float8 expires',
      );
      const r: Review = {
        id: randomUUID(),
        customer: req.user.id,
        session: identity.session,
        factor: b.factor_id,
        revision: b.revision,
        policy,
        serviceId: offer.id,
        serviceSnapshot: { ...offer },
        amountMinor: offer.amountMinor,
        expires: rows[0]!.expires,
        reference,
        ipAddress: ip,
      };
      return r;
    });
    await this.activeProvider(identity.token, req.user.id, review.factor);
    const encoded = Buffer.from(JSON.stringify(review)).toString('base64url');
    return {
      reviewToken: encoded + '.' + this.mac(key, encoded),
      requestId: review.id,
      revision: review.revision,
      service: { ...review.serviceSnapshot },
      amountMinor: offer.amountMinor,
      currency: 'VND',
      expiresAt: new Date(review.expires),
    };
  }
  private async decode(req: AuthenticatedRequest, raw: unknown) {
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
    const offer = paymentInput({ serviceId: review.serviceId });
    if (
      review.policy !== policy ||
      !sameOffer(review.serviceSnapshot, offer) ||
      review.amountMinor !== offer.amountMinor ||
      BigInt(review.amountMinor) >= 5000000n ||
      !Number.isFinite(review.expires) ||
      !review.reference ||
      !isIP(review.ipAddress)
    )
      throw new ConflictException('Review policy changed.');
    uuid(review.id, 'Payment ID');
    return { identity, review, digest: this.mac(key, raw) };
  }
  private order(row: Payment) {
    const snapshot = row.service_snapshot;
    if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot))
      throw new ServiceUnavailableException('Payment details are unavailable.');
    const data = snapshot as Record<string, unknown>;
    if (
      Object.keys(data).length !== offerKeys.length ||
      !offerKeys.every((key) => typeof data[key] === 'string') ||
      data.id !== row.service_id ||
      data.amountMinor !== row.amount_minor ||
      data.currency !== row.currency ||
      row.currency !== 'VND' ||
      !/^[1-9]\d{0,6}$/.test(String(data.amountMinor)) ||
      BigInt(String(data.amountMinor)) >= 5000000n ||
      String(data.name).length < 1 ||
      String(data.name).length > 120 ||
      String(data.description).length < 1 ||
      String(data.description).length > 600
    )
      throw new ServiceUnavailableException('Payment details are unavailable.');
    // Receipts retain the exact reviewed details even after the catalog changes.
    const service = { ...snapshot } as Offer;
    return {
      id: row.id,
      service,
      amountMinor: row.amount_minor,
      currency: row.currency,
      state: row.state,
      createdAt: row.created_at,
      expiresAt: row.expires_at,
      paidAt: row.paid_at,
      fulfillment: 'not_available',
    };
  }
  private checkout(row: Payment) {
    const config = this.config();
    if (
      !config ||
      row.terminal_code !== config.terminalCode ||
      row.state !== 'awaiting_payment' ||
      row.expires_at.getTime() <= Date.now()
    )
      return {};
    return {
      checkoutUrl: createSandboxCheckout(config, {
        reference: row.provider_reference,
        amountVnd: row.amount_minor,
        orderInfo: row.order_info,
        ipAddress: row.ip_address,
        createdAt: row.created_at,
        expiresAt: row.expires_at,
      }),
    };
  }
  async status(req: AuthenticatedRequest, rawId: unknown) {
    this.security.identity(req);
    const id = uuid(rawId, 'Payment ID');
    // Read authorization first: an issued state and its payment commit together.
    // A later payment read can see that commit; reading in the opposite order
    // can miss the payment and then observe issued during a concurrent retry.
    const [attempt] = await this.db.query<Attempt>(
      'select * from bank.sandbox_payment_authorizations where id=$1 and customer_id=$2',
      [id, req.user.id],
    );
    if (!attempt) throw new NotFoundException();
    const [row] = await this.db.query<Payment>(
      'select *,amount_minor::text from bank.sandbox_payments where id=$1 and customer_id=$2',
      [id, req.user.id],
    );
    if (row)
      return {
        requestId: id,
        state: row.state,
        order: this.order(row),
        ...this.checkout(row),
      };
    if (attempt.state === 'issued')
      throw new ServiceUnavailableException(
        'Payment record is temporarily unavailable. Check status again.',
      );
    const state =
      attempt.state === 'checking' &&
      attempt.lease_until.getTime() <= Date.now()
        ? 'unknown'
        : attempt.state;
    return { requestId: id, state, order: null };
  }
  async recent(req: AuthenticatedRequest) {
    this.security.identity(req);
    const rows = await this.db.query<Payment>(
      'select *,amount_minor::text from bank.sandbox_payments where customer_id=$1 order by created_at desc,id desc limit 20',
      [req.user.id],
    );
    return { orders: rows.map((row) => this.order(row)) };
  }
  async confirm(req: AuthenticatedRequest, body: unknown) {
    this.security.identity(req);
    const config = this.enabled(),
      data = exact(body, ['reviewToken', 'code']);
    if (typeof data.code !== 'string' || !/^\d{6}$/.test(data.code))
      throw new BadRequestException('Enter a six-digit authenticator code.');
    const {
      identity,
      review: r,
      digest,
    } = await this.decode(req, data.reviewToken);
    const reserved = await this.db.transaction(async (client) => {
      await this.binding(client, req.user.id, r);
      const { rows } = await client.query<Attempt>(
        'select * from bank.sandbox_payment_authorizations where id=$1 for update',
        [r.id],
      );
      const prior = rows[0];
      if (prior) {
        if (prior.customer_id !== req.user.id || prior.review_digest !== digest)
          throw new ConflictException();
        return false;
      }
      const active = await client.query(
        "select id from bank.sandbox_payment_authorizations where customer_id=$1 and state='checking' and lease_until>clock_timestamp() limit 1",
        [req.user.id],
      );
      if (active.rows.length)
        throw new ConflictException(
          'Another payment confirmation is being checked. Check its status first.',
        );
      await this.available(client, req.user.id, r.serviceId);
      await this.eligibility(client, req.user.id, r.reference);
      const inserted = await client.query(
        "insert into bank.sandbox_payment_authorizations(id,customer_id,session_id,review_digest,factor_id,security_revision,state,expires_at) select $1,$2,$3,$4,$5,$6,'checking',to_timestamp($7/1000.0) where to_timestamp($7/1000.0)>clock_timestamp() returning id",
        [
          r.id,
          req.user.id,
          identity.session,
          digest,
          r.factor,
          r.revision,
          r.expires,
        ],
      );
      if (!inserted.rows.length) throw new ConflictException('Review expired.');
      return true;
    });
    if (!reserved) return { ...(await this.status(req, r.id)), replay: true };
    try {
      await reserveSecurityProof(
        this.db,
        req.user.id,
        r.factor,
        data.code,
        purpose,
      );
    } catch (error) {
      await this.db.query(
        "update bank.sandbox_payment_authorizations set state='rejected' where id=$1 and state='checking'",
        [r.id],
      );
      throw error;
    }
    let pair: Record<string, unknown>;
    try {
      if (
        !sameOffer(r.serviceSnapshot, paymentInput({ serviceId: r.serviceId }))
      )
        throw new ConflictException('Offer changed. Review again.');
      await this.activeProvider(identity.token, req.user.id, r.factor);
      if (
        !sameOffer(r.serviceSnapshot, paymentInput({ serviceId: r.serviceId }))
      )
        throw new ConflictException('Offer changed. Review again.');
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
        "update bank.sandbox_payment_authorizations set state=$2 where id=$1 and state='checking'",
        [r.id, rejected ? 'rejected' : 'unknown'],
      );
      if (rejected) throw error;
      throw new ServiceUnavailableException(
        'Authorization is uncertain. Sign in again and check payment status before trying again.',
      );
    }
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
        if (
          !sameOffer(
            r.serviceSnapshot,
            paymentInput({ serviceId: r.serviceId }),
          )
        )
          throw new ConflictException('Offer changed. Review again.');
        await this.binding(client, req.user.id, r);
        await this.available(client, req.user.id, r.serviceId);
        await this.eligibility(client, req.user.id, r.reference);
        const valid = await client.query(
          "select id from bank.sandbox_payment_authorizations where id=$1 and customer_id=$2 and review_digest=$3 and session_id=$4 and state='checking' and expires_at>clock_timestamp() and lease_until>clock_timestamp() for update",
          [r.id, req.user.id, digest, identity.session],
        );
        if (!valid.rows.length) throw new ConflictException();
        // Bind the same details after any security/reference lock waits, too.
        if (
          !sameOffer(
            r.serviceSnapshot,
            paymentInput({ serviceId: r.serviceId }),
          )
        )
          throw new ConflictException('Offer changed. Review again.');
        const { rows } = await client.query<Payment>(
          "insert into bank.sandbox_payments(id,customer_id,service_id,amount_minor,currency,provider_reference,terminal_code,order_info,ip_address,created_at,expires_at,service_snapshot) select $1,$2,$3,$4,'VND',$5,$6,$7,$8,clock_timestamp(),clock_timestamp()+interval '15 minutes',$10::jsonb where exists(select 1 from bank.identity_cases i join bank.identity_evidence e on e.id=i.evidence_id where i.id=$9 and i.expires_at>clock_timestamp() and e.expires_at>clock_timestamp()) and exists(select 1 from bank.sandbox_payment_authorizations where id=$1 and state='checking' and expires_at>clock_timestamp() and lease_until>clock_timestamp()) returning *,amount_minor::text",
          [
            r.id,
            req.user.id,
            r.serviceId,
            r.amountMinor,
            'N' + r.id.replaceAll('-', ''),
            config.terminalCode,
            'Nene sandbox ' + r.serviceId.replaceAll('_', '-'),
            r.ipAddress,
            r.reference.id,
            JSON.stringify(r.serviceSnapshot),
          ],
        );
        if (!rows.length)
          throw new ConflictException('Authorization or reference expired.');
        // Validate the exact checkout before committing its only immutable order.
        createSandboxCheckout(config, {
          reference: rows[0]!.provider_reference,
          amountVnd: rows[0]!.amount_minor,
          orderInfo: rows[0]!.order_info,
          ipAddress: rows[0]!.ip_address,
          createdAt: rows[0]!.created_at,
          expiresAt: rows[0]!.expires_at,
        });
        await client.query(
          "update bank.sandbox_payment_authorizations set state='issued' where id=$1",
          [r.id],
        );
      });
      return {
        ...(await this.status(req, r.id)),
        requestId: r.id,
        revision: r.revision,
        purpose,
        accessToken: pair.access_token,
        refreshToken: pair.refresh_token,
        replay: false,
      };
    } catch {
      // Tokens must never be persisted or replayed. A lost pair requires sign-in.
      throw new ServiceUnavailableException(
        'Authorization outcome is uncertain. Sign in again and check payment history; do not submit the code again.',
      );
    }
  }
  async ipn(rawQuery: string) {
    const config = this.config();
    const response = (RspCode: string, Message: string) => ({
      RspCode,
      Message,
    });
    if (!config) return response('99', 'Payment configuration unavailable');
    let notification;
    try {
      notification = verifyVnpayNotification(config, rawQuery);
    } catch {
      return response('97', 'Invalid signature or notification');
    }
    try {
      return await this.db.transaction(async (client) => {
        const { rows } = await client.query<Payment>(
          'select *,amount_minor::text from bank.sandbox_payments where provider_reference=$1 for update',
          [notification.reference],
        );
        const row = rows[0];
        if (
          !row ||
          row.terminal_code !== notification.terminalCode ||
          row.order_info !== notification.orderInfo
        )
          return response('01', 'Order not found');
        if (row.amount_minor !== notification.amountVnd)
          return response('04', 'Invalid amount');
        if (row.state !== 'awaiting_payment')
          return response('02', 'Order already confirmed');
        const authorized = await client.query(
          "select id from bank.sandbox_payment_authorizations where id=$1 and customer_id=$2 and state='issued'",
          [row.id, row.customer_id],
        );
        if (!authorized.rows.length)
          return response('99', 'Order authorization unavailable');
        const state = notification.successful
          ? 'paid'
          : notification.transactionStatus === '02'
            ? 'failed'
            : notification.transactionStatus === '01'
              ? 'awaiting_payment'
              : null;
        if (!state)
          return response('99', 'Payment result requires reconciliation');
        await client.query(
          "update bank.sandbox_payments set state=$2,paid_at=case when $2='paid' then clock_timestamp() else null end,provider_transaction_no=$3,provider_response_code=$4,provider_transaction_status=$5 where id=$1",
          [
            row.id,
            state,
            notification.transactionNo,
            notification.responseCode,
            notification.transactionStatus,
          ],
        );
        return response('00', 'Confirm Success');
      });
    } catch {
      return response('99', 'Payment result could not be recorded');
    }
  }
}
