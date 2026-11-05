import 'reflect-metadata';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  BranchesController,
  distanceMeters,
  locationInput,
  nearestBranch,
  type Branch,
} from '../src/branches/branches.controller.js';
import {
  WalkingRouteService,
  parseWalkingRoute,
} from '../src/branches/walking-route.service.js';
import type { DatabaseService } from '../src/database/database.service.js';
import type { AuthenticatedRequest } from '../src/auth/auth.types.js';

const origin = { latitude: 10.7326, longitude: 106.6992 };
const offices: Branch[] = [
  {
    id: 'farther',
    name: 'Demo B',
    area: 'Demo',
    latitude: 10.741,
    longitude: 106.701,
    isDemo: true,
  },
  {
    id: 'nearest',
    name: 'Demo A',
    area: 'Demo',
    latitude: 10.734,
    longitude: 106.7,
    isDemo: true,
  },
];
const request = (role: 'customer' | 'officer') =>
  ({ user: { id: 'customer-id', role } }) as AuthenticatedRequest;
const result = () => ({
  code: 'Ok',
  routes: [
    {
      distance: 200.4,
      duration: 150.2,
      geometry: {
        type: 'LineString',
        coordinates: [
          [origin.longitude, origin.latitude],
          [106.7, 10.734],
        ],
      },
    },
  ],
});

void test('coordinates reject spoofed destination, strings, infinity and invalid ranges', () => {
  assert.deepEqual(locationInput(origin), origin);
  for (const input of [
    null,
    [],
    { ...origin, branchId: 'other' },
    { ...origin, latitude: '10' },
    { ...origin, longitude: Infinity },
    { ...origin, latitude: 91 },
  ])
    assert.throws(() => locationInput(input));
});
void test('nearest uses distance, deterministic ties and 5 km boundary, independent of order', () => {
  assert.equal(nearestBranch(origin, offices)?.id, 'nearest');
  assert.equal(nearestBranch(origin, offices.toReversed())?.id, 'nearest');
  assert.equal(
    nearestBranch({ latitude: 0, longitude: 0 }, offices),
    undefined,
  );
  assert.equal(
    nearestBranch(origin, [
      { ...offices[1]!, id: 'z' },
      { ...offices[1]!, id: 'a' },
    ])?.id,
    'a',
  );
  assert.ok(
    distanceMeters(origin, offices[1]!) > 170 &&
      distanceMeters(origin, offices[1]!) < 185,
  );
});
void test('customer catalog is read-only; denied roles and out-of-area never request a route', async () => {
  let reads = 0,
    calls = 0;
  const db = {
    query: async (sql: string) => {
      assert.match(sql, /^select /);
      reads++;
      return offices;
    },
  } as unknown as DatabaseService;
  const routes = {
    walk: async (_from: unknown, to: Branch) => {
      calls++;
      assert.equal(to.id, 'nearest');
      return { points: [] };
    },
  } as unknown as WalkingRouteService;
  const controller = new BranchesController(db, routes);
  await assert.rejects(controller.read(request('officer')));
  await assert.rejects(controller.route(request('officer'), origin));
  assert.equal(reads, 0);
  assert.equal((await controller.read(request('customer'))).branches.length, 2);
  await assert.rejects(
    controller.route(request('customer'), { latitude: 0, longitude: 0 }),
  );
  assert.equal(calls, 0);
  assert.equal(
    (await controller.route(request('customer'), origin)).branchId,
    'nearest',
  );
  assert.equal(calls, 1);
});
void test('route parser rejects no route, malformed geometry and out-of-range summaries', () => {
  assert.equal(parseWalkingRoute(result()).distanceMeters, 200);
  assert.deepEqual(parseWalkingRoute(result()).points[0], origin);
  for (const input of [
    { code: 'NoRoute', routes: [] },
    { ...result(), routes: [] },
    { code: 'Ok', routes: [{ ...result().routes[0], distance: NaN }] },
    {
      code: 'Ok',
      routes: [
        {
          ...result().routes[0],
          geometry: {
            type: 'LineString',
            coordinates: [
              [181, 1],
              [1, 1],
            ],
          },
        },
      ],
    },
  ])
    assert.throws(() => parseWalkingRoute(input));
});
void test('provider uses pedestrian shortest mode, fixed URL, no redirects and throttles concurrency', async (t) => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  let calls = 0;
  t.mock.method(
    globalThis,
    'fetch',
    async (url: string, options: RequestInit) => {
      calls++;
      assert.equal(url, 'https://valhalla1.openstreetmap.de/route');
      assert.equal(options.redirect, 'error');
      assert.ok(options.signal);
      const body = JSON.parse(options.body as string) as Record<
        string,
        unknown
      >;
      assert.equal(body.costing, 'pedestrian');
      assert.deepEqual(body.costing_options, {
        pedestrian: { shortest: true, max_distance: 30000 },
      });
      assert.equal(body.format, 'osrm');
      assert.equal(body.shape_format, 'geojson');
      await gate;
      return Response.json(result());
    },
  );
  const service = new WalkingRouteService();
  const first = service.walk(origin, offices[1]!);
  await assert.rejects(service.walk(origin, offices[1]!), /Wait a moment/);
  release();
  assert.equal((await first).points.length, 2);
  await assert.rejects(service.walk(origin, offices[1]!), /Wait a moment/);
  assert.equal(calls, 1);
});
void test('provider failures and unrelated route geometry fail closed without echoing details', async (t) => {
  t.mock.method(globalThis, 'fetch', async () => {
    throw new Error('sensitive provider details');
  });
  await assert.rejects(
    new WalkingRouteService().walk(origin, offices[1]!),
    /Walking route unavailable/,
  );
  t.mock.restoreAll();
  t.mock.method(globalThis, 'fetch', async () => Response.json(result()));
  await assert.rejects(
    new WalkingRouteService().walk({ latitude: 1, longitude: 1 }, offices[1]!),
    /Walking route unavailable/,
  );
});
