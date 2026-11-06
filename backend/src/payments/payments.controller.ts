import {
  Body,
  Controller,
  Get,
  Header,
  Param,
  Post,
  Req,
} from '@nestjs/common';
import type { Request } from 'express';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { Public } from '../auth/public.decorator.js';
import { PaymentsService } from './payments.service.js';

@Controller('me/payments')
export class PaymentsController {
  constructor(private readonly service: PaymentsService) {}
  @Get('configuration') @Header('Cache-Control', 'no-store') configuration(
    @Req() req: AuthenticatedRequest,
  ) {
    return this.service.configuration(req);
  }
  @Get() @Header('Cache-Control', 'no-store') recent(
    @Req() req: AuthenticatedRequest,
  ) {
    return this.service.recent(req);
  }
  @Post('review') @Header('Cache-Control', 'no-store') review(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.review(req, body);
  }
  @Post('preview') @Header('Cache-Control', 'no-store') preview(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.preview(req, body);
  }
  @Post('confirm') @Header('Cache-Control', 'no-store') confirm(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.confirm(req, body);
  }
  @Get(':id') @Header('Cache-Control', 'no-store') status(
    @Req() req: AuthenticatedRequest,
    @Param('id') id: string,
  ) {
    return this.service.status(req, id);
  }
}

@Controller('payments/vnpay')
export class VnpayCallbacksController {
  constructor(private readonly service: PaymentsService) {}
  @Public() @Get('ipn') @Header('Cache-Control', 'no-store') ipn(
    @Req() req: Request,
  ) {
    const index = req.originalUrl.indexOf('?');
    return this.service.ipn(index < 0 ? '' : req.originalUrl.slice(index + 1));
  }
  @Public()
  @Get('return')
  @Header('Cache-Control', 'no-store')
  @Header('Content-Type', 'text/plain; charset=utf-8')
  @Header('X-Content-Type-Options', 'nosniff')
  @Header('Referrer-Policy', 'no-referrer')
  returned() {
    return 'Return to your Nene tab and check payment status. This redirect does not confirm payment. Sign in again if your session has ended. These are sandbox payments; no real bill, phone credit, movie ticket, seat reservation or admission is fulfilled.';
  }
}
