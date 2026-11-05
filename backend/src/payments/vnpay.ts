import { createHmac, timingSafeEqual } from 'node:crypto';
import { isIP } from 'node:net';

// PAY 2.1.0, HMACSHA512, using the official Node query encoding contract:
// https://sandbox.vnpayment.vn/apis/docs/chuyen-doi-thuat-toan/changeTypeHash.html
// This adapter only authenticates protocol messages. The caller must check the
// stored owner, authorization, order amount/state and commit IPN changes once.
export const VNPAY_SANDBOX_URL =
  'https://sandbox.vnpayment.vn/paymentv2/vpcpay.html';

export interface VnpaySandboxConfig {
  terminalCode: string;
  hashSecret: string;
  returnUrl: string;
}

export interface VnpayCheckoutInput {
  reference: string;
  amountVnd: string;
  orderInfo: string;
  ipAddress: string;
  createdAt: Date;
  expiresAt: Date;
}

export interface VerifiedVnpayNotification {
  reference: string;
  amountVnd: string;
  orderInfo: string;
  terminalCode: string;
  transactionNo: string;
  responseCode: string;
  transactionStatus: string;
  successful: boolean;
  bankCode: string;
  payDate?: string;
}

export class VnpayValidationError extends Error {
  constructor(readonly reason: 'malformed' | 'signature' | 'terminal') {
    super(`Invalid VNPay message (${reason}).`);
    this.name = 'VnpayValidationError';
  }
}

const malformed = (): never => {
  throw new VnpayValidationError('malformed');
};

function printable(
  value: string,
  maximum: number,
  allowEmpty = false,
): boolean {
  return (
    (allowEmpty || value.length > 0) &&
    value.length <= maximum &&
    [...value].every((character) => {
      const code = character.charCodeAt(0);
      return code >= 32 && code <= 126;
    })
  );
}

function credentials(
  config: Pick<VnpaySandboxConfig, 'terminalCode' | 'hashSecret'>,
) {
  if (
    !/^[A-Za-z0-9]{8}$/.test(config.terminalCode) ||
    !printable(config.hashSecret, 1024) ||
    config.hashSecret.trim() !== config.hashSecret
  )
    malformed();
}

function encode(value: string): string {
  return encodeURIComponent(value).replace(/%20/g, '+');
}

function canonical(fields: ReadonlyMap<string, string>): string {
  return [...fields.keys()]
    .sort()
    .map((key) => `${encode(key)}=${encode(fields.get(key)!)}`)
    .join('&');
}

function signature(
  fields: ReadonlyMap<string, string>,
  secret: string,
): Buffer {
  return createHmac('sha512', secret)
    .update(canonical(fields), 'utf8')
    .digest();
}

function providerDate(value: Date): string {
  if (!Number.isFinite(value.getTime())) malformed();
  const shifted = new Date(value.getTime() + 7 * 60 * 60 * 1000);
  const year = shifted.getUTCFullYear();
  if (year < 2000 || year > 9999) malformed();
  return shifted.toISOString().slice(0, 19).replace(/[-T:]/g, '');
}

function validPayDate(value: string): boolean {
  if (!/^\d{14}$/.test(value)) return false;
  const iso = `${value.slice(0, 4)}-${value.slice(4, 6)}-${value.slice(6, 8)}T${value.slice(8, 10)}:${value.slice(10, 12)}:${value.slice(12, 14)}+07:00`;
  const date = new Date(iso);
  return Number.isFinite(date.getTime()) && providerDate(date) === value;
}

export function createSandboxCheckout(
  config: VnpaySandboxConfig,
  input: VnpayCheckoutInput,
): string {
  credentials(config);
  let returnUrl: URL;
  try {
    returnUrl = new URL(config.returnUrl);
  } catch {
    return malformed();
  }
  if (
    returnUrl.protocol !== 'https:' ||
    returnUrl.username ||
    returnUrl.password ||
    returnUrl.search ||
    returnUrl.hash ||
    !printable(config.returnUrl, 255) ||
    !/^[A-Za-z0-9]{1,100}$/.test(input.reference) ||
    !/^[1-9]\d{0,9}$/.test(input.amountVnd) ||
    !/^[A-Za-z0-9 .,:/-]{1,255}$/.test(input.orderInfo) ||
    input.orderInfo.trim().length === 0 ||
    isIP(input.ipAddress) === 0 ||
    input.expiresAt.getTime() <= input.createdAt.getTime()
  )
    malformed();
  const fields = new Map<string, string>([
    ['vnp_Version', '2.1.0'],
    ['vnp_Command', 'pay'],
    ['vnp_TmnCode', config.terminalCode],
    ['vnp_Amount', (BigInt(input.amountVnd) * 100n).toString()],
    ['vnp_CurrCode', 'VND'],
    ['vnp_TxnRef', input.reference],
    ['vnp_OrderInfo', input.orderInfo],
    ['vnp_OrderType', 'other'],
    ['vnp_ReturnUrl', config.returnUrl],
    ['vnp_IpAddr', input.ipAddress],
    ['vnp_Locale', 'vn'],
    ['vnp_CreateDate', providerDate(input.createdAt)],
    ['vnp_ExpireDate', providerDate(input.expiresAt)],
  ]);
  return `${VNPAY_SANDBOX_URL}?${canonical(fields)}&vnp_SecureHash=${signature(fields, config.hashSecret).toString('hex')}`;
}

const notificationFields = new Set([
  'vnp_Amount',
  'vnp_BankCode',
  'vnp_BankTranNo',
  'vnp_CardType',
  'vnp_OrderInfo',
  'vnp_PayDate',
  'vnp_ResponseCode',
  'vnp_TmnCode',
  'vnp_TransactionNo',
  'vnp_TransactionStatus',
  'vnp_TxnRef',
  'vnp_SecureHash',
  'vnp_SecureHashType',
]);

function rawFields(rawQuery: string): Map<string, string> {
  if (typeof rawQuery !== 'string' || !rawQuery || rawQuery.length > 8192)
    malformed();
  const fields = new Map<string, string>();
  for (const part of rawQuery.split('&')) {
    const equals = part.indexOf('=');
    if (equals < 1) malformed();
    let key: string;
    let value: string;
    try {
      // Unlike URLSearchParams, decodeURIComponent rejects malformed percent
      // escapes / invalid UTF-8 instead of silently replacing their contents.
      key = decodeURIComponent(part.slice(0, equals).replace(/\+/g, ' '));
      value = decodeURIComponent(part.slice(equals + 1).replace(/\+/g, ' '));
    } catch {
      return malformed();
    }
    if (
      !notificationFields.has(key) ||
      fields.has(key) ||
      !printable(value, 255, true)
    )
      malformed();
    fields.set(key, value);
  }
  return fields;
}

/** Pass the raw query, without "?", before any framework query normalization. */
export function verifyVnpayNotification(
  config: Pick<VnpaySandboxConfig, 'terminalCode' | 'hashSecret'>,
  rawQuery: string,
): VerifiedVnpayNotification {
  credentials(config);
  const fields = rawFields(rawQuery);
  const hash = fields.get('vnp_SecureHash') ?? '';
  const hashType = fields.get('vnp_SecureHashType');
  if (
    !/^[a-fA-F0-9]{128}$/.test(hash) ||
    (hashType !== undefined &&
      hashType !== '' &&
      hashType.toLowerCase() !== 'hmacsha512')
  )
    throw new VnpayValidationError('signature');
  fields.delete('vnp_SecureHash');
  fields.delete('vnp_SecureHashType');
  if (
    !timingSafeEqual(
      signature(fields, config.hashSecret),
      Buffer.from(hash, 'hex'),
    )
  )
    throw new VnpayValidationError('signature');

  const terminalCode = fields.get('vnp_TmnCode') ?? '';
  if (terminalCode !== config.terminalCode)
    throw new VnpayValidationError('terminal');
  const reference = fields.get('vnp_TxnRef') ?? '';
  const amount = fields.get('vnp_Amount') ?? '';
  const orderInfo = fields.get('vnp_OrderInfo') ?? '';
  const transactionNo = fields.get('vnp_TransactionNo') ?? '';
  const responseCode = fields.get('vnp_ResponseCode') ?? '';
  const transactionStatus = fields.get('vnp_TransactionStatus') ?? '';
  const bankCode = fields.get('vnp_BankCode') ?? '';
  // Preserve empty optional values in the checksum above, then interpret them
  // as absent. Failed/cancelled payments may have no bank receipt or pay date.
  const bankTransactionNo = fields.get('vnp_BankTranNo') || undefined;
  const cardType = fields.get('vnp_CardType') || undefined;
  const payDate = fields.get('vnp_PayDate') || undefined;
  if (
    !/^[A-Za-z0-9]{1,100}$/.test(reference) ||
    !/^[1-9]\d{0,11}$/.test(amount) ||
    BigInt(amount) % 100n !== 0n ||
    !printable(orderInfo, 255) ||
    !/^\d{1,15}$/.test(transactionNo) ||
    !/^\d{2}$/.test(responseCode) ||
    !/^\d{2}$/.test(transactionStatus) ||
    !/^[A-Za-z0-9]{3,20}$/.test(bankCode) ||
    (bankTransactionNo !== undefined &&
      !/^[A-Za-z0-9]{1,255}$/.test(bankTransactionNo)) ||
    (cardType !== undefined && !/^[A-Za-z]{2,20}$/.test(cardType)) ||
    (payDate !== undefined && !validPayDate(payDate))
  )
    malformed();
  const successful = responseCode === '00' && transactionStatus === '00';
  if (successful && BigInt(transactionNo) === 0n) malformed();
  return {
    reference,
    amountVnd: (BigInt(amount) / 100n).toString(),
    orderInfo,
    terminalCode,
    transactionNo,
    responseCode,
    transactionStatus,
    successful,
    bankCode,
    ...(payDate === undefined ? {} : { payDate }),
  };
}
