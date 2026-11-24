import {
  Body,
  Controller,
  Get,
  Header,
  Headers,
  Param,
  Post,
  Req,
  StreamableFile,
} from '@nestjs/common';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { uuid } from '../customers/customer.validation.js';
import { IdentityService } from './identity.service.js';
import {
  evidenceInput,
  reviewInput,
  startInput,
  submitInput,
} from './identity.validation.js';

@Controller()
export class IdentityController {
  constructor(private readonly identity: IdentityService) {}

  @Get('me/identity')
  @Header('Cache-Control', 'no-store')
  ownStatus(@Req() request: AuthenticatedRequest) {
    this.identity.customer(request.user);
    return this.identity.status(request.user, request.user.id);
  }
  @Get('officer/customers/:id/identity')
  @Header('Cache-Control', 'no-store')
  customerStatus(
    @Req() request: AuthenticatedRequest,
    @Param('id') id: unknown,
  ) {
    this.identity.officer(request.user);
    return this.identity.status(request.user, uuid(id));
  }
  @Post('me/identity/cases')
  @Header('Cache-Control', 'no-store')
  ownStart(
    @Req() request: AuthenticatedRequest,
    @Headers('idempotency-key') key: unknown,
    @Body() body: unknown,
  ) {
    this.identity.customer(request.user);
    return this.identity.start(
      request.user,
      request.user.id,
      uuid(key, 'Idempotency-Key'),
      startInput(body),
    );
  }
  @Post('officer/customers/:id/identity/cases')
  @Header('Cache-Control', 'no-store')
  assistedStart(
    @Req() request: AuthenticatedRequest,
    @Param('id') id: unknown,
    @Headers('idempotency-key') key: unknown,
    @Body() body: unknown,
  ) {
    this.identity.officer(request.user);
    return this.identity.start(
      request.user,
      uuid(id),
      uuid(key, 'Idempotency-Key'),
      startInput(body),
    );
  }
  @Get('identity/cases/:caseId')
  @Header('Cache-Control', 'no-store')
  status(@Req() request: AuthenticatedRequest, @Param('caseId') id: unknown) {
    return this.identity.caseStatus(request.user, uuid(id, 'Case ID'));
  }
  @Post('identity/cases/:caseId/evidence')
  @Header('Cache-Control', 'no-store')
  upload(
    @Req() request: AuthenticatedRequest,
    @Param('caseId') id: unknown,
    @Headers('idempotency-key') key: unknown,
    @Body() body: unknown,
  ) {
    return this.identity.upload(
      request.user,
      uuid(id, 'Case ID'),
      uuid(key, 'Idempotency-Key'),
      evidenceInput(body),
    );
  }
  @Get('identity/cases/:caseId/evidence/:evidenceId')
  @Header('Cache-Control', 'no-store')
  @Header('X-Content-Type-Options', 'nosniff')
  async readEvidence(
    @Req() request: AuthenticatedRequest,
    @Param('caseId') id: unknown,
    @Param('evidenceId') evidenceId: unknown,
  ) {
    const photo = await this.identity.readEvidence(
      request.user,
      uuid(id, 'Case ID'),
      uuid(evidenceId, 'Evidence ID'),
    );
    return new StreamableFile(photo.bytes, {
      type: photo.contentType,
      length: photo.bytes.length,
      disposition: 'inline',
    });
  }
  @Post('identity/cases/:caseId/submit')
  @Header('Cache-Control', 'no-store')
  submit(
    @Req() request: AuthenticatedRequest,
    @Param('caseId') id: unknown,
    @Headers('idempotency-key') key: unknown,
    @Body() body: unknown,
  ) {
    return this.identity.submit(
      request.user,
      uuid(id, 'Case ID'),
      uuid(key, 'Idempotency-Key'),
      submitInput(body),
    );
  }
  @Post('officer/identity/cases/:caseId/reviews')
  @Header('Cache-Control', 'no-store')
  review(
    @Req() request: AuthenticatedRequest,
    @Param('caseId') id: unknown,
    @Headers('idempotency-key') key: unknown,
    @Body() body: unknown,
  ) {
    this.identity.officer(request.user);
    return this.identity.review(
      request.user,
      uuid(id, 'Case ID'),
      uuid(key, 'Idempotency-Key'),
      reviewInput(body),
    );
  }
}
