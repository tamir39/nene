import {
  BadRequestException,
  Controller,
  ForbiddenException,
  Get,
  Header,
  NotFoundException,
  Param,
  Query,
  Req,
} from '@nestjs/common';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { DatabaseService } from '../database/database.service.js';
import { uuid } from '../customers/customer.validation.js';

export function historyQuery(query: Record<string, unknown>) {
  if (
    Object.keys(query).some((key) => !['month', 'cursor'].includes(key)) ||
    typeof query.month !== 'string' ||
    !/^(20\d{2}|2100)-(0[1-9]|1[0-2])$/.test(query.month)
  )
    throw new BadRequestException('Choose a month from 2000-01 to 2100-12.');
  return {
    month: query.month,
    cursor: query.cursor === undefined ? null : uuid(query.cursor, 'Cursor'),
  };
}
const monthRange =
  "h.posted_at >= (($3 || '-01')::date::timestamp at time zone 'Asia/Bangkok') and h.posted_at < ((($3 || '-01')::date + interval '1 month') at time zone 'Asia/Bangkok')";
@Controller('me/accounts/:accountId/history')
export class AccountHistoryController {
  constructor(private readonly db: DatabaseService) {}
  @Get()
  @Header('Cache-Control', 'no-store')
  async read(
    @Req() req: AuthenticatedRequest,
    @Param('accountId') rawId: unknown,
    @Query() query: Record<string, unknown>,
  ) {
    if (req.user.role !== 'customer')
      throw new ForbiddenException('A customer profile is required.');
    const id = uuid(rawId, 'Account ID'),
      { month, cursor } = historyQuery(query);
    const accounts = await this.db.query(
      'select id from bank.banking_accounts where id=$1 and owner_id=$2',
      [id, req.user.id],
    );
    if (!accounts.length) throw new NotFoundException('Account not found.');
    if (cursor) {
      const found = await this.db.query(
        `select h.id from bank.account_history h join bank.banking_accounts a on a.id=h.account_id where h.account_id=$1 and a.owner_id=$2 and ${monthRange} and h.id=$4`,
        [id, req.user.id, month, cursor],
      );
      if (!found.length)
        throw new BadRequestException(
          'History page is no longer available. Refresh this month.',
        );
    }
    const entries = await this.db.query<{
      id: string;
      reference: string;
      kind: string;
      direction: string;
      amountMinor: string;
      currency: string;
      postedAt: string;
    }>(
      `select h.id,h.operation_id as reference,h.kind,h.direction,h.amount_minor::text as "amountMinor",h.currency,to_char(h.posted_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as "postedAt" from bank.account_history h join bank.banking_accounts a on a.id=h.account_id where h.account_id=$1 and a.owner_id=$2 and ${monthRange} and ($4::uuid is null or (h.posted_at,h.id)<(select posted_at,id from bank.account_history where id=$4 and account_id=$1)) order by h.posted_at desc,h.id desc limit 26`,
      [id, req.user.id, month, cursor],
    );
    const page = entries.slice(0, 25);
    return {
      accountId: id,
      month,
      timeZone: 'Asia/Bangkok',
      entries: page,
      nextCursor: entries.length > 25 ? page[24]!.id : null,
    };
  }
}
