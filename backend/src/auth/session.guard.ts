import {
  ForbiddenException,
  Injectable,
  UnauthorizedException,
  type CanActivate,
  type ExecutionContext,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { AuthenticatedRequest } from './auth.types.js';
import { PUBLIC_ROUTE } from './public.decorator.js';
import { SupabaseAuthService } from './supabase-auth.service.js';
import { ProfilesRepository } from '../profiles/profiles.repository.js';

@Injectable()
export class SessionGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly auth: SupabaseAuthService,
    private readonly profiles: ProfilesRepository,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    if (
      this.reflector.getAllAndOverride<boolean>(PUBLIC_ROUTE, [
        context.getHandler(),
        context.getClass(),
      ])
    )
      return true;
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    const authorization = request.headers.authorization;
    const match =
      typeof authorization === 'string' && authorization.length <= 16384
        ? /^Bearer ([^\s,]+)$/i.exec(authorization)
        : null;
    const token = match?.[1];
    if (!token)
      throw new UnauthorizedException('A bearer session is required.');
    const identity = await this.auth.verifyAccessToken(token);
    const profile = await this.profiles.findById(identity.id);
    if (
      !profile ||
      profile.status !== 'active' ||
      !['customer', 'officer'].includes(profile.role)
    ) {
      throw new ForbiddenException(
        'An active application profile is required.',
      );
    }
    request.user = {
      id: identity.id,
      email: identity.email,
      displayName: profile.display_name,
      role: profile.role,
    };
    return true;
  }
}
