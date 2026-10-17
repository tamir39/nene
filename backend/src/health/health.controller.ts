import { Controller, Get, Header } from '@nestjs/common';
import { Public } from '../auth/public.decorator.js';

@Controller('health')
export class HealthController {
  @Public()
  @Get()
  @Header('Cache-Control', 'no-store')
  getHealth() {
    // Liveness only; this does not claim that Supabase or PostgreSQL is reachable.
    return { status: 'ok', service: 'nene-api', check: 'liveness' } as const;
  }
}
