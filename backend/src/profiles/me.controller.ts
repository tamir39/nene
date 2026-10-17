import { Controller, Get, Header, Req } from '@nestjs/common';
import type { AuthenticatedRequest, CurrentUser } from '../auth/auth.types.js';

@Controller('me')
export class MeController {
  @Get()
  @Header('Cache-Control', 'no-store')
  getMe(@Req() request: AuthenticatedRequest): CurrentUser {
    return request.user;
  }
}
