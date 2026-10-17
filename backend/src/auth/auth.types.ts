import type { Request } from 'express';

export interface VerifiedIdentity {
  id: string;
  email: string | null;
}

export interface CurrentUser extends VerifiedIdentity {
  displayName: string;
  role: 'customer' | 'officer';
}

export interface AuthenticatedRequest extends Request {
  user: CurrentUser;
}
