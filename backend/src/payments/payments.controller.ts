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
import { RETURN_PAGE_DEFAULT, RETURN_PAGE_RECEIVED } from './return-page.js';

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
  @Header('Content-Type', 'text/html; charset=utf-8')
  @Header(
    'Content-Security-Policy',
    "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  )
  @Header('X-Content-Type-Options', 'nosniff')
  @Header('Referrer-Policy', 'no-referrer')
  async returned(@Req() req: Request) {
    // VNPay signs the same result fields on the browser return as in the IPN.
    // Recording them through the IPN verifier keeps sandbox payments working
    // when no IPN URL is registered for the terminal: forged, altered, extra or
    // repeated values fail the same signature, order, amount and state checks.
    // Both pages are fixed documents; query values are never reflected, and the
    // "received" page only means a verified result was (or already was) recorded.
    const index = req.originalUrl.indexOf('?');
    if (index < 0) return RETURN_PAGE_DEFAULT;
    const result = await this.service
      .ipn(req.originalUrl.slice(index + 1))
      .catch(() => undefined);
    return result?.RspCode === '00' || result?.RspCode === '02'
      ? RETURN_PAGE_RECEIVED
      : RETURN_PAGE_DEFAULT;
  }
}
