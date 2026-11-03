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
import { ConfirmationService } from './confirmation.service.js';
@Controller('me/transfers')
export class TransfersController {
  constructor(private readonly service: ConfirmationService) {}
  @Get() @Header('Cache-Control', 'no-store') recent(
    @Req() req: AuthenticatedRequest,
  ) {
    return this.service.recent(req);
  }
  @Get('configuration') @Header('Cache-Control', 'no-store') configuration(
    @Req() req: AuthenticatedRequest,
  ) {
    return this.service.configuration(req);
  }
  @Post('review') @Header('Cache-Control', 'no-store') review(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.review(req, body, true);
  }
  @Post('confirm') @Header('Cache-Control', 'no-store') confirm(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.confirm(req, body, true);
  }
  @Post('cancel') @Header('Cache-Control', 'no-store') cancel(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.cancel(req, body, true);
  }
  @Get(':id') @Header('Cache-Control', 'no-store') status(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
  ) {
    return this.service.status(req, id, true);
  }
}
