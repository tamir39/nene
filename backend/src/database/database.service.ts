import {
  Inject,
  Injectable,
  Logger,
  ServiceUnavailableException,
  type OnModuleDestroy,
} from '@nestjs/common';
import { Pool, type QueryResultRow } from 'pg';
import { ENVIRONMENT } from '../config/config.module.js';
import type { Environment } from '../config/environment.js';

@Injectable()
export class DatabaseService implements OnModuleDestroy {
  private readonly pool: Pool;
  private readonly logger = new Logger(DatabaseService.name);

  constructor(@Inject(ENVIRONMENT) environment: Environment) {
    this.pool = new Pool(environment.database);
    this.pool.on('error', () =>
      this.logger.error('An idle PostgreSQL connection failed.'),
    );
  }

  async query<T extends QueryResultRow>(
    text: string,
    values: unknown[],
  ): Promise<T[]> {
    try {
      const result = await this.pool.query<T>(text, values);
      return result.rows;
    } catch {
      // Do not log query values, credentials, or banking data.
      throw new ServiceUnavailableException(
        'Application data is temporarily unavailable.',
      );
    }
  }

  async onModuleDestroy(): Promise<void> {
    await this.pool.end();
  }
}
