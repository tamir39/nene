# Demo branch navigation

Implemented 5 November 2026 for **BR-13**, PDF p. 2, Business 6: show the user's position, nearby bank offices and a shortest walking path to the nearest office. Persisted office data also supports TR-03. Android/device and human acceptance remain open; this record does not mark the whole requirement complete.

## Scope and decisions

The user explicitly approved **fictional Nene offices near TDTU, Ho Chi Minh City**. They belong to our demo brand, not another bank, and are not TDTU facilities. Names, coordinates, a visible demo notice and office cards identify this clearly. No banking services exist at those locations.

The catalog contains three demonstration points: Nene TDTU, Nene Tan Phong and Nene North. The initial map shows the whole catalog. After location selection, it shows every catalog office within **5 km in a straight line**, with no top-N omission. NestJS selects the nearest by geographic distance (Haversine); equal distances use the stable branch ID. Radius, catalog and nearest metric are project decisions, not PDF wording. This supersedes the earlier proposal to select by walking distance.

The walking path goes to that selected office using the provider's pedestrian shortest-distance mode. A shorter walking trip to a different office is not what this selection rule means. Map data, access restrictions and snapped road endpoints affect results; do not claim the drawn path is an audited physical entrance or a guarantee of real-world accessibility.

No branch administration, appointment booking, ATMs, background tracking, voice navigation or other-bank directory is added. Financial flows are unchanged. Face comparison itself and AWS remain undecided, eKYC remains unresolved, and local financial amounts at or above 5,000,000 VND remain blocked.

## App behavior

Customer home → **Find a Nene office** opens the same Flutter app's map. Offices load through the authenticated NestJS API. Location permission is requested only after **Use my location**. The current point and all nearby offices appear on the map and in an accessible text list. **Walking route to nearest** requests and draws the route with distance and approximate duration.

**Use TDTU demo starting point** is an explicit fallback at 10.7326, 106.6992. The screen labels it as a demo point, never as the user's actual location. This fallback helps browser/LAN tests but does not replace the PDF's real-location demonstration.

The screen handles loading, catalog retry, permission denial, location-service errors/timeouts, no nearby offices, unavailable map tiles, route failure and throttling. A failed route has no fabricated straight-line fallback. Leaving the screen or signing out disposes its location/route state; late async results are discarded. Existing session ownership protects API requests.

Android declares foreground coarse/fine location permissions. iOS has a when-in-use purpose string for stack compatibility; no iOS build/release has been validated. HTTP LAN origins may block browser geolocation. Test actual location on `localhost` in Edge or an appropriately secured native/HTTPS environment; demo starting points still work over LAN.

## API and storage

All endpoints require an active customer session and send `Cache-Control: no-store`. Officers are denied. The existing global session guard verifies authentication and server-controlled role.

| Endpoint | Contract |
| --- | --- |
| `GET /api/v1/me/branches` | `branches` with `id`, `name`, `area`, `latitude`, `longitude`, `isDemo`; `nearbyRadiusMeters: 5000`; `demoOrigin`. |
| `POST /api/v1/me/branches/route` | Exactly numeric `latitude` and `longitude` in the body. No destination/provider URL is accepted. Returns `branchId`, `nearestBy: straight_line`, `mode: walking_shortest_distance`, `distanceMeters`, `durationSeconds`, `points` and provider credit. |

Invalid coordinates/extra fields return 400; no nearby demo office returns 404; another route request too soon/in flight returns 429; provider timeout/failure/invalid response returns a safe 503. The app never treats these as successful routes.

Migration `20261105000100_demo_branches.sql` seeds `bank.branches`. The API role has SELECT only under forced RLS. Client Supabase roles have no access, and no mutation endpoint is provided. Financial tables/grants are untouched. Location and route requests are not stored in the database or application logs. Coordinates are sent in POST bodies, not URL query parameters.

## Providers and release boundary

Flutter uses pinned `flutter_map 8.3.2`, `latlong2 0.9.1`, `geolocator 14.1.2` and the existing `url_launcher 6.3.3` as a direct dependency. No framework/backend change or provider account is introduced.

OpenStreetMap raster tiles use the published HTTPS endpoint, visible linked attribution and a native application identifier. Normal native/browser HTTP caching is retained; no bulk download, offline pack or explicit prefetch feature is added. The map service sees the requested viewport/IP. See the [OSM tile policy](https://operations.osmfoundation.org/policies/tiles/) and [flutter_map caching behavior](https://docs.fleaflet.dev/layers/raster-tile-layer/caching).

NestJS calls the fixed FOSSGIS Valhalla demo endpoint with `costing: pedestrian` and `costing_options.pedestrian.shortest: true`. OSRM-format GeoJSON is requested for bounded decoding; this is Valhalla's response format, not the OSRM driving service. The [Valhalla API reference](https://valhalla.github.io/valhalla/api/route/api-reference/) documents distance-only costing and disabled pedestrian hierarchy pruning. Server code enforces one request in flight, a 1.5-second global spacing per process, 12-second timeout, no redirects/retries, a 512 KiB response limit and coordinate/geometry/endpoint checks. Provider errors do not expose request details.

This public route endpoint is **local development only** and returns 503 when `NODE_ENV=production`. Before end-user publication, settle appropriate service capacity and usage arrangements; the [provider README](https://github.com/valhalla/valhalla#demo-server) asks published apps to identify themselves and contact the maintainers. No such message, paid service, hosted deployment or account creation was performed. The single-process limiter is not a hosted multi-instance quota system.

## Verification and local test

- Backend lint, build and 107 tests pass; formatting passes. New checks cover input validation, role denial, nearest/radius/tie rules, no nearby destination, pedestrian request configuration, concurrency throttling, malformed responses, failures and mismatched route geometry.
- A live request using only the synthetic TDTU start and demo destination returned **470 m, 340 seconds and 46 route points** on 5 November. This proves provider connectivity/decoding for that pair, not device geolocation or global route optimality.
- Flutter analysis passes; all **205 tests** pass, including new API, permission-denial/demo fallback, out-of-area, route failure, 200% text and late-result disposal checks. Debug web build passes. A rendered 390-pixel offline fixture was inspected for layout; it uses blank tiles and synthetic offices, not evidence of a live browser map or GPS permission.
- `node scripts/check-branch-map.mjs` is a disposable database check for migration, persisted catalog, nearest selection and denied API/client writes. It could not start because Docker Desktop's Linux engine was stopped; no application data was changed. Re-run with Docker available after `npm --prefix backend run build`.
- Shared `D:\Data\Downloads\Policies` remains unavailable. No policy compliance claim is made.

When ready, the user starts **`run.bat`** (or stops/restarts an existing run). The local runner applies forward migrations and rebuilds the same Flutter web app; the launcher itself remains local and uncommitted. Sign in as a customer, open **Find a Nene office**, and test:

1. Three explicitly fictional Nene offices and map attribution appear.
2. Choose **Use TDTU demo starting point**, then **Walking route to nearest**. Check the demo-start label, selected Nene TDTU office, drawn street route and distance/duration.
3. On PC localhost, choose **Use my location** and allow permission. Check the user marker and nearby list; being farther than 5 km from every demo point correctly produces an empty result.
4. Deny location permission and confirm the map remains usable with the explicit demo option. Try a failed/offline route and confirm no success or fabricated line appears.
5. Return home or sign out while a request is pending; the previous location/route must not reappear in another session.

No emulator or interactive demo was launched by the agent. Human Edge, Android, real location permission and hosted provider acceptance are pending.
