import { ConflictException } from '@nestjs/common';
import type { PoolClient } from 'pg';

/**
 * High-value transfer rule, modelled on the Decision 2345/QD-NHNN bands. The
 * database function `bank.transfer_face_check_required` is the single source of
 * truth; these constants describe it for configuration responses and docs.
 */
export const faceRule = {
  singleMinor: '10000000',
  dailyMinor: '20000000',
  maxTransferMinor: '50000000',
  validitySeconds: 300,
} as const;

/** Same-bank and other-bank transfers allow up to 50,000,000 VND. */
export const transferAmountAllowed = (amountMinor: string) =>
  BigInt(amountMinor) <= BigInt(faceRule.maxTransferMinor);

export async function faceCheckRequired(
  client: PoolClient,
  customer: string,
  amountMinor: string,
) {
  const { rows } = await client.query<{ required: boolean }>(
    'select bank.transfer_face_check_required($1,$2::bigint) as required',
    [customer, amountMinor],
  );
  // Fail closed if the database returns nothing.
  return rows[0]?.required !== false;
}

export const faceCheckRequiredError = () =>
  new ConflictException({
    statusCode: 409,
    code: 'FACE_CHECK_REQUIRED',
    message:
      'A face check is required for this transfer. Complete it, then confirm again.',
  });
