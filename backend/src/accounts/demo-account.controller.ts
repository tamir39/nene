import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  ForbiddenException,
  Header,
  Headers,
  Inject,
  NotFoundException,
  Param,
  Post,
  Req,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { ENVIRONMENT } from '../config/config.module.js';
import type { Environment } from '../config/environment.js';
import { DatabaseService } from '../database/database.service.js';
import { uuid } from '../customers/customer.validation.js';

export function demoAccountInput(body: unknown) {
  if (!body || typeof body !== 'object' || Array.isArray(body))
    throw new BadRequestException();
  const data = body as Record<string, unknown>;
  const fields =
    data.type === 'saving'
      ? ['type', 'reason', 'syntheticConfirmed']
      : [
          'type',
          'reason',
          'syntheticConfirmed',
          'principalMinor',
          'termMonths',
          'firstDueOn',
        ];
  if (
    Object.keys(data).length !== fields.length ||
    fields.some((k) => !Object.hasOwn(data, k)) ||
    !['saving', 'mortgage'].includes(String(data.type)) ||
    data.syntheticConfirmed !== true ||
    typeof data.reason !== 'string' ||
    data.reason.trim().length < 5 ||
    data.reason.trim().length > 500 ||
    /\p{Cc}/u.test(data.reason)
  )
    throw new BadRequestException(
      'Confirm synthetic data and provide a reason of 5–500 characters.',
    );
  const base = {
    type: data.type as 'saving' | 'mortgage',
    reason: data.reason.trim(),
    syntheticConfirmed: true,
  };
  if (data.type === 'saving') return base;
  if (
    typeof data.principalMinor !== 'string' ||
    !/^[1-9]\d{0,12}$/.test(data.principalMinor) ||
    BigInt(data.principalMinor) > 1000000000000n ||
    typeof data.termMonths !== 'number' ||
    !Number.isInteger(data.termMonths) ||
    data.termMonths < 1 ||
    data.termMonths > 360 ||
    BigInt(data.principalMinor) < BigInt(data.termMonths) ||
    typeof data.firstDueOn !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}$/.test(data.firstDueOn)
  )
    throw new BadRequestException(
      'Use a VND principal from the term length up to 1 trillion, 1–360 months and a valid date.',
    );
  const date = new Date(data.firstDueOn + 'T00:00:00Z');
  if (
    !Number.isFinite(date.getTime()) ||
    date.toISOString().slice(0, 10) !== data.firstDueOn ||
    data.firstDueOn < '2000-01-01' ||
    data.firstDueOn > '2100-12-31'
  )
    throw new BadRequestException('Invalid first payment date.');
  return {
    ...base,
    principalMinor: data.principalMinor,
    termMonths: data.termMonths,
    firstDueOn: data.firstDueOn,
  };
}
@Controller('officer/customers/:customerId/demo-accounts')
export class DemoAccountController {
  constructor(
    private readonly db: DatabaseService,
    @Inject(ENVIRONMENT) private readonly env: Environment,
  ) {}
  @Post()
  @Header('Cache-Control', 'no-store')
  async create(
    @Req() req: AuthenticatedRequest,
    @Param('customerId') rawCustomer: unknown,
    @Headers('idempotency-key') rawKey: unknown,
    @Body() body: unknown,
  ) {
    if (
      req.user.role !== 'officer' ||
      this.env.nodeEnv === 'production' ||
      !['localhost', '127.0.0.1', '[::1]'].includes(
        new URL(this.env.supabaseUrl).hostname,
      )
    )
      throw new ForbiddenException(
        'Demo provisioning is available only to officers on local Auth.',
      );
    const customer = uuid(rawCustomer),
      key = uuid(rawKey, 'Idempotency-Key'),
      input = demoAccountInput(body),
      payload = JSON.stringify(input);
    return this.db.transaction(async (client) => {
      // Serialize request keys even across different customers; serialize per-customer uniqueness too.
      await client.query(
        'select pg_advisory_xact_lock(hashtextextended($1,0))',
        [req.user.id + ':' + key],
      );
      const profile = await client.query<{ email: string }>(
        "select email from bank.user_profiles where id=$1 and role='customer' and status='active' for update",
        [customer],
      );
      if (!profile.rows.length)
        throw new NotFoundException('Active customer not found.');
      if (!/@[^@]+\.(invalid|test)$/i.test(profile.rows[0]!.email ?? ''))
        throw new ForbiddenException(
          'Use a synthetic customer with an .invalid or .test email.',
        );
      const prior = await client.query<{
        customer_id: string;
        account_id: string;
        matches: boolean;
      }>(
        'select customer_id,account_id,payload=$3::jsonb as matches from bank.demo_account_requests where officer_id=$1 and request_id=$2',
        [req.user.id, key, payload],
      );
      if (prior.rows[0]) {
        const old = prior.rows[0];
        if (old.customer_id !== customer || !old.matches)
          throw new ConflictException(
            'This request key was already used with different details.',
          );
        return { accountId: old.account_id, customerId: customer };
      }
      const existing = await client.query(
        'select id from bank.banking_accounts where owner_id=$1 and type=$2 and is_demo',
        [customer, input.type],
      );
      if (existing.rows.length)
        throw new ConflictException(
          'This demo account type already exists. Reload the customer.',
        );
      const accountId = randomUUID();
      await client.query(
        "insert into bank.banking_accounts(id,owner_id,type,currency,is_demo) values($1,$2,$3,'VND',true)",
        [accountId, customer, input.type],
      );
      if ('principalMinor' in input) {
        const due = (
          BigInt(input.principalMinor) / BigInt(input.termMonths)
        ).toString();
        await client.query(
          'insert into bank.mortgage_schedule(account_id,principal_remaining_minor,monthly_due_minor,next_due_on,term_months) values($1,$2,$3,$4,$5)',
          [
            accountId,
            input.principalMinor,
            due,
            input.firstDueOn,
            input.termMonths,
          ],
        );
      }
      await client.query(
        'insert into bank.demo_account_requests(officer_id,request_id,customer_id,account_id,payload) values($1,$2,$3,$4,$5::jsonb)',
        [req.user.id, key, customer, accountId, payload],
      );
      return { accountId, customerId: customer };
    });
  }
}
