import {
  BadRequestException,
  Body,
  Controller,
  ForbiddenException,
  Get,
  Header,
  HttpCode,
  NotFoundException,
  Post,
  Req,
} from '@nestjs/common';
import type { AuthenticatedRequest } from '../auth/auth.types.js';
import { DatabaseService } from '../database/database.service.js';
import { WalkingRouteService } from './walking-route.service.js';

export interface Point {
  latitude: number;
  longitude: number;
}
export type Branch = Point & {
  id: string;
  name: string;
  area: string;
  isDemo: boolean;
};
export const nearbyRadiusMeters = 5000;
export function distanceMeters(a: Point, b: Point): number {
  const rad = Math.PI / 180;
  const h =
    Math.sin(((b.latitude - a.latitude) * rad) / 2) ** 2 +
    Math.cos(a.latitude * rad) *
      Math.cos(b.latitude * rad) *
      Math.sin(((b.longitude - a.longitude) * rad) / 2) ** 2;
  return 6371000 * 2 * Math.asin(Math.sqrt(Math.min(1, h)));
}
export function locationInput(body: unknown): Point {
  if (!body || typeof body !== 'object' || Array.isArray(body))
    throw new BadRequestException('A starting location is required.');
  const data = body as Record<string, unknown>;
  if (
    Object.keys(data).some((key) => !['latitude', 'longitude'].includes(key)) ||
    typeof data.latitude !== 'number' ||
    !Number.isFinite(data.latitude) ||
    Math.abs(data.latitude) > 90 ||
    typeof data.longitude !== 'number' ||
    !Number.isFinite(data.longitude) ||
    Math.abs(data.longitude) > 180
  ) {
    throw new BadRequestException('Use valid latitude and longitude.');
  }
  return { latitude: data.latitude, longitude: data.longitude };
}
export function nearestBranch(
  origin: Point,
  branches: Branch[],
): Branch | undefined {
  return branches
    .filter((b) => distanceMeters(origin, b) <= nearbyRadiusMeters)
    .sort(
      (a, b) =>
        distanceMeters(origin, a) - distanceMeters(origin, b) ||
        a.id.localeCompare(b.id),
    )[0];
}
@Controller('me/branches')
export class BranchesController {
  constructor(
    private readonly db: DatabaseService,
    private readonly routes: WalkingRouteService,
  ) {}
  private customer(req: AuthenticatedRequest) {
    if (req.user.role !== 'customer')
      throw new ForbiddenException('A customer profile is required.');
  }
  private async branches(): Promise<Branch[]> {
    return this.db.query<Branch & Record<string, unknown>>(
      'select id, name, area, latitude, longitude, is_demo as "isDemo" from bank.branches order by id',
      [],
    );
  }
  @Get()
  @Header('Cache-Control', 'no-store')
  async read(@Req() req: AuthenticatedRequest) {
    this.customer(req);
    return {
      branches: await this.branches(),
      nearbyRadiusMeters,
      demoOrigin: { latitude: 10.7326, longitude: 106.6992 },
    };
  }
  @Post('route')
  @HttpCode(200)
  @Header('Cache-Control', 'no-store')
  async route(@Req() req: AuthenticatedRequest, @Body() body: unknown) {
    this.customer(req);
    const origin = locationInput(body);
    const branch = nearestBranch(origin, await this.branches());
    if (!branch)
      throw new NotFoundException(
        'No demo office within 5 km of this starting point.',
      );
    return {
      branchId: branch.id,
      nearestBy: 'straight_line',
      ...(await this.routes.walk(origin, branch)),
    };
  }
}
