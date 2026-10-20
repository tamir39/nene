import {
  Body,
  Controller,
  Get,
  Header,
  Headers,
  Param,
  Patch,
  Post,
  Query,
  Req,
} from '@nestjs/common';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { CustomersService } from './customers.service.js';
import {
  createInput,
  editInput,
  searchQuery,
  uuid,
} from './customer.validation.js';

@Controller('officer/customers')
export class OfficerCustomersController {
  constructor(private readonly customers: CustomersService) {}

  @Post()
  @Header('Cache-Control', 'no-store')
  create(
    @Req() request: AuthenticatedRequest,
    @Headers('idempotency-key') key: unknown,
    @Body() body: unknown,
  ) {
    this.customers.officer(request.user);
    return this.customers.create(
      request.user,
      uuid(key, 'Idempotency-Key'),
      createInput(body),
    );
  }

  @Get()
  @Header('Cache-Control', 'no-store')
  search(@Req() request: AuthenticatedRequest, @Query('query') query: unknown) {
    this.customers.officer(request.user);
    return this.customers.search(request.user, searchQuery(query));
  }

  @Get(':id')
  @Header('Cache-Control', 'no-store')
  detail(@Req() request: AuthenticatedRequest, @Param('id') id: unknown) {
    this.customers.officer(request.user);
    return this.customers.detail(request.user, uuid(id));
  }

  @Patch(':id')
  @Header('Cache-Control', 'no-store')
  edit(
    @Req() request: AuthenticatedRequest,
    @Param('id') id: unknown,
    @Body() body: unknown,
  ) {
    this.customers.officer(request.user);
    return this.customers.edit(request.user, uuid(id), editInput(body));
  }
}
