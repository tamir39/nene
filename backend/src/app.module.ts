import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { ConfigModule } from './config/config.module.js';
import { SessionGuard } from './auth/session.guard.js';
import { SupabaseAuthService } from './auth/supabase-auth.service.js';
import { DatabaseService } from './database/database.service.js';
import { ProfilesRepository } from './profiles/profiles.repository.js';
import { MeController } from './profiles/me.controller.js';
import { HealthController } from './health/health.controller.js';

@Module({
  imports: [ConfigModule],
  controllers: [HealthController, MeController],
  providers: [
    DatabaseService,
    SupabaseAuthService,
    ProfilesRepository,
    { provide: APP_GUARD, useClass: SessionGuard },
  ],
})
export class AppModule {}
