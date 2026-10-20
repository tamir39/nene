import {
  Inject,
  Injectable,
  Logger,
  ServiceUnavailableException,
  type OnModuleDestroy,
  HttpException,
} from '@nestjs/common';
import { Pool, type QueryResultRow, type PoolClient } from 'pg';
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

  async transaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
    let client: PoolClient | undefined;
    try {
      client = await this.pool.connect();
      await client.query('BEGIN');
      await client.query("SET LOCAL lock_timeout = '3s'");
      await client.query(
        "SET LOCAL idle_in_transaction_session_timeout = '20s'",
      );
      const result = await work(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      if (client) {
        try {
          await client.query('ROLLBACK');
        } catch {
          /* Connection may have closed. */
        }
      }
      if (error instanceof HttpException) throw error;
      throw new ServiceUnavailableException(
        'Application data is temporarily unavailable.',
      );
    } finally {
      client?.release();
    }
  }
}
