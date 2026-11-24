import { AssistantController } from './assistant/assistant.controller.js';
import {
  PaymentsController,
  VnpayCallbacksController,
} from './payments/payments.controller.js';
import { PaymentsService } from './payments/payments.service.js';
import { BranchesController } from './branches/branches.controller.js';
import { WalkingRouteService } from './branches/walking-route.service.js';
import { CashController } from './confirmation/cash.controller.js';
import { InterbankController } from './confirmation/interbank.controller.js';
import { Module } from '@nestjs/common';
import { TransfersController } from './confirmation/transfers.controller.js';
import { ConfirmationController } from './confirmation/confirmation.controller.js';
import { ConfirmationService } from './confirmation/confirmation.service.js';
import { SecurityManagementController } from './security/security-management.controller.js';
import { SecurityManagementService } from './security/security-management.service.js';
import { AccountHistoryController } from './accounts/account-history.controller.js';
import { DemoAccountController } from './accounts/demo-account.controller.js';
import { SavingsPolicyController } from './accounts/savings-policy.controller.js';
import { SecurityController } from './security/security.controller.js';
import { SecurityService } from './security/security.service.js';
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
    PaymentsController,
    VnpayCallbacksController,
    AssistantController,
    BranchesController,
    CashController,
    InterbankController,
    TransfersController,
    ConfirmationController,
    SecurityManagementController,
    AccountHistoryController,
    DemoAccountController,
    SavingsPolicyController,
    SecurityController,
    HealthController,
    MeController,
    OfficerCustomersController,
    IdentityController,
  ],
  providers: [
    PaymentsService,
    WalkingRouteService,
    ConfirmationService,
    SecurityManagementService,
    SecurityService,
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
