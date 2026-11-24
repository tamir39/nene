import 'reflect-metadata';
import assert from 'node:assert/strict';
import { beforeEach, describe, it } from 'node:test';
import {
  ConflictException,
  ForbiddenException,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import type { PoolClient } from 'pg';
import type { CurrentUser } from '../src/auth/auth.types.js';
import type { SupabaseAdminService } from '../src/auth/supabase-admin.service.js';
import { CustomersService } from '../src/customers/customers.service.js';
import type { DatabaseService } from '../src/database/database.service.js';
import type { CreateCustomerInput } from '../src/customers/customer.types.js';

const officer: CurrentUser = {
  id: 'b1000000-0000-4000-8000-000000000001',
  email: 'officer@example.invalid',
  displayName: 'Demo Officer',
  role: 'officer',
  phone: null,
  address: null,
};
const customer: CurrentUser = {
  ...officer,
  id: 'b1000000-0000-4000-8000-000000000002',
  role: 'customer',
};
const key = 'b1000000-0000-4000-8000-000000000003';
const input: CreateCustomerInput = {
  email: 'customer@example.invalid',
  displayName: 'Demo Customer',
  phone: '+84 900 123 456',
  address: 'Demo address 1',
  initialPassword: 'Synthetic-long-password',
};

interface Reservation {
  customer_id: string;
  account_id: string;
  fingerprint_salt: string;
  payload_fingerprint: string;
  completed_at: string | null;
}

void describe('customer provisioning orchestration (transaction/Auth fakes)', () => {
  let service: CustomersService;
  let reservations: Map<string, Reservation>;
  let identities: Map<string, string>;
  let profiles: Map<string, Record<string, unknown>>;
  let accounts: Map<string, Record<string, unknown>>;
  let calls: { sql: string; values: unknown[] }[];
  let authCreates: number;
  let authFailsAfterCreation: boolean;
  let failAccountInsert: boolean;
  let adminAvailable: boolean;
  let tail: Promise<void>;

  beforeEach(() => {
    reservations = new Map();
    identities = new Map();
    profiles = new Map();
    accounts = new Map();
    calls = [];
    authCreates = 0;
    authFailsAfterCreation = false;
    failAccountInsert = false;
    adminAvailable = true;
    tail = Promise.resolve();
    const query = async (sql: string, values: unknown[]) => {
      calls.push({ sql, values });
      if (sql.includes('INSERT INTO bank.customer_creation_requests')) {
        const requestKey = `${values[0]}:${values[1]}`;
        if (!reservations.has(requestKey))
          reservations.set(requestKey, {
            customer_id: values[2] as string,
            account_id: values[3] as string,
            fingerprint_salt: values[4] as string,
            payload_fingerprint: values[5] as string,
            completed_at: null,
          });
        return [];
      }
      if (sql.includes('FROM bank.customer_creation_requests')) {
        const found = reservations.get(`${values[0]}:${values[1]}`);
        return found ? [found] : [];
      }
      if (sql.includes('INSERT INTO bank.user_profiles')) {
        assert.equal(
          profiles.has(values[0] as string),
          false,
          'profile insert must be unique',
        );
        profiles.set(values[0] as string, {
          id: values[0],
          email: values[1],
          displayName: values[2],
          phone: values[3],
          address: values[4],
        });
        return [];
      }
      if (sql.includes('INSERT INTO bank.banking_accounts')) {
        if (failAccountInsert)
          throw new ServiceUnavailableException('Simulated database failure.');
        accounts.set(values[0] as string, {
          id: values[0],
          owner_id: values[1],
          type: values[2],
          currency: values[3],
          accountNumber: '100000000001',
          balanceMinor: '0',
          status: 'active',
        });
        return [];
      }
      if (sql.includes('UPDATE bank.customer_creation_requests')) {
        reservations.get(`${values[0]}:${values[1]}`)!.completed_at =
          'complete';
        return [];
      }
      if (sql.includes('FROM bank.user_profiles')) {
        const found = profiles.get(values[0] as string);
        return found ? [found] : [];
      }
      if (sql.includes('FROM bank.banking_accounts')) {
        return [...accounts.values()]
          .filter((a) => a.owner_id === values[0])
          .map(({ owner_id, ...a }) => {
            assert.ok(owner_id);
            return a;
          });
      }
      throw new Error(`Unexpected fake query: ${sql}`);
    };
    const database = {
      query,
      transaction: async <T>(work: (client: PoolClient) => Promise<T>) => {
        const previous = tail;
        let unlock!: () => void;
        tail = new Promise<void>((resolve) => {
          unlock = resolve;
        });
        await previous;
        const savedProfiles = structuredClone(profiles);
        const savedAccounts = structuredClone(accounts);
        const completed = new Map(
          [...reservations].map(([k, v]) => [k, v.completed_at]),
        );
        try {
          return await work({
            query: async (sql: string, values: unknown[]) => ({
              rows: await query(sql, values),
            }),
          } as unknown as PoolClient);
        } catch (error) {
          profiles = savedProfiles;
          accounts = savedAccounts;
          for (const [k, state] of completed)
            reservations.get(k)!.completed_at = state;
          throw error;
        } finally {
          unlock();
        }
      },
    } as unknown as DatabaseService;
    const admin = {
      assertAvailable: () => {
        if (!adminAvailable) throw new ServiceUnavailableException();
      },
      ensureUser: async (id: string, email: string) => {
        assert.ok(
          [...reservations.values()].some((r) => r.customer_id === id),
          'ID must already be durably reserved',
        );
        if (identities.has(id)) return;
        if ([...identities.values()].includes(email))
          throw new ConflictException('Duplicate identity.');
        identities.set(id, email);
        authCreates++;
        if (authFailsAfterCreation)
          throw new ServiceUnavailableException('Uncertain Auth outcome.');
      },
    } as unknown as SupabaseAdminService;
    service = new CustomersService(database, admin);
  });

  void it('creates one zero-balance checking account and replays the same IDs', async () => {
    const first = await service.create(officer, key, input);
    const replay = await service.create(officer, key, input);
    assert.deepEqual(replay, first);
    assert.equal(first.email, input.email);
    assert.equal(first.accounts.length, 1);
    assert.equal(first.accounts[0]?.balanceMinor, '0');
    assert.equal(first.accounts[0]?.currency, 'VND');
    assert.equal(first.accounts[0]?.type, 'checking');
    assert.equal(authCreates, 1);
    assert.equal(
      JSON.stringify([...reservations.values()]).includes(
        input.initialPassword,
      ),
      false,
    );
    assert.equal(JSON.stringify(calls).includes(input.initialPassword), false);
  });

  void it('serializes simultaneous retries into one identity and account', async () => {
    const results = await Promise.all([
      service.create(officer, key, input),
      service.create(officer, key, input),
    ]);
    assert.deepEqual(results[0], results[1]);
    assert.equal(authCreates, 1);
    assert.equal(profiles.size, 1);
    assert.equal(accounts.size, 1);
  });

  void it('rejects changes to the original password or business payload on replay', async () => {
    await service.create(officer, key, input);
    for (const changed of [
      { ...input, initialPassword: 'Different-long-password' },
      { ...input, phone: null },
    ]) {
      await assert.rejects(
        service.create(officer, key, changed),
        ConflictException,
      );
    }
    assert.equal(authCreates, 1);
  });

  void it('recovers the reserved identity after a timeout following Auth creation', async () => {
    authFailsAfterCreation = true;
    await assert.rejects(
      service.create(officer, key, input),
      ServiceUnavailableException,
    );
    assert.equal(profiles.size, 0);
    assert.equal(identities.size, 1);
    const reserved = [...reservations.values()][0]!.customer_id;
    authFailsAfterCreation = false;
    assert.equal((await service.create(officer, key, input)).id, reserved);
    assert.equal(authCreates, 1);
  });

  void it('rolls back profile/account together and reconciles after database failure', async () => {
    failAccountInsert = true;
    await assert.rejects(
      service.create(officer, key, input),
      ServiceUnavailableException,
    );
    assert.equal(profiles.size, 0);
    assert.equal(accounts.size, 0);
    assert.equal(identities.size, 1);
    failAccountInsert = false;
    const result = await service.create(officer, key, input);
    assert.equal(result.accounts.length, 1);
    assert.equal(authCreates, 1);
  });

  void it('does not adopt an existing unrelated identity with the same email', async () => {
    identities.set('unrelated-identity', input.email);
    await assert.rejects(
      service.create(officer, key, input),
      ConflictException,
    );
    assert.equal(profiles.size, 0);
    assert.deepEqual([...identities.keys()], ['unrelated-identity']);
  });

  void it('checks officer permissions and configuration before reserving requests', async () => {
    await assert.rejects(
      service.create(customer, key, input),
      ForbiddenException,
    );
    adminAvailable = false;
    await assert.rejects(
      service.create(officer, key, input),
      ServiceUnavailableException,
    );
    assert.equal(reservations.size, 0);
    await assert.rejects(
      service.detail(customer, customer.id),
      ForbiddenException,
    );
    await assert.rejects(service.search(customer, 'other'), ForbiddenException);
    await assert.rejects(
      service.edit(customer, customer.id, {
        displayName: 'X',
        phone: null,
        address: null,
        requestReason: 'Requested',
      }),
      ForbiddenException,
    );
  });

  void it('restricts own accounts to the verified subject and rejects officers', async () => {
    accounts.set('own', { id: 'own', owner_id: customer.id });
    accounts.set('other', { id: 'other', owner_id: officer.id });
    assert.deepEqual(await service.ownAccounts(customer), {
      accounts: [{ id: 'own' }],
    });
    await assert.rejects(service.ownAccounts(officer), ForbiddenException);
    await assert.rejects(
      service.updateContact(officer, { phone: null, address: null }),
      ForbiddenException,
    );
  });

  void it('uses empty search without enumerating customers and returns missing detail as 404', async () => {
    assert.deepEqual(await service.search(officer, ''), { customers: [] });
    assert.equal(calls.length, 0);
    await assert.rejects(
      service.detail(officer, customer.id),
      NotFoundException,
    );
  });
});
