import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { ConfigModule } from './config/config.module.js';
import { SessionGuard } from './auth/session.guard.js';
import { SupabaseAuthService } from './auth/supabase-auth.service.js';
import { DatabaseService } from './database/database.service.js';
import { ProfilesRepository } from './profiles/profiles.repository.js';
import { MeController } from './profiles/me.controller.js';
import { HealthController } from './health/health.controller.js';
import { SupabaseAdminService } from './auth/supabase-admin.service.js';
import { CustomersService } from './customers/customers.service.js';
import { OfficerCustomersController } from './customers/officer-customers.controller.js';
import { IdentityController } from './identity/identity.controller.js';
import { IdentityService } from './identity/identity.service.js';
import { IdentityStorageService } from './identity/identity-storage.service.js';

@Module({
  imports: [ConfigModule],
  controllers: [
    HealthController,
    MeController,
    OfficerCustomersController,
    IdentityController,
  ],
  providers: [
    DatabaseService,
    SupabaseAuthService,
    SupabaseAdminService,
    CustomersService,
    IdentityService,
    IdentityStorageService,
    ProfilesRepository,
    { provide: APP_GUARD, useClass: SessionGuard },
  ],
})
export class AppModule {}
