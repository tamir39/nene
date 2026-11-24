import {
  ConflictException,
  ForbiddenException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import type { PoolClient, QueryResultRow } from 'pg';
import type { CurrentUser } from '../auth/auth.types.js';
import { DatabaseService } from '../database/database.service.js';
import { IdentityStorageService } from './identity-storage.service.js';
import { normalizeImage } from './identity-image.js';
import {
  notice,
  type evidenceInput,
  type reviewInput,
  type startInput,
  type submitInput,
} from './identity.validation.js';

interface CustomerRow extends QueryResultRow {
  id: string;
  display_name: string;
}
interface CaseRow extends QueryResultRow {
  id: string;
  customer_id: string;
  state: 'draft' | 'submitted' | 'needs_changes' | 'reference_accepted';
  version: number;
  revision: number;
  profile_name: string;
  evidence_id: string | null;
  correction_reason: string | null;
  expires_at: Date;
}
interface EvidenceRow extends QueryResultRow {
  id: string;
  case_id: string;
  revision: number;
  object_key: string;
  content_hash: string;
  content_type: string;
  status: string;
  expires_at: Date;
  deleted_at: Date | null;
}
interface CommandRow extends QueryResultRow {
  customer_id: string;
  action: string;
  payload_hash: string;
  case_id: string | null;
  evidence_id: string | null;
  completed_at: Date | null;
}
export interface IdentitySummary {
  customerId: string;
  customerName: string;
  status: CaseRow['state'] | 'not_started';
  caseId: string | null;
  version: number | null;
  revision: number | null;
  evidenceId: string | null;
  correctionReason: string | null;
  expiresAt: string | null;
  expired: boolean;
  notice: typeof notice;
  allowedActions: string[];
}
const expiredReason = 'This reference expired. Start again with a new photo.';
function hash(value: unknown) {
  return createHash('sha256').update(JSON.stringify(value)).digest('hex');
}
function isExpired(row: CaseRow) {
  return row.expires_at.getTime() <= Date.now();
}

@Injectable()
export class IdentityService {
  constructor(
    private readonly database: DatabaseService,
    private readonly storage: IdentityStorageService,
  ) {}

  officer(user: CurrentUser) {
    if (user.role !== 'officer')
      throw new ForbiddenException('An officer profile is required.');
  }
  customer(user: CurrentUser) {
    if (user.role !== 'customer')
      throw new ForbiddenException('A customer profile is required.');
  }
  private async customerRow(
    client: PoolClient,
    user: CurrentUser,
    id: string,
    lock = false,
  ): Promise<CustomerRow> {
    if (user.role !== 'officer' && user.id !== id)
      throw new NotFoundException('Identity reference was not found.');
    const result = await client.query<CustomerRow>(
      `SELECT id, display_name FROM bank.user_profiles WHERE id = $1 AND role = 'customer' AND status = 'active' ${lock ? 'FOR UPDATE' : ''}`,
      [id],
    );
    const row = result.rows[0];
    if (!row) throw new NotFoundException('Identity reference was not found.');
    return row;
  }
  private async caseRow(
    client: PoolClient,
    customerId: string,
    lock = false,
  ): Promise<CaseRow | undefined> {
    return (
      await client.query<CaseRow>(
        `SELECT * FROM bank.identity_cases WHERE customer_id = $1 ${lock ? 'FOR UPDATE' : ''}`,
        [customerId],
      )
    ).rows[0];
  }
  private summary(
    user: CurrentUser,
    customer: CustomerRow,
    row?: CaseRow,
  ): IdentitySummary {
    const expired = !!row && isExpired(row);
    const status = expired ? 'needs_changes' : (row?.state ?? 'not_started');
    const allowedActions: string[] = [];
    if (status === 'not_started' || status === 'needs_changes')
      allowedActions.push('start');
    if (status === 'draft') {
      allowedActions.push('capture');
      if (row?.evidence_id) allowedActions.push('submit');
    }
    if (status === 'submitted' && user.role === 'officer')
      allowedActions.push('accept_reference', 'request_changes');
    return {
      customerId: customer.id,
      customerName: customer.display_name,
      status,
      caseId: row?.id ?? null,
      version: row?.version ?? null,
      revision: row?.revision ?? null,
      evidenceId: expired ? null : (row?.evidence_id ?? null),
      correctionReason: expired
        ? expiredReason
        : (row?.correction_reason ?? null),
      expiresAt: row?.expires_at.toISOString() ?? null,
      expired,
      notice,
      allowedActions,
    };
  }
  async status(
    user: CurrentUser,
    customerId: string,
  ): Promise<IdentitySummary> {
    return this.database.transaction(async (client) => {
      const customer = await this.customerRow(client, user, customerId);
      return this.summary(
        user,
        customer,
        await this.caseRow(client, customerId),
      );
    });
  }
  private async caseCustomer(
    user: CurrentUser,
    caseId: string,
  ): Promise<string> {
    const rows = await this.database.query<{ customer_id: string }>(
      `SELECT c.customer_id FROM bank.identity_cases c JOIN bank.user_profiles p ON p.id = c.customer_id
       WHERE c.id = $1 AND p.role = 'customer' AND p.status = 'active' AND ($2 = 'officer' OR c.customer_id = $3)`,
      [caseId, user.role, user.id],
    );
    if (!rows[0])
      throw new NotFoundException('Identity reference was not found.');
    return rows[0].customer_id;
  }
  async caseStatus(user: CurrentUser, caseId: string) {
    return this.status(user, await this.caseCustomer(user, caseId));
  }

  private async command(
    client: PoolClient,
    user: CurrentUser,
    customerId: string,
    key: string,
    action: string,
    payload: unknown,
  ) {
    const digest = hash(payload);
    await client.query(
      `INSERT INTO bank.identity_commands (actor_id,idempotency_key,customer_id,action,payload_hash) VALUES ($1,$2,$3,$4,$5) ON CONFLICT (actor_id,idempotency_key) DO NOTHING`,
      [user.id, key, customerId, action, digest],
    );
    const row = (
      await client.query<CommandRow>(
        `SELECT * FROM bank.identity_commands WHERE actor_id=$1 AND idempotency_key=$2 FOR UPDATE`,
        [user.id, key],
      )
    ).rows[0];
    if (
      !row ||
      row.customer_id !== customerId ||
      row.action !== action ||
      row.payload_hash !== digest
    )
      throw new ConflictException(
        'This request key was used for different details. Check status before starting another request.',
      );
    return row;
  }
  private async complete(
    client: PoolClient,
    user: CurrentUser,
    key: string,
    caseId: string,
  ) {
    await client.query(
      'UPDATE bank.identity_commands SET case_id=$3, completed_at=now() WHERE actor_id=$1 AND idempotency_key=$2',
      [user.id, key, caseId],
    );
  }
  private assertVersion(
    row: CaseRow | undefined,
    caseId: string,
    expectedVersion: number,
    state: CaseRow['state'],
  ) {
    if (
      !row ||
      row.id !== caseId ||
      row.version !== expectedVersion ||
      row.state !== state ||
      isExpired(row)
    )
      throw new ConflictException(
        'The reference changed or expired. Check status and review the latest version.',
      );
    return row;
  }

  async start(
    user: CurrentUser,
    customerId: string,
    key: string,
    input: ReturnType<typeof startInput>,
  ) {
    this.storage.assertAvailable();
    return this.database.transaction(async (client) => {
      const customer = await this.customerRow(client, user, customerId, true);
      const command = await this.command(
        client,
        user,
        customerId,
        key,
        'start',
        input,
      );
      let row = await this.caseRow(client, customerId, true);
      if (command.completed_at) return this.summary(user, customer, row);
      if (!row) {
        row = (
          await client.query<CaseRow>(
            `INSERT INTO bank.identity_cases
          (id,customer_id,profile_name,notice_version,acknowledged_by,acknowledged_role)
          VALUES ($1,$2,$3,$4,$5,$6) RETURNING *`,
            [
              randomUUID(),
              customerId,
              customer.display_name,
              notice.version,
              user.id,
              user.role,
            ],
          )
        ).rows[0]!;
      } else if (row.state === 'needs_changes' || isExpired(row)) {
        row = (
          await client.query<CaseRow>(
            `UPDATE bank.identity_cases SET state='draft',version=version+1,revision=revision+1,
          profile_name=$2,notice_version=$3,acknowledged_by=$4,acknowledged_role=$5,evidence_id=NULL,
          correction_reason=NULL,reviewed_by=NULL,reviewed_at=NULL,expires_at=now()+interval '7 days',updated_at=now()
          WHERE id=$1 RETURNING *`,
            [row.id, customer.display_name, notice.version, user.id, user.role],
          )
        ).rows[0]!;
      } else if (row.state !== 'draft') {
        throw new ConflictException(
          'This reference has already been submitted. Check its status.',
        );
      }
      await this.complete(client, user, key, row.id);
      return this.summary(user, customer, row);
    });
  }

  async upload(
    user: CurrentUser,
    caseId: string,
    key: string,
    input: ReturnType<typeof evidenceInput>,
  ) {
    const customerId = await this.caseCustomer(user, caseId);
    this.storage.assertAvailable();
    const image = await normalizeImage(input.bytes, input.contentType);
    const payload = {
      caseId,
      expectedVersion: input.expectedVersion,
      contentType: image.contentType,
      hash: image.hash,
    };
    const reservation = await this.database.transaction(async (client) => {
      const customer = await this.customerRow(client, user, customerId, true);
      const command = await this.command(
        client,
        user,
        customerId,
        key,
        'upload',
        payload,
      );
      const row = await this.caseRow(client, customerId, true);
      if (command.completed_at)
        return { summary: this.summary(user, customer, row) };
      const current = this.assertVersion(
        row,
        caseId,
        input.expectedVersion,
        'draft',
      );
      let evidence: EvidenceRow;
      if (command.evidence_id) {
        evidence = (
          await client.query<EvidenceRow>(
            'SELECT * FROM bank.identity_evidence WHERE id=$1 AND case_id=$2',
            [command.evidence_id, caseId],
          )
        ).rows[0]!;
        if (
          !evidence ||
          evidence.deleted_at ||
          evidence.expires_at.getTime() <= Date.now()
        )
          throw new ConflictException(
            'The reserved upload expired. Check status and take a new photo.',
          );
      } else {
        const id = randomUUID();
        evidence = (
          await client.query<EvidenceRow>(
            `INSERT INTO bank.identity_evidence
          (id,case_id,revision,object_key,content_hash,content_type,byte_size,expires_at,profile_name)
          VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *`,
            [
              id,
              caseId,
              current.revision + 1,
              `${customerId}/${caseId}/${id}`,
              image.hash,
              image.contentType,
              image.bytes.length,
              current.expires_at,
              customer.display_name,
            ],
          )
        ).rows[0]!;
        await client.query(
          'UPDATE bank.identity_commands SET case_id=$3,evidence_id=$4 WHERE actor_id=$1 AND idempotency_key=$2',
          [user.id, key, caseId, id],
        );
      }
      return { evidence };
    });
    if (reservation.summary) return reservation.summary;
    const evidence = reservation.evidence!;
    return this.database.transaction(async (client) => {
      const customer = await this.customerRow(client, user, customerId, true);
      const command = await this.command(
        client,
        user,
        customerId,
        key,
        'upload',
        payload,
      );
      const row = await this.caseRow(client, customerId, true);
      if (command.completed_at) return this.summary(user, customer, row);
      this.assertVersion(row, caseId, input.expectedVersion, 'draft');
      const eligible = await client.query(
        `SELECT id FROM bank.identity_evidence WHERE id=$1 AND case_id=$2 AND deleted_at IS NULL
         AND expires_at>now() AND created_at>now()-interval '24 hours' FOR UPDATE`,
        [evidence.id, caseId],
      );
      if (!eligible.rows[0])
        throw new ConflictException(
          'The upload reservation expired. Check status before retrying.',
        );
      // This bounded write shares cleanup's profile/case lock so a late upload
      // cannot recreate an already tombstoned object. The reservation is committed first.
      await this.storage.write(
        evidence.object_key,
        image.bytes,
        image.contentType,
        image.hash,
      );
      const updated = await client.query(
        `UPDATE bank.identity_evidence SET status='ready',ready_at=now()
        WHERE id=$1 AND case_id=$2 AND deleted_at IS NULL AND expires_at>now() AND created_at>now()-interval '24 hours' RETURNING id`,
        [evidence.id, caseId],
      );
      if (!updated.rows[0])
        throw new ConflictException(
          'The upload reservation expired. Check status before retrying.',
        );
      const current = (
        await client.query<CaseRow>(
          `UPDATE bank.identity_cases SET evidence_id=$2,revision=$3,version=version+1,updated_at=now() WHERE id=$1 RETURNING *`,
          [caseId, evidence.id, evidence.revision],
        )
      ).rows[0]!;
      await this.complete(client, user, key, caseId);
      return this.summary(user, customer, current);
    });
  }

  async submit(
    user: CurrentUser,
    caseId: string,
    key: string,
    input: ReturnType<typeof submitInput>,
  ) {
    const customerId = await this.caseCustomer(user, caseId);
    return this.database.transaction(async (client) => {
      const customer = await this.customerRow(client, user, customerId, true);
      const command = await this.command(
        client,
        user,
        customerId,
        key,
        'submit',
        { caseId, ...input },
      );
      const row = await this.caseRow(client, customerId, true);
      if (command.completed_at) return this.summary(user, customer, row);
      const current = this.assertVersion(
        row,
        caseId,
        input.expectedVersion,
        'draft',
      );
      if (!current.evidence_id)
        throw new ConflictException(
          'Upload a reference photo before submitting.',
        );
      const evidence = (
        await client.query<EvidenceRow>(
          `SELECT * FROM bank.identity_evidence WHERE id=$1 AND case_id=$2 AND revision=$3 AND status='ready' AND deleted_at IS NULL AND expires_at>now()`,
          [current.evidence_id, caseId, current.revision],
        )
      ).rows[0];
      if (!evidence)
        throw new ConflictException(
          'The reference photo is not ready. Upload a new photo.',
        );
      const result = (
        await client.query<CaseRow>(
          `UPDATE bank.identity_cases SET state='submitted',version=version+1,updated_at=now() WHERE id=$1 RETURNING *`,
          [caseId],
        )
      ).rows[0]!;
      await this.complete(client, user, key, caseId);
      return this.summary(user, customer, result);
    });
  }

  async review(
    user: CurrentUser,
    caseId: string,
    key: string,
    input: ReturnType<typeof reviewInput>,
  ) {
    this.officer(user);
    const customerId = await this.caseCustomer(user, caseId);
    return this.database.transaction(async (client) => {
      const customer = await this.customerRow(client, user, customerId, true);
      const command = await this.command(
        client,
        user,
        customerId,
        key,
        input.action,
        { caseId, ...input },
      );
      const row = await this.caseRow(client, customerId, true);
      if (command.completed_at) return this.summary(user, customer, row);
      const current = this.assertVersion(
        row,
        caseId,
        input.expectedVersion,
        'submitted',
      );
      const ready = await client.query(
        `SELECT id FROM bank.identity_evidence WHERE id=$1 AND case_id=$2 AND revision=$3 AND status='ready' AND deleted_at IS NULL AND expires_at>now()`,
        [current.evidence_id, caseId, current.revision],
      );
      if (!ready.rows[0] || current.profile_name !== customer.display_name)
        throw new ConflictException(
          'The reference changed or expired. Ask for a new photo.',
        );
      await client.query(
        `INSERT INTO bank.identity_reviews (id,case_id,actor_id,revision,action,reason) VALUES ($1,$2,$3,$4,$5,$6)`,
        [
          randomUUID(),
          caseId,
          user.id,
          current.revision,
          input.action,
          input.reason,
        ],
      );
      const result = (
        await client.query<CaseRow>(
          `UPDATE bank.identity_cases SET state=$2,version=version+1,correction_reason=$3,reviewed_by=$4,reviewed_at=now(),updated_at=now() WHERE id=$1 RETURNING *`,
          [
            caseId,
            input.action === 'accept_reference'
              ? 'reference_accepted'
              : 'needs_changes',
            input.reason,
            user.id,
          ],
        )
      ).rows[0]!;
      await this.complete(client, user, key, caseId);
      return this.summary(user, customer, result);
    });
  }

  async readEvidence(user: CurrentUser, caseId: string, evidenceId: string) {
    const customerId = await this.caseCustomer(user, caseId);
    const row = await this.database.transaction(async (client) => {
      await this.customerRow(client, user, customerId, true);
      const current = await this.caseRow(client, customerId, true);
      if (!current || current.evidence_id !== evidenceId || isExpired(current))
        throw new NotFoundException('Reference photo was not found.');
      const evidence = (
        await client.query<EvidenceRow>(
          `SELECT * FROM bank.identity_evidence WHERE id=$1 AND case_id=$2 AND revision=$3 AND status='ready' AND deleted_at IS NULL AND expires_at>now()`,
          [evidenceId, caseId, current.revision],
        )
      ).rows[0];
      if (!evidence)
        throw new NotFoundException('Reference photo was not found.');
      return evidence;
    });
    const bytes = await this.storage.read(row.object_key);
    // Recheck after storage I/O, so name/review/expiry changes do not expose stale evidence.
    const latest = await this.status(user, customerId);
    if (latest.evidenceId !== evidenceId || latest.expired)
      throw new NotFoundException('Reference photo was not found.');
    return { bytes, contentType: row.content_type };
  }

  async cleanup(): Promise<{ removed: number }> {
    this.storage.assertAvailable();
    let removed = 0;
    const candidates = await this.database.query<EvidenceRow>(
      `SELECT * FROM bank.identity_evidence WHERE deleted_at IS NULL
      AND (expires_at<=now() OR (status='pending' AND created_at<=now()-interval '24 hours')) ORDER BY created_at LIMIT 100`,
      [],
    );
    for (const evidence of candidates) {
      await this.database.transaction(async (client) => {
        // Serialize with profile edits and reference mutations before touching storage.
        const selected = await client.query<{ customer_id: string }>(
          'SELECT customer_id FROM bank.identity_cases WHERE id=$1',
          [evidence.case_id],
        );
        if (!selected.rows[0]) return;
        await client.query(
          'SELECT id FROM bank.user_profiles WHERE id=$1 FOR UPDATE',
          [selected.rows[0].customer_id],
        );
        const row = (
          await client.query<CaseRow>(
            'SELECT * FROM bank.identity_cases WHERE id=$1 FOR UPDATE',
            [evidence.case_id],
          )
        ).rows[0]!;
        const eligible = await client.query(
          `SELECT id FROM bank.identity_evidence WHERE id=$1 AND deleted_at IS NULL AND
          (expires_at<=now() OR (status='pending' AND created_at<=now()-interval '24 hours')) FOR UPDATE`,
          [evidence.id],
        );
        if (!eligible.rows[0]) return;
        if (row.evidence_id === evidence.id) {
          await client.query(
            `UPDATE bank.identity_cases SET state='needs_changes',version=version+1,evidence_id=NULL,correction_reason=$2,reviewed_by=NULL,reviewed_at=NULL,updated_at=now() WHERE id=$1`,
            [row.id, expiredReason],
          );
          await client.query(
            `INSERT INTO bank.identity_reviews (id,case_id,actor_id,revision,action,reason) VALUES ($1,$2,NULL,$3,'expired',$4)`,
            [randomUUID(), row.id, row.revision, expiredReason],
          );
        }
        await this.storage.remove(evidence.object_key);
        await client.query(
          'UPDATE bank.identity_evidence SET deleted_at=now() WHERE id=$1',
          [evidence.id],
        );
        removed++;
      });
    }
    return { removed };
  }
}
