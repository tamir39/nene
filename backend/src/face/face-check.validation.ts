import { BadRequestException } from '@nestjs/common';
import { maxImageBytes } from '../identity/identity.validation.js';

export type Liveness = { blink: boolean; turn: boolean };
export type UploadedSelfie = {
  buffer: Buffer;
  mimetype: string;
  size: number;
  fieldname: string;
};
export type FaceCheckInput = {
  reviewToken: string;
  liveness: Liveness;
  selfie: { bytes: Buffer; contentType: 'image/jpeg' | 'image/png' };
};

/** Multipart limits: one selfie up to 10 MiB and two small text fields. */
export const faceUploadLimits = {
  fileSize: maxImageBytes,
  files: 1,
  fields: 2,
  parts: 3,
  fieldSize: 8192,
};

/** Validates the multipart fields of POST /me/face-checks. */
export function faceCheckInput(
  body: unknown,
  file: UploadedSelfie | undefined,
): FaceCheckInput {
  if (!body || typeof body !== 'object' || Array.isArray(body))
    throw new BadRequestException(
      'Send the review token, liveness and selfie.',
    );
  const fields = body as Record<string, unknown>;
  const keys = Object.keys(fields);
  if (
    keys.length !== 2 ||
    !keys.includes('reviewToken') ||
    !keys.includes('liveness')
  )
    throw new BadRequestException(
      'Send exactly the reviewToken and liveness fields with the selfie file.',
    );
  if (
    typeof fields.reviewToken !== 'string' ||
    !fields.reviewToken.length ||
    fields.reviewToken.length > 4096
  )
    throw new BadRequestException('Review token is invalid.');
  if (typeof fields.liveness !== 'string' || fields.liveness.length > 100)
    throw new BadRequestException('Liveness flags are invalid.');
  let liveness: unknown;
  try {
    liveness = JSON.parse(fields.liveness);
  } catch {
    throw new BadRequestException('Liveness flags are invalid.');
  }
  if (
    !liveness ||
    typeof liveness !== 'object' ||
    Array.isArray(liveness) ||
    Object.keys(liveness).length !== 2 ||
    typeof (liveness as Liveness).blink !== 'boolean' ||
    typeof (liveness as Liveness).turn !== 'boolean'
  )
    throw new BadRequestException(
      'Liveness must be {"blink":true|false,"turn":true|false}.',
    );
  if (!file || file.fieldname !== 'selfie' || !file.buffer?.length)
    throw new BadRequestException('A selfie photo is required.');
  if (file.mimetype !== 'image/jpeg' && file.mimetype !== 'image/png')
    throw new BadRequestException('Use a JPEG or PNG photo.');
  return {
    reviewToken: fields.reviewToken,
    liveness: {
      blink: (liveness as Liveness).blink,
      turn: (liveness as Liveness).turn,
    },
    selfie: { bytes: file.buffer, contentType: file.mimetype },
  };
}
