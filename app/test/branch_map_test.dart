import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:nene_app/data/branch_location.dart';
import 'package:nene_app/data/branches_api.dart';
import 'package:nene_app/session_controller.dart';
import 'package:nene_app/ui/branch_map_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';
import 'test_doubles.dart';

final catalog = <String, dynamic>{
  'nearbyRadiusMeters': 5000,
  'demoOrigin': {'latitude': 10.7326, 'longitude': 106.6992},
  'branches': [
    {
      'id': 'tdtu',
      'name': 'Nene TDTU demo',
      'area': 'Nguyen Huu Tho area',
      'latitude': 10.734,
      'longitude': 106.7,
      'isDemo': true,
    },
    {
      'id': 'north',
      'name': 'Nene North demo',
      'area': 'North of TDTU',
      'latitude': 10.741,
      'longitude': 106.701,
      'isDemo': true,
    },
  ],
};
final route = <String, dynamic>{
  'branchId': 'tdtu',
  'nearestBy': 'straight_line',
  'mode': 'walking_shortest_distance',
  'distanceMeters': 220,
  'durationSeconds': 180,
  'points': [
    {'latitude': 10.7326, 'longitude': 106.6992},
    {'latitude': 10.733, 'longitude': 106.7},
    {'latitude': 10.734, 'longitude': 106.7},
  ],
};

class OfflineTiles extends TileProvider {
  @override
  ImageProvider getImage(
    TileCoordinates coordinates,
    TileLayer options,
  ) => MemoryImage(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  );
}

class FakeLocation implements BranchLocation {
  int calls = 0;
  Future<LatLng> Function() read = () async => const LatLng(10.7326, 106.6992);
  @override
  Future<LatLng> current() {
    calls++;
    return read();
  }
}

BranchesApi api(Future<http.Response> Function(http.Request) handler) =>
    BranchesApi(
      baseUrl: Uri.parse('http://localhost/api/v1/'),
      client: MockClient(handler),
    );
http.Response json(Object data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Future<SessionController> session() async {
  final owner = SessionController(
    auth: FakeAuth()
      ..userId = demoProfile.id
      ..accessToken = 'test-token',
    profiles: FakeProfiles()..fetch = (_) async => demoProfile,
  );
  await owner.loadProfile();
  return owner;
}

Future<void> tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> mount(
  WidgetTester tester, {
  required BranchesApi backend,
  FakeLocation? location,
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final owner = await session();
  addTearDown(owner.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: neneTheme(),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: BranchMapScreen(
            session: owner,
            api: backend,
            location: location,
            tileProvider: OfflineTiles(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'all nearby offices, nearest order, outside radius and malformed points',
    () {
      final data = BranchCatalog(catalog);
      expect(data.nearby(const LatLng(10.7326, 106.6992)).map((b) => b.id), [
        'tdtu',
        'north',
      ]);
      expect(data.nearby(const LatLng(0, 0)), isEmpty);
      expect(
        () => BranchCatalog({...catalog, 'nearbyRadiusMeters': -1}),
        throwsFormatException,
      );
      expect(
        () => branchPoint({'latitude': double.nan, 'longitude': 0}),
        throwsFormatException,
      );
      expect(
        () => BranchRoute({...route, 'mode': 'driving'}),
        throwsFormatException,
      );
    },
  );
  test(
    'API sends coordinates only in POST body, uses session and denies redirects',
    () async {
      final backend = api((req) async {
        expect(req.method, 'POST');
        expect(req.followRedirects, isFalse);
        expect(req.headers['Authorization'], 'Bearer token');
        expect(req.url.query, isEmpty);
        expect(jsonDecode(req.body), {
          'latitude': 10.7326,
          'longitude': 106.6992,
        });
        return json(route);
      });
      expect(
        (await backend.route(
          'token',
          const LatLng(10.7326, 106.6992),
        )).branchId,
        'tdtu',
      );
      await expectLater(
        api((_) async => json({}, 429)).route('token', const LatLng(0, 0)),
        throwsA(isA<BranchRouteException>()),
      );
    },
  );
  testWidgets(
    'no automatic location; denied permission still allows explicit demo walking route',
    (tester) async {
      final location = FakeLocation()
        ..read = () async => throw const BranchLocationException(
          'Location permission is blocked.',
        );
      var routeCalls = 0;
      await mount(
        tester,
        location: location,
        backend: api((req) async {
          if (req.method == 'POST') {
            routeCalls++;
            return json(route);
          }
          return json(catalog);
        }),
      );
      expect(location.calls, 0);
      expect(find.textContaining('fictional Nene offices'), findsOneWidget);
      await tap(tester, 'Use my location');
      expect(find.text('Location permission is blocked.'), findsOneWidget);
      expect(routeCalls, 0);
      await tap(tester, 'Use TDTU demo starting point');
      expect(find.text('Starting from: TDTU demo point'), findsOneWidget);
      await tap(tester, 'Walking route to nearest');
      expect(routeCalls, 1);
      expect(find.textContaining('220 m'), findsOneWidget);
      expect(find.byType(PolylineLayer), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('out-of-area real location does not request a route', (
    tester,
  ) async {
    final location = FakeLocation()..read = () async => const LatLng(0, 0);
    await mount(
      tester,
      location: location,
      backend: api((req) async {
        expect(req.method, 'GET');
        return json(catalog);
      }),
    );
    await tap(tester, 'Use my location');
    expect(find.text('Starting from: your location'), findsOneWidget);
    expect(find.textContaining('No demo offices within 5 km'), findsOneWidget);
    expect(find.text('Walking route to nearest'), findsNothing);
  });
  testWidgets(
    'routing failure has no fabricated line and supports retry at large text',
    (tester) async {
      await mount(
        tester,
        scale: 2,
        backend: api(
          (req) async => req.method == 'POST' ? json({}, 503) : json(catalog),
        ),
      );
      await tap(tester, 'Use TDTU demo starting point');
      await tap(tester, 'Walking route to nearest');
      expect(find.textContaining('Walking route unavailable'), findsOneWidget);
      expect(find.byType(PolylineLayer), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('late location completion after leaving screen is discarded', (
    tester,
  ) async {
    final pending = Completer<LatLng>();
    await mount(
      tester,
      location: FakeLocation()..read = () => pending.future,
      backend: api((_) async => json(catalog)),
    );
    await tester.ensureVisible(find.text('Use my location'));
    await tester.tap(find.text('Use my location'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    pending.complete(const LatLng(0, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('offline branch screen capture', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE_BRANCH_UI')) return;
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
    await tester.runAsync(() async {
      await (FontLoader('MaterialIcons')..addFont(
            File(
              '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    });
    await tester.runAsync(
      () async =>
          (FontLoader('BranchFixtureFont')..addFont(
                File(
                  '$sdk/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
                ).readAsBytes().then(ByteData.sublistView),
              ))
              .load(),
    );
    tester.view.physicalSize = const Size(390, 1050);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final owner = await session();
    addTearDown(owner.dispose);
    final theme = neneTheme();
    const capture = ValueKey('branch-capture');
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'BranchFixtureFont'),
          filledButtonTheme: FilledButtonThemeData(
            style: theme.filledButtonTheme.style!.copyWith(
              textStyle: const WidgetStatePropertyAll(
                TextStyle(fontFamily: 'BranchFixtureFont', fontSize: 16),
              ),
            ),
          ),
        ),
        home: RepaintBoundary(
          key: capture,
          child: Scaffold(
            appBar: AppBar(title: const NeneLogo(size: 30)),
            body: BranchMapScreen(
              session: owner,
              api: api((_) async => json(catalog)),
              tileProvider: OfflineTiles(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../.tmp/ui-review/branch-map-fixture.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
