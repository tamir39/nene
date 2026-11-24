import {
  Body,
  Controller,
  Get,
  Header,
  Param,
  Post,
  Req,
} from '@nestjs/common';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { cashOperation, ConfirmationService } from './confirmation.service.js';

@Controller('me/cash/:operation')
export class CashController {
  constructor(private readonly service: ConfirmationService) {}
  @Get() @Header('Cache-Control', 'no-store') recent(
    @Req() req: AuthenticatedRequest,
    @Param('operation') raw: string,
  ) {
    return this.service.recent(req, cashOperation(raw));
  }
  @Get('configuration') @Header('Cache-Control', 'no-store') configuration(
    @Req() req: AuthenticatedRequest,
    @Param('operation') raw: string,
  ) {
    return this.service.configuration(req, cashOperation(raw));
  }
  @Get(':id') @Header('Cache-Control', 'no-store') status(
    @Req() req: AuthenticatedRequest,
    @Param('operation') raw: string,
    @Param('id') id: string,
  ) {
    return this.service.status(req, id, cashOperation(raw));
  }
  @Post('review') @Header('Cache-Control', 'no-store') review(
    @Req() req: AuthenticatedRequest,
    @Param('operation') raw: string,
    @Body() body: unknown,
  ) {
    return this.service.review(req, body, cashOperation(raw));
  }
  @Post('confirm') @Header('Cache-Control', 'no-store') confirm(
    @Req() req: AuthenticatedRequest,
    @Param('operation') raw: string,
    @Body() body: unknown,
  ) {
    return this.service.confirm(req, body, cashOperation(raw));
  }
  @Post('cancel') @Header('Cache-Control', 'no-store') cancel(
    @Req() req: AuthenticatedRequest,
    @Param('operation') raw: string,
    @Body() body: unknown,
  ) {
    return this.service.cancel(req, body, cashOperation(raw));
  }
}
