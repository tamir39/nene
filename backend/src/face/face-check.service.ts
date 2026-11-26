import {
  BadRequestException,
  ConflictException,
  HttpException,
  Inject,
  Injectable,
  Logger,
  Optional,
  ServiceUnavailableException,
  UnprocessableEntityException,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { PoolClient } from 'pg';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { ENVIRONMENT } from '../config/config.module.js';
import type { Environment } from '../config/environment.js';
import { ConfirmationService } from '../confirmation/confirmation.service.js';
import { DatabaseService } from '../database/database.service.js';
import { normalizeImage } from '../identity/identity-image.js';
import { IdentityStorageService } from '../identity/identity-storage.service.js';
import type { FaceCheckInput } from './face-check.validation.js';
import { defaultFaceThreshold } from './face-match.service.js';
import { FaceMatcher, type FaceComparison } from './face-matcher.js';
import { faceCheckRequired } from './face-rule.js';

type Outcome = 'matched' | 'not_matched' | 'no_face' | 'multiple_faces';
type Row = {
  id: string;
  review_id: string;
  outcome: Outcome | 'pending' | 'error';
  expires_at: Date | null;
};

const failedAttemptsPerReview = 5;
const attemptsPerWindow = 10;
const messages: Record<Exclude<Outcome, 'matched'>, string> = {
  no_face:
    'No face was found. Hold the phone at eye level in good light and try again.',
  multiple_faces:
    'More than one face was found. Make sure only you are in the photo.',
  not_matched:
    'The photo did not match your reference photo. Look straight at the camera in good light and try again.',
};

function result(row: Row) {
  if (row.outcome === 'matched')
    return {
      faceCheckId: row.id,
      matched: true as const,
      expiresAt: row.expires_at!.toISOString(),
    };
  if (row.outcome === 'pending')
    throw new ConflictException(
      'This face check is still running. Wait a moment and check again.',
    );
  if (row.outcome === 'error')
    throw new ConflictException(
      'This face check could not be completed. Try again with a new request.',
    );
  throw new UnprocessableEntityException({
    statusCode: 422,
    matched: false,
    reason: row.outcome,
    message: messages[row.outcome],
  });
}

/**
 * Compares a selfie with the customer's accepted reference photo for one
 * high-value transfer review. The selfie is validated, compared in memory and
 * discarded; only the outcome, scores, device liveness flags and the review
 * binding are stored. Not eKYC, certified biometrics or active liveness.
 */
@Injectable()
export class FaceCheckService {
  private readonly logger = new Logger(FaceCheckService.name);
  private readonly threshold: number;

  constructor(
    private readonly db: DatabaseService,
    private readonly confirmation: ConfirmationService,
    private readonly storage: IdentityStorageService,
    private readonly matcher: FaceMatcher,
    @Optional() @Inject(ENVIRONMENT) env?: Environment,
  ) {
    this.threshold = env?.faceMatchThreshold ?? defaultFaceThreshold;
  }

  async check(req: AuthenticatedRequest, key: string, input: FaceCheckInput) {
    const { review, digest, purpose } = await this.confirmation.faceReview(
      req,
      input.reviewToken,
    );
    // Same validation and re-encoding as reference upload, before an attempt is counted.
    const selfie = await normalizeImage(
      input.selfie.bytes,
      input.selfie.contentType,
    );
    const reserved = await this.db.transaction((client) =>
      this.reserve(client, req.user.id, key, review, digest, purpose, input),
    );
    if ('replay' in reserved) return result(reserved.replay);

    let comparison: FaceComparison;
    try {
      const reference = await this.storage.read(reserved.objectKey);
      comparison = await this.matcher.compare(selfie.bytes, reference);
    } catch (error) {
      await this.finish(reserved.id, 'error');
      if (error instanceof HttpException) throw error;
      throw new ServiceUnavailableException(
        'Face verification is temporarily unavailable.',
      );
    }
    if (comparison.outcome === 'reference_unusable') {
      await this.finish(reserved.id, 'error');
      this.logger.warn(`Face check ${reserved.id}: reference unusable.`);
      throw new ConflictException({
        statusCode: 409,
        code: 'REFERENCE_UNUSABLE',
        message:
          'Your reference photo cannot be used for face checks. Ask an officer to review a new reference photo.',
      });
    }
    const row = await this.finish(
      reserved.id,
      comparison.outcome,
      comparison.score,
      comparison.antispoof,
    );
    // Advisory anti-spoof and device liveness are recorded, never enforced.
    this.logger.log(
      `Face check ${reserved.id}: ${comparison.outcome}, antispoof ${comparison.antispoof ?? 'n/a'}, device liveness ${JSON.stringify(input.liveness)}.`,
    );
    return result(row);
  }

  private async reserve(
    client: PoolClient,
    customer: string,
    key: string,
    review: Awaited<ReturnType<ConfirmationService['faceReview']>>['review'],
    digest: string,
    purpose: string,
    input: FaceCheckInput,
  ): Promise<{ replay: Row } | { id: string; objectKey: string }> {
    // The customer's authenticator row is the lock every transfer path uses.
    const binding = (
      await client.query<{
        factor_id: string;
        revision: number;
        state: string;
      }>(
        'select factor_id,revision,state from bank.authenticator_setup where customer_id=$1 for update',
        [customer],
      )
    ).rows[0];
    if (
      !binding ||
      binding.state !== 'ready' ||
      binding.factor_id !== review.factor ||
      binding.revision !== review.revision
    )
      throw new ConflictException(
        'Authenticator changed or is restricted. Review again after completing security setup.',
      );
    const prior = (
      await client.query<Row & { customer_id: string }>(
        'select id,customer_id,review_id,outcome,expires_at from bank.face_checks where customer_id=$1 and idempotency_key=$2',
        [customer, key],
      )
    ).rows[0];
    if (prior) {
      if (prior.review_id !== review.id)
        throw new ConflictException(
          'This request key was used for a different review.',
        );
      return { replay: prior };
    }
    if (!(await faceCheckRequired(client, customer, review.amountMinor)))
      throw new ConflictException(
        'This transfer does not need a face check. Continue with your authenticator code.',
      );
    const used = await client.query(
      'select id from bank.transaction_confirmations where id=$1',
      [review.id],
    );
    if (used.rows.length)
      throw new ConflictException(
        'This review was already submitted or cancelled. Start a new review.',
      );
    const reference = review.reference;
    const evidence = reference
      ? (
          await client.query<{ object_key: string }>(
            "select e.object_key from bank.identity_cases i join bank.identity_evidence e on e.id=i.evidence_id join bank.user_profiles p on p.id=i.customer_id where i.customer_id=$1 and i.id=$2 and i.version=$3 and i.revision=$4 and i.evidence_id=$5 and i.state='reference_accepted' and i.profile_name=p.display_name and i.expires_at>clock_timestamp() and e.case_id=i.id and e.revision=i.revision and e.status='ready' and e.deleted_at is null and e.expires_at>clock_timestamp()",
            [
              customer,
              reference.id,
              reference.version,
              reference.revision,
              reference.evidence_id,
            ],
          )
        ).rows[0]
      : undefined;
    if (!evidence)
      throw new BadRequestException(
        'An unchanged, unexpired accepted reference is required.',
      );
    const counts = (
      await client.query<{ failed: number; recent: number }>(
        "select count(*) filter (where review_id=$2 and outcome in ('not_matched','no_face','multiple_faces'))::int failed, count(*) filter (where created_at>clock_timestamp()-interval '15 minutes')::int recent from bank.face_checks where customer_id=$1",
        [customer, review.id],
      )
    ).rows[0]!;
    if (counts.failed >= failedAttemptsPerReview)
      throw new HttpException(
        'Too many failed face checks for this transfer. Start a new review later.',
        429,
      );
    if (counts.recent >= attemptsPerWindow)
      throw new HttpException(
        'Too many face checks. Wait 15 minutes and try again.',
        429,
      );
    const id = randomUUID();
    await client.query(
      'insert into bank.face_checks(id,customer_id,idempotency_key,review_id,review_digest,purpose,threshold,liveness) values($1,$2,$3,$4,$5,$6,$7,$8)',
      [
        id,
        customer,
        key,
        review.id,
        digest,
        purpose,
        this.threshold,
        JSON.stringify(input.liveness),
      ],
    );
    return { id, objectKey: evidence.object_key };
  }

  /** Records the result once; the database stamps completion and validity. */
  private async finish(
    id: string,
    outcome: Outcome | 'error',
    score: number | null = null,
    antispoof: number | null = null,
  ): Promise<Row> {
    const [row] = await this.db.query<Row>(
      "update bank.face_checks set outcome=$2,score=$3,antispoof_score=$4 where id=$1 and outcome='pending' returning id,review_id,outcome,expires_at",
      [id, outcome, score, antispoof],
    );
    if (!row)
      throw new ServiceUnavailableException(
        'Face check outcome is uncertain. Try again with a new request.',
      );
    return row;
  }
}
