import {
  HttpException,
  Injectable,
  ServiceUnavailableException,
} from '@nestjs/common';
import type { Point } from './branches.controller.js';

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new Error('Invalid route');
  return value as Record<string, unknown>;
}
export function parseWalkingRoute(data: unknown) {
  const result = record(data);
  if (
    result.code !== 'Ok' ||
    !Array.isArray(result.routes) ||
    result.routes.length !== 1
  )
    throw new Error('No route');
  const route = record(result.routes[0]);
  const geometry = record(route.geometry);
  if (
    typeof route.distance !== 'number' ||
    !Number.isFinite(route.distance) ||
    route.distance < 0 ||
    route.distance > 30000 ||
    typeof route.duration !== 'number' ||
    !Number.isFinite(route.duration) ||
    route.duration < 0 ||
    route.duration > 86400 ||
    geometry.type !== 'LineString' ||
    !Array.isArray(geometry.coordinates) ||
    geometry.coordinates.length < 2 ||
    geometry.coordinates.length > 10000
  )
    throw new Error('Invalid route');
  const points = geometry.coordinates.map((value: unknown) => {
    if (!Array.isArray(value) || value.length !== 2)
      throw new Error('Invalid point');
    const lon: unknown = value[0],
      lat: unknown = value[1];
    if (
      typeof lat !== 'number' ||
      !Number.isFinite(lat) ||
      Math.abs(lat) > 90 ||
      typeof lon !== 'number' ||
      !Number.isFinite(lon) ||
      Math.abs(lon) > 180
    )
      throw new Error('Invalid point');
    return { latitude: lat, longitude: lon };
  });
  return {
    distanceMeters: Math.round(route.distance),
    durationSeconds: Math.round(route.duration),
    points,
    provider: 'Valhalla / FOSSGIS',
    mode: 'walking_shortest_distance',
  };
}
@Injectable()
export class WalkingRouteService {
  private nextRequestAt = 0;
  private pending = false;
  async walk(origin: Point, destination: Point) {
    // Public demo capacity is for this single-process local course preview only.
    if (process.env.NODE_ENV === 'production')
      throw new ServiceUnavailableException(
        'Routing provider is not configured for release.',
      );
    if (this.pending || Date.now() < this.nextRequestAt)
      throw new HttpException(
        'Wait a moment before requesting another route.',
        429,
      );
    this.nextRequestAt = Date.now() + 1500;
    this.pending = true;
    try {
      const response = await fetch('https://valhalla1.openstreetmap.de/route', {
        method: 'POST',
        redirect: 'error',
        signal: AbortSignal.timeout(12000),
        headers: {
          'Content-Type': 'application/json',
          'X-Client-Id': 'nene-course-demo.github.com/tamir39/nene',
          'User-Agent': 'NeneCourseDemo/0.1 (https://github.com/tamir39/nene)',
        },
        body: JSON.stringify({
          locations: [origin, destination].map((p) => ({
            lat: p.latitude,
            lon: p.longitude,
            radius: 100,
          })),
          costing: 'pedestrian',
          costing_options: {
            pedestrian: { shortest: true, max_distance: 30000 },
          },
          format: 'osrm',
          shape_format: 'geojson',
          units: 'kilometers',
          directions_type: 'none',
          alternates: 0,
        }),
      });
      if (!response.ok || !response.body) {
        await response.body?.cancel();
        throw new Error('Provider unavailable');
      }
      const reader = response.body.getReader();
      const chunks: Uint8Array[] = [];
      let length = 0;
      try {
        while (true) {
          const part = await reader.read();
          if (part.done) break;
          length += part.value.length;
          if (length > 524288) throw new Error('Route too large');
          chunks.push(part.value);
        }
      } finally {
        await reader.cancel();
      }
      const route = parseWalkingRoute(
        JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown,
      );
      // Reject unrelated/malformed geometry rather than drawing a misleading path.
      const close = (a: Point, b: Point) =>
        Math.abs(a.latitude - b.latitude) < 0.003 &&
        Math.abs(a.longitude - b.longitude) < 0.003;
      if (
        !close(origin, route.points[0]!) ||
        !close(destination, route.points.at(-1)!)
      )
        throw new Error('Route endpoints do not match');
      return route;
    } catch {
      // Never log the request, coordinates, or provider response.
      throw new ServiceUnavailableException(
        'Walking route unavailable. Try again later.',
      );
    } finally {
      this.pending = false;
    }
  }
}
