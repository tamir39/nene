import {
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { randomBytes, randomUUID, scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import type { PoolClient, QueryResultRow } from 'pg';
import type { CurrentUser } from '../auth/auth.types.js';
import { SupabaseAdminService } from '../auth/supabase-admin.service.js';
import { DatabaseService } from '../database/database.service.js';
import type {
  Account,
  ContactInput,
  CreateCustomerInput,
  Customer,
  CustomerDetail,
  EditCustomerInput,
} from './customer.types.js';

const derive = promisify(scrypt);
// First-demo choices, not requirements imposed by the assignment.
const initialAccount = { type: 'checking', currency: 'VND' } as const;
const customerColumns =
  'id, email, display_name AS "displayName", phone, address';
const accountColumns =
  'id, account_number::text AS "accountNumber", type, currency, balance_minor::text AS "balanceMinor", status';

interface CreationRow extends QueryResultRow {
  customer_id: string;
  account_id: string;
  fingerprint_salt: string;
  payload_fingerprint: string;
  completed_at: string | null;
}

@Injectable()
export class CustomersService {
  constructor(
    private readonly database: DatabaseService,
    private readonly admin: SupabaseAdminService,
  ) {}

  officer(user: CurrentUser): void {
    if (user.role !== 'officer')
      throw new ForbiddenException('An officer profile is required.');
  }

  private customer(user: CurrentUser): void {
    if (user.role !== 'customer')
      throw new ForbiddenException('A customer profile is required.');
  }

  async ownAccounts(user: CurrentUser): Promise<{ accounts: Account[] }> {
    this.customer(user);
    const accounts = await this.database.query<Account>(
      `SELECT ${accountColumns} FROM bank.banking_accounts WHERE owner_id = $1 ORDER BY created_at, id`,
      [user.id],
    );
    return { accounts };
  }

  async updateContact(
    user: CurrentUser,
    input: ContactInput,
  ): Promise<CurrentUser> {
    this.customer(user);
    return this.database.transaction(async (client) => {
      const result = await client.query<{
        displayName: string;
        phone: string | null;
        address: string | null;
      }>(
        `UPDATE bank.user_profiles SET phone = $2, address = $3, updated_at = now()
         WHERE id = $1 AND role = 'customer' AND status = 'active'
         RETURNING display_name AS "displayName", phone, address`,
        [user.id, input.phone, input.address],
      );
      if (!result.rows[0])
        throw new NotFoundException('Customer profile was not found.');
      await client.query(
        `INSERT INTO bank.profile_edit_audit (actor_id, customer_id, request_reason, fields)
         VALUES ($1, $1, NULL, ARRAY['phone','address'])`,
        [user.id],
      );
      return { ...user, ...result.rows[0] };
    });
  }

  async search(
    user: CurrentUser,
    query: string,
  ): Promise<{ customers: Customer[] }> {
    this.officer(user);
    if (!query) return { customers: [] };
    const customers = await this.database.query<Customer>(
      `SELECT ${customerColumns} FROM bank.user_profiles
       WHERE role = 'customer' AND status = 'active'
       AND (strpos(lower(display_name), lower($1)) > 0 OR strpos(lower(coalesce(email, '')), lower($1)) > 0
            OR strpos(coalesce(phone, ''), $1) > 0)
       ORDER BY display_name, id LIMIT 20`,
      [query],
    );
    return { customers };
  }

  async detail(user: CurrentUser, id: string): Promise<CustomerDetail> {
    this.officer(user);
    return this.database.transaction((client) => this.readDetail(client, id));
  }

  private async readDetail(
    client: PoolClient,
    id: string,
  ): Promise<CustomerDetail> {
    const result = await client.query<Customer>(
      `SELECT ${customerColumns} FROM bank.user_profiles WHERE id = $1 AND role = 'customer' AND status = 'active'`,
      [id],
    );
    const customer = result.rows[0];
    if (!customer) throw new NotFoundException('Customer was not found.');
    const accounts = await client.query<Account>(
      `SELECT ${accountColumns} FROM bank.banking_accounts WHERE owner_id = $1 ORDER BY created_at, id`,
      [id],
    );
    return { ...customer, accounts: accounts.rows };
  }

  async edit(
    user: CurrentUser,
    id: string,
    input: EditCustomerInput,
  ): Promise<CustomerDetail> {
    this.officer(user);
    return this.database.transaction(async (client) => {
      const result = await client.query(
        `UPDATE bank.user_profiles SET display_name = $2, phone = $3, address = $4, updated_at = now()
         WHERE id = $1 AND role = 'customer' AND status = 'active' RETURNING id`,
        [id, input.displayName, input.phone, input.address],
      );
      if (!result.rows[0])
        throw new NotFoundException('Customer was not found.');
      await client.query(
        `INSERT INTO bank.profile_edit_audit (actor_id, customer_id, request_reason, fields)
         VALUES ($1, $2, $3, ARRAY['displayName','phone','address'])`,
        [user.id, id, input.requestReason],
      );
      return this.readDetail(client, id);
    });
  }

  async create(
    user: CurrentUser,
    key: string,
    input: CreateCustomerInput,
  ): Promise<CustomerDetail> {
    this.officer(user);
    this.admin.assertAvailable();
    const canonical = JSON.stringify([
      input.email,
      input.displayName,
      input.phone,
      input.address,
      input.initialPassword,
    ]);
    const salt = randomBytes(16).toString('hex');
    const fingerprint = (
      (await derive(canonical, salt, 32)) as Buffer
    ).toString('hex');
    // Commit the UUID before making an external call. An uncertain Auth result
    // must always reconcile this identity, never create a new one.
    await this.database.query(
      `INSERT INTO bank.customer_creation_requests
       (officer_id, idempotency_key, customer_id, account_id, fingerprint_salt, payload_fingerprint)
       VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (officer_id, idempotency_key) DO NOTHING`,
      [user.id, key, randomUUID(), randomUUID(), salt, fingerprint],
    );
    return this.database.transaction(async (client) => {
      const selected = await client.query<CreationRow>(
        `SELECT customer_id, account_id, fingerprint_salt, payload_fingerprint, completed_at
         FROM bank.customer_creation_requests WHERE officer_id = $1 AND idempotency_key = $2 FOR UPDATE`,
        [user.id, key],
      );
      const reservation = selected.rows[0];
      if (!reservation)
        throw new ConflictException(
          'The customer request could not be reserved.',
        );
      const actual = (await derive(
        canonical,
        reservation.fingerprint_salt,
        32,
      )) as Buffer;
      if (
        !timingSafeEqual(
          actual,
          Buffer.from(reservation.payload_fingerprint, 'hex'),
        )
      ) {
        throw new ConflictException(
          'This request key was already used with different customer details. Retry the original request.',
        );
      }
      if (!reservation.completed_at) {
        await this.admin.ensureUser(
          reservation.customer_id,
          input.email,
          input.initialPassword,
        );
        await client.query(
          `INSERT INTO bank.user_profiles (id, email, display_name, phone, address)
           VALUES ($1, $2, $3, $4, $5)`,
          [
            reservation.customer_id,
            input.email,
            input.displayName,
            input.phone,
            input.address,
          ],
        );
        await client.query(
          `INSERT INTO bank.banking_accounts (id, owner_id, type, currency)
           VALUES ($1, $2, $3, $4)`,
          [
            reservation.account_id,
            reservation.customer_id,
            initialAccount.type,
            initialAccount.currency,
          ],
        );
        await client.query(
          `UPDATE bank.customer_creation_requests SET completed_at = now()
           WHERE officer_id = $1 AND idempotency_key = $2`,
          [user.id, key],
        );
      }
      return this.readDetail(client, reservation.customer_id);
    });
  }
}
