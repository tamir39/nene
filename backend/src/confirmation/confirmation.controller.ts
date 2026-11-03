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
@Controller('me/transfer-confirmations')
export class ConfirmationController {
  constructor(private readonly service: ConfirmationService) {}
  @Post('review') @Header('Cache-Control', 'no-store') review(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.review(req, body);
  }
  @Post('confirm') @Header('Cache-Control', 'no-store') confirm(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.confirm(req, body);
  }
  @Post('cancel') @Header('Cache-Control', 'no-store') cancel(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.cancel(req, body);
  }
  @Get(':id') @Header('Cache-Control', 'no-store') status(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
  ) {
    return this.service.status(req, id);
  }
}
