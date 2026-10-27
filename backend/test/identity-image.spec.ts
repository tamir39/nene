import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { BadRequestException, PayloadTooLargeException } from '@nestjs/common';
import sharp from 'sharp';
import { normalizeImage } from '../src/identity/identity-image.js';
import {
  evidenceInput,
  maxImageBytes,
  notice,
  reviewInput,
  startInput,
  submitInput,
} from '../src/identity/identity.validation.js';

void describe('reference input and image boundaries (synthetic pixels only)', () => {
  void it('requires explicit current notice acknowledgement and rejects extra authority fields', () => {
    assert.equal(
      startInput({ noticeVersion: notice.version, acknowledged: true })
        .noticeVersion,
      notice.version,
    );
    for (const value of [
      { noticeVersion: notice.version, acknowledged: false },
      { noticeVersion: 'old', acknowledged: true },
      { noticeVersion: notice.version, acknowledged: true, role: 'officer' },
    ])
      assert.throws(() => startInput(value), BadRequestException);
  });
  void it('acceptance requires association confirmation and corrections require a meaningful reason', () => {
    assert.equal(
      reviewInput({
        expectedVersion: 1,
        action: 'accept_reference',
        associationConfirmed: true,
        reason: null,
      }).action,
      'accept_reference',
    );
    for (const value of [
      {
        expectedVersion: 1,
        action: 'accept_reference',
        associationConfirmed: false,
        reason: null,
      },
      {
        expectedVersion: 1,
        action: 'request_changes',
        associationConfirmed: false,
        reason: 'x',
      },
      {
        expectedVersion: 1,
        action: 'accept_reference',
        associationConfirmed: true,
        reason: null,
        isVerified: true,
      },
      {
        expectedVersion: 1,
        action: 'verify',
        associationConfirmed: true,
        reason: null,
      },
    ])
      assert.throws(() => reviewInput(value), BadRequestException);
    assert.throws(
      () => submitInput({ expectedVersion: 0 }),
      BadRequestException,
    );
  });
  void it('validates a full 10 MiB base64 envelope without regex stack exhaustion and rejects larger input', () => {
    assert.throws(
      () =>
        evidenceInput({
          expectedVersion: 1,
          contentType: { toString: 'invalid' },
          dataBase64: 'AAAA',
        }),
      BadRequestException,
    );
    const dataBase64 = Buffer.alloc(maxImageBytes, 255).toString('base64');
    assert.equal(
      evidenceInput({
        expectedVersion: 1,
        contentType: 'image/png',
        dataBase64,
      }).bytes.length,
      maxImageBytes,
    );
    assert.throws(
      () =>
        evidenceInput({
          expectedVersion: 1,
          contentType: 'image/png',
          dataBase64: dataBase64 + 'AAAA',
        }),
      PayloadTooLargeException,
    );
    for (const invalid of [
      'data:image/png;base64,AAAA',
      'A===',
      'AAAA\n',
      '/x==',
    ])
      assert.throws(
        () =>
          evidenceInput({
            expectedVersion: 1,
            contentType: 'image/png',
            dataBase64: invalid,
          }),
        BadRequestException,
      );
  });
  void it('decodes and re-encodes actual pixels, removes embedded metadata and retains the declared format', async () => {
    const pixels = await sharp({
      create: { width: 8, height: 12, channels: 3, background: '#4c929e' },
    })
      .jpeg()
      .withMetadata({ exif: { IFD0: { Artist: 'SYNTHETIC_TEST_METADATA' } } })
      .toBuffer();
    const result = await normalizeImage(pixels, 'image/jpeg');
    assert.equal(result.contentType, 'image/jpeg');
    assert.match(result.hash, /^[a-f0-9]{64}$/);
    const meta = await sharp(result.bytes).metadata();
    assert.equal(meta.width, 8);
    assert.equal(meta.height, 12);
    assert.equal(meta.exif, undefined);
    assert.equal(
      result.bytes.includes(Buffer.from('SYNTHETIC_TEST_METADATA')),
      false,
    );
  });
  void it('rejects claimed PNG with JPEG bytes, malformed input and oversized dimensions', async () => {
    const jpeg = await sharp({
      create: { width: 4, height: 4, channels: 3, background: '#f6c9a5' },
    })
      .jpeg()
      .toBuffer();
    await assert.rejects(
      normalizeImage(jpeg, 'image/png'),
      BadRequestException,
    );
    await assert.rejects(
      normalizeImage(Buffer.from('<svg></svg>'), 'image/png'),
      BadRequestException,
    );
    await assert.rejects(
      normalizeImage(Buffer.from('not a photo'), 'image/jpeg'),
      BadRequestException,
    );
    const wide = await sharp({
      create: { width: 4097, height: 1, channels: 3, background: '#4c929e' },
    })
      .png()
      .toBuffer();
    await assert.rejects(
      normalizeImage(wide, 'image/png'),
      BadRequestException,
    );
  });
});
