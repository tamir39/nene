import { BadRequestException, PayloadTooLargeException } from '@nestjs/common';

export const notice = {
  version: 'reference-demo-v1',
  text: 'This coursework demo stores one private reference photo for officer review and later identity-check development. Acceptance is not completed eKYC or proof of live presence. Access expires after 7 days; expired and abandoned files are removed when local maintenance runs. Use only agreed test images; do not submit real customer data.',
};
export const maxImageBytes = 10 * 1024 * 1024;

function object(body: unknown, keys: string[]): Record<string, unknown> {
  if (!body || typeof body !== 'object' || Array.isArray(body))
    throw new BadRequestException('A JSON object is required.');
  const result = body as Record<string, unknown>;
  if (
    Object.keys(result).some((key) => !keys.includes(key)) ||
    keys.some((key) => !Object.hasOwn(result, key))
  )
    throw new BadRequestException(
      'The request contains unsupported or missing fields.',
    );
  return result;
}
function version(value: unknown): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1)
    throw new BadRequestException(
      'Expected version must be a positive integer.',
    );
  return value;
}
export function startInput(body: unknown) {
  const value = object(body, ['noticeVersion', 'acknowledged']);
  if (value.noticeVersion !== notice.version || value.acknowledged !== true)
    throw new BadRequestException(
      'Acknowledge the current reference-photo notice.',
    );
  return { noticeVersion: notice.version, acknowledged: true };
}
export function submitInput(body: unknown) {
  const value = object(body, ['expectedVersion']);
  return { expectedVersion: version(value.expectedVersion) };
}
export function evidenceInput(body: unknown) {
  const value = object(body, ['expectedVersion', 'contentType', 'dataBase64']);
  if (value.contentType !== 'image/jpeg' && value.contentType !== 'image/png')
    throw new BadRequestException('Use a JPEG or PNG photo.');
  if (typeof value.dataBase64 !== 'string' || !value.dataBase64.length)
    throw new BadRequestException('Photo bytes are required.');
  if (value.dataBase64.length > Math.ceil(maxImageBytes / 3) * 4)
    throw new PayloadTooLargeException('Photo must be at most 10 MiB.');
  if (
    value.dataBase64.length % 4 !== 0 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(value.dataBase64)
  )
    throw new BadRequestException('Photo encoding is invalid.');
  const bytes = Buffer.from(value.dataBase64, 'base64');
  if (bytes.toString('base64') !== value.dataBase64)
    throw new BadRequestException('Photo encoding is invalid.');
  if (bytes.length > maxImageBytes)
    throw new PayloadTooLargeException('Photo must be at most 10 MiB.');
  return {
    expectedVersion: version(value.expectedVersion),
    contentType: value.contentType as 'image/jpeg' | 'image/png',
    bytes,
  };
}
export function reviewInput(body: unknown) {
  const value = object(body, [
    'expectedVersion',
    'action',
    'associationConfirmed',
    'reason',
  ]);
  if (value.action === 'accept_reference') {
    if (value.associationConfirmed !== true || value.reason !== null)
      throw new BadRequestException(
        'Confirm the customer/reference association before accepting.',
      );
    return {
      expectedVersion: version(value.expectedVersion),
      action: 'accept_reference' as const,
      associationConfirmed: true,
      reason: null,
    };
  }
  if (
    value.action !== 'request_changes' ||
    value.associationConfirmed !== false ||
    typeof value.reason !== 'string' ||
    value.reason.trim().length < 5 ||
    value.reason.trim().length > 500 ||
    /\p{Cc}/u.test(value.reason)
  )
    throw new BadRequestException(
      'A correction requires a reason of 5 to 500 characters.',
    );
  return {
    expectedVersion: version(value.expectedVersion),
    action: 'request_changes' as const,
    associationConfirmed: false,
    reason: value.reason.trim(),
  };
}
