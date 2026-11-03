import { Body, Controller, Get, Header, Post, Req } from '@nestjs/common';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { SecurityManagementService } from './security-management.service.js';
@Controller('me/security/management')
export class SecurityManagementController {
  constructor(private readonly service: SecurityManagementService) {}
  @Get() @Header('Cache-Control', 'no-store') status(
    @Req() req: AuthenticatedRequest,
  ) {
    return this.service.status(req);
  }
  @Post('start') @Header('Cache-Control', 'no-store') start(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.start(req, body);
  }
  @Post('prove') @Header('Cache-Control', 'no-store') prove(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.prove(req, body);
  }
  @Post('resume') @Header('Cache-Control', 'no-store') resume(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.prove(req, body, true);
  }
  @Post('enroll') @Header('Cache-Control', 'no-store') enroll(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.enroll(req, body);
  }
  @Post('verify') @Header('Cache-Control', 'no-store') verify(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.verify(req, body);
  }
  @Post('issue-codes') @Header('Cache-Control', 'no-store') issue(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.issue(req, body);
  }
  @Post('finish') @Header('Cache-Control', 'no-store') finish(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.finish(req, body);
  }
  @Post('cancel') @Header('Cache-Control', 'no-store') cancel(
    @Req() req: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.service.cancel(req, body);
  }
}
