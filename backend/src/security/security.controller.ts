import { Body, Controller, Get, Header, Post, Req } from '@nestjs/common';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { SecurityService } from './security.service.js';

@Controller('me/security')
export class SecurityController {
  constructor(private readonly security: SecurityService) {}
  @Get()
  @Header('Cache-Control', 'no-store')
  status(@Req() req: AuthenticatedRequest) {
    return this.security.status(req);
  }
  @Post('setup')
  @Header('Cache-Control', 'no-store')
  start(@Req() req: AuthenticatedRequest) {
    return this.security.start(req);
  }
  @Post('verify')
  @Header('Cache-Control', 'no-store')
  verify(@Req() req: AuthenticatedRequest, @Body() body: unknown) {
    return this.security.verify(req, body);
  }
}
