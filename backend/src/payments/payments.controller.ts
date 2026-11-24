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
  async returned(@Req() req: Request) {
    // VNPay signs the same result fields on the browser return as in the IPN.
    // Recording them through the IPN verifier keeps sandbox payments working
    // when no IPN URL is registered for the terminal: forged, altered, extra or
    // repeated values fail the same signature, order, amount and state checks.
    // The page never reflects query values or the outcome.
    const index = req.originalUrl.indexOf('?');
    if (index >= 0)
      await this.service
        .ipn(req.originalUrl.slice(index + 1))
        .catch(() => undefined);
    return 'Return to your Nene tab and check payment status. Nene records a result only after verifying VNPay’s signature. Sign in again if your session has ended. These are sandbox payments; no real bill, phone credit, movie ticket, seat reservation or admission is fulfilled.';
  }
}
