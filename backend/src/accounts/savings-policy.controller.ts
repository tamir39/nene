import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  ForbiddenException,
  Get,
  Header,
  Patch,
  Req,
} from '@nestjs/common';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { DatabaseService } from '../database/database.service.js';

export function rateInput(value: unknown) {
  const data = value as {
    annualRateBps?: unknown;
    revision?: unknown;
    reason?: unknown;
  } | null;
  if (
    !data ||
    Object.keys(data).some(
      (k) => !['annualRateBps', 'revision', 'reason'].includes(k),
    ) ||
    typeof data.annualRateBps !== 'number' ||
    !Number.isInteger(data.annualRateBps) ||
    data.annualRateBps < 0 ||
    data.annualRateBps > 2000 ||
    typeof data.revision !== 'number' ||
    !Number.isSafeInteger(data.revision) ||
    data.revision < 1 ||
    typeof data.reason !== 'string' ||
    data.reason.trim().length < 5 ||
    data.reason.trim().length > 500
  )
    throw new BadRequestException(
      'Use a rate from 0 to 20%, a current revision and a reason.',
    );
  return {
    annualRateBps: data.annualRateBps,
    revision: data.revision,
    reason: data.reason.trim(),
  };
}
@Controller('officer/savings-policy')
export class SavingsPolicyController {
  constructor(private readonly db: DatabaseService) {}
  private officer(req: AuthenticatedRequest) {
    if (req.user.role !== 'officer') throw new ForbiddenException();
  }
  @Get()
  @Header('Cache-Control', 'no-store')
  async read(@Req() req: AuthenticatedRequest) {
    this.officer(req);
    const [row] = await this.db.query(
      'select annual_rate_bps as "annualRateBps",revision from bank.savings_policy where id',
      [],
    );
    return row;
  }
  @Patch()
  @Header('Cache-Control', 'no-store')
  async edit(@Req() req: AuthenticatedRequest, @Body() body: unknown) {
    this.officer(req);
    const input = rateInput(body);
    return this.db.transaction(async (client) => {
      const old = await client.query<{
        annual_rate_bps: number;
        revision: number;
      }>(
        'select annual_rate_bps,revision from bank.savings_policy where id for update',
      );
      const row = old.rows[0];
      if (!row || row.revision !== input.revision)
        throw new ConflictException('Rate changed. Reload before saving.');
      const result = await client.query(
        'update bank.savings_policy set annual_rate_bps=$1,revision=revision+1,updated_at=now() where id returning annual_rate_bps as "annualRateBps",revision',
        [input.annualRateBps],
      );
      await client.query(
        'insert into bank.savings_rate_audit(officer_id,old_bps,new_bps,revision,reason) values($1,$2,$3,$4,$5)',
        [
          req.user.id,
          row.annual_rate_bps,
          input.annualRateBps,
          row.revision + 1,
          input.reason,
        ],
      );
      return result.rows[0];
    });
  }
}
