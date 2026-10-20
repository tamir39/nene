import {
  ConflictException,
  BadRequestException,
  Inject,
  Injectable,
  ServiceUnavailableException,
} from '@nestjs/common';
import {
  createClient,
  type SupabaseClient,
  type User,
} from '@supabase/supabase-js';
import { ENVIRONMENT } from '../config/config.module.js';
import type { Environment } from '../config/environment.js';

@Injectable()
export class SupabaseAdminService {
  private readonly client?: SupabaseClient;

  constructor(@Inject(ENVIRONMENT) private readonly environment: Environment) {
    if (environment.supabaseSecretKey) {
      this.client = createClient(
        environment.supabaseUrl,
        environment.supabaseSecretKey,
        {
          auth: {
            persistSession: false,
            autoRefreshToken: false,
            detectSessionInUrl: false,
          },
          global: {
            fetch: (input, init) =>
              fetch(input, { ...init, signal: AbortSignal.timeout(5000) }),
          },
        },
      );
    }
  }

  assertAvailable(): void {
    const host = new URL(this.environment.supabaseUrl).hostname;
    if (
      !this.client ||
      this.environment.nodeEnv === 'production' ||
      !['127.0.0.1', 'localhost', '[::1]'].includes(host)
    ) {
      throw new ServiceUnavailableException(
        'Demo customer creation is not configured for this environment.',
      );
    }
  }

  private async find(id: string): Promise<User | null> {
    try {
      const { data, error } = await this.client!.auth.admin.getUserById(id);
      if (error?.status === 404 && error.code === 'user_not_found') return null;
      if (error || !data.user) throw new Error('unavailable');
      return data.user;
    } catch {
      throw new ServiceUnavailableException(
        'Customer sign-in setup is temporarily unavailable. Retry the same request.',
      );
    }
  }

  private matching(user: User, id: string, email: string): void {
    if (user.id !== id || user.email?.toLowerCase() !== email) {
      throw new ConflictException(
        'The reserved identity does not match this customer request.',
      );
    }
  }

  async ensureUser(id: string, email: string, password: string): Promise<void> {
    this.assertAvailable();
    const existing = await this.find(id);
    if (existing) {
      this.matching(existing, id, email);
      return;
    }
    let duplicate = false;
    let invalidInput = false;
    try {
      // Local synthetic demo activation only; not eKYC or proof of email ownership.
      const { data, error } = await this.client!.auth.admin.createUser({
        id,
        email,
        password,
        email_confirm: true,
      });
      if (!error && data.user) {
        this.matching(data.user, id, email);
        return;
      }
      duplicate =
        !!error &&
        ['email_exists', 'user_already_exists'].includes(error.code ?? '');
      invalidInput =
        !!error &&
        ['email_address_invalid', 'weak_password'].includes(error.code ?? '');
    } catch (error) {
      if (error instanceof ConflictException) throw error;
      // The server may have committed despite a timeout; reconcile the reserved ID.
    }
    const reconciled = await this.find(id);
    if (reconciled) {
      this.matching(reconciled, id, email);
      return;
    }
    if (duplicate)
      throw new ConflictException({
        code: 'CUSTOMER_EMAIL_EXISTS',
        message:
          'That sign-in email is already in use. No existing identity was changed.',
      });
    if (invalidInput)
      throw new BadRequestException(
        'The sign-in email or initial password was not accepted. Check the details and start a new request.',
      );
    throw new ServiceUnavailableException(
      'Customer sign-in setup is temporarily unavailable. Retry the same request.',
    );
  }
}
