import { BadRequestException, PayloadTooLargeException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import sharp from 'sharp';
import { maxImageBytes } from './identity.validation.js';

export async function normalizeImage(bytes: Buffer, contentType: string) {
  try {
    const source = sharp(bytes, {
      limitInputPixels: 4096 * 4096,
      failOn: 'warning',
    });
    const meta = await source.metadata();
    if (
      !meta.width ||
      !meta.height ||
      meta.width > 4096 ||
      meta.height > 4096 ||
      (meta.pages ?? 1) !== 1 ||
      !['jpeg', 'png'].includes(meta.format ?? '') ||
      `image/${meta.format}` !== contentType
    )
      throw new Error('unsupported');
    // Decode and re-encode, stripping EXIF/GPS and trailing non-image material.
    const clean = await source
      .rotate()
      .toFormat(meta.format as 'jpeg' | 'png')
      .toBuffer();
    if (clean.length > maxImageBytes)
      throw new PayloadTooLargeException('Decoded photo is too large.');
    return {
      bytes: clean,
      contentType,
      hash: createHash('sha256').update(clean).digest('hex'),
    };
  } catch (error) {
    if (error instanceof PayloadTooLargeException) throw error;
    throw new BadRequestException(
      'Use a readable, single JPEG or PNG photo up to 4096 by 4096 pixels.',
    );
  }
}
