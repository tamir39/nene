import {
  Inject,
  Injectable,
  ServiceUnavailableException,
} from '@nestjs/common';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { createHash } from 'node:crypto';
import { ENVIRONMENT } from '../config/config.module.js';
import type { Environment } from '../config/environment.js';
import { maxImageBytes } from './identity.validation.js';

@Injectable()
export class IdentityStorageService {
  private readonly client?: SupabaseClient;
  constructor(@Inject(ENVIRONMENT) environment: Environment) {
    if (environment.supabaseSecretKey)
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
  assertAvailable() {
    if (!this.client)
      throw new ServiceUnavailableException(
        'Private reference storage is not configured.',
      );
  }
  async read(key: string): Promise<Buffer> {
    this.assertAvailable();
    try {
      const { data, error } =
        await this.client!.storage.from('identity-evidence').download(key);
      if (error || !data || data.size > maxImageBytes)
        throw new Error('unavailable');
      return Buffer.from(await data.arrayBuffer());
    } catch {
      throw new ServiceUnavailableException(
        'The private reference photo is temporarily unavailable.',
      );
    }
  }
  async write(key: string, bytes: Buffer, contentType: string, hash: string) {
    this.assertAvailable();
    try {
      const { error } = await this.client!.storage.from(
        'identity-evidence',
      ).upload(key, bytes, { contentType, upsert: false, cacheControl: '0' });
      if (!error) return;
    } catch {
      /* Reconcile a lost response by reading this reserved key only. */
    }
    const stored = await this.read(key);
    if (createHash('sha256').update(stored).digest('hex') !== hash)
      throw new ServiceUnavailableException(
        'The reference upload could not be reconciled. Check status before retrying.',
      );
  }
  async remove(key: string) {
    this.assertAvailable();
    try {
      const { error } = await this.client!.storage.from(
        'identity-evidence',
      ).remove([key]);
      if (error) throw new Error('unavailable');
    } catch {
      throw new ServiceUnavailableException(
        'Expired reference cleanup is temporarily unavailable.',
      );
    }
  }
}
