import { Body, Controller, Get, Header, Patch, Req } from '@nestjs/common';
import type { AuthenticatedRequest, CurrentUser } from '../auth/auth.types.js';
import { CustomersService } from '../customers/customers.service.js';
import { contactInput } from '../customers/customer.validation.js';

@Controller('me')
export class MeController {
  constructor(private readonly customers: CustomersService) {}

  @Get()
  @Header('Cache-Control', 'no-store')
  getMe(@Req() request: AuthenticatedRequest): CurrentUser {
    return request.user;
  }

  @Get('accounts')
  @Header('Cache-Control', 'no-store')
  accounts(@Req() request: AuthenticatedRequest) {
    return this.customers.ownAccounts(request.user);
  }

  @Patch('contact')
  @Header('Cache-Control', 'no-store')
  updateContact(@Req() request: AuthenticatedRequest, @Body() body: unknown) {
    return this.customers.updateContact(request.user, contactInput(body));
  }
}
