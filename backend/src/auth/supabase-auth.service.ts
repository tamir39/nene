import {
  Inject,
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import {
  createClient,
  isAuthRetryableFetchError,
  type SupabaseClient,
} from '@supabase/supabase-js';
import { ENVIRONMENT } from '../config/config.module.js';
import type { Environment } from '../config/environment.js';
import type { VerifiedIdentity } from './auth.types.js';

@Injectable()
export class SupabaseAuthService {
  private readonly client: SupabaseClient;

  constructor(@Inject(ENVIRONMENT) environment: Environment) {
    this.client = createClient(
      environment.supabaseUrl,
      environment.supabasePublishableKey,
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

  async verifyAccessToken(token: string): Promise<VerifiedIdentity> {
    try {
      // getUser verifies with the Auth server. Never authorize from getSession or user_metadata.
      const { data, error } = await this.client.auth.getUser(token);
      if (
        error &&
        (isAuthRetryableFetchError(error) || (error.status ?? 0) >= 500)
      ) {
        throw new ServiceUnavailableException(
          'Authentication is temporarily unavailable.',
        );
      }
      if (error || !data.user)
        throw new UnauthorizedException('Invalid or expired session.');
      return { id: data.user.id, email: data.user.email ?? null };
    } catch (error) {
      if (
        error instanceof UnauthorizedException ||
        error instanceof ServiceUnavailableException
      )
        throw error;
      throw new ServiceUnavailableException(
        'Authentication is temporarily unavailable.',
      );
    }
  }
}
