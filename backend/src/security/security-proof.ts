import { BadRequestException, HttpException } from '@nestjs/common';
import { createHmac } from 'node:crypto';
import type { DatabaseService } from '../database/database.service.js';

// Shared by setup and lifecycle. Future financial authorization MUST use this
// same boundary and check the active binding/revision at final consumption.
export async function reserveSecurityProof(
  db: DatabaseService,
  customer: string,
  factor: string,
  code: string,
  purpose: string,
) {
  await db.transaction(async (client) => {
    await client.query('select pg_advisory_xact_lock(hashtextextended($1,0))', [
      'security-proof:' + customer,
    ]);
    await client.query(
      "delete from bank.security_proof_reservations where customer_id=$1 and created_at<now()-interval '15 minutes'",
      [customer],
    );
    const count = await client.query<{ n: number }>(
      'select count(*)::int n from bank.security_proof_reservations where customer_id=$1',
      [customer],
    );
    if (count.rows[0]!.n >= 10)
      throw new HttpException(
        'Too many security attempts. Wait 15 minutes.',
        429,
      );
    const key = await client.query<{ secret: string }>(
      'select secret from bank.security_proof_key where id',
    );
    const fingerprint = createHmac('sha256', key.rows[0]!.secret)
      .update(customer + '\0' + factor + '\0' + code)
      .digest('hex');
    const inserted = await client.query(
      'insert into bank.security_proof_reservations(customer_id,factor_scope,fingerprint,purpose) values($1,$2,$3,$4) on conflict do nothing returning customer_id',
      [customer, factor, fingerprint, purpose],
    );
    if (!inserted.rows.length)
      throw new BadRequestException(
        'This code was already attempted. Wait for a new code or use another recovery code.',
      );
  });
}
