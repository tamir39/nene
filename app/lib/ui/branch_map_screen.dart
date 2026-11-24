import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/branches_api.dart';
import '../data/branch_location.dart';
import '../data/user_profile.dart';
import '../session_controller.dart';
import 'customer_workspace.dart' show WorkspaceContent;
import 'nene_brand.dart';

class BranchMapScreen extends StatefulWidget {
  const BranchMapScreen({
    super.key,
    required this.session,
    required this.api,
    this.location,
    this.tileProvider,
  });
  final SessionController session;
  final BranchesApi api;
  final BranchLocation? location;
  // Allows offline widget verification without contacting the tile service.
  final TileProvider? tileProvider;
  @override
  State<BranchMapScreen> createState() => _BranchMapScreenState();
}

class _BranchMapScreenState extends State<BranchMapScreen> {
  final _map = MapController();
  BranchCatalog? _catalog;
  BranchRoute? _route;
  LatLng? _origin;
  bool _busy = false, _demo = false, _tileError = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await widget.session.authorized(
        widget.api.read,
        role: AppRole.customer,
      );
      if (mounted) setState(() => _catalog = result);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not load demo offices. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fit() {
    final catalog = _catalog;
    if (catalog == null) return;
    final points =
        _route?.points ??
        [
          ?_origin,
          ...(_origin == null ? catalog.branches : catalog.nearby(_origin!))
              .map((b) => b.point),
        ];
    if (points.length > 1) {
      _map.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.all(35),
          maxZoom: 16,
        ),
      );
    } else if (points.isNotEmpty) {
      _map.move(points.first, 15);
    }
  }

  Future<void> _locate({required bool demo}) async {
    setState(() {
      _busy = true;
      _message = null;
      _route = null;
      _origin = null;
    });
    try {
      final point = demo
          ? _catalog!.demoOrigin
          : await (widget.location ?? DeviceBranchLocation()).current();
      if (!mounted) return;
      setState(() {
        _origin = point;
        _demo = demo;
      });
      _fit();
    } on BranchLocationException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Location unavailable. Try the demo starting point.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _walk() async {
    final origin = _origin!;
    setState(() {
      _busy = true;
      _message = null;
      _route = null;
    });
    try {
      final route = await widget.session.authorized(
        (token) => widget.api.route(token, origin),
        role: AppRole.customer,
      );
      if (!mounted) return;
      if (route.branchId != _catalog!.nearby(origin).first.id) {
        throw const FormatException('Destination changed');
      }
      setState(() => _route = route);
      _fit();
    } on BranchRouteException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Walking route unavailable. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _link(String url) async {
    try {
      if (await launchUrl(Uri.parse(url))) return;
    } catch (_) {
      /* Show failure without hiding attribution. */
    }
    if (mounted) {
      setState(() => _message = 'Could not open the map information link.');
    }
  }

  Widget _marker(LatLng point, String label, {bool origin = false}) => Tooltip(
    message: label,
    child: Semantics(
      label: label,
      child: Icon(
        origin ? Icons.my_location : Icons.location_on,
        color: origin ? NeneColors.ink : NeneColors.action,
        size: 36,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final nearby = catalog == null
        ? <DemoBranch>[]
        : _origin == null
        ? catalog.branches
        : catalog.nearby(_origin!);
    return WorkspaceContent(
      children: [
        Text(
          'Find a Nene office',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'Demo locations near TDTU, Ho Chi Minh City. These are fictional Nene offices, not real bank branches or TDTU facilities.',
        ),
        const SizedBox(height: 16),
        if (_busy)
          const LinearProgressIndicator(
            semanticsLabel: 'Loading map information',
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Semantics(liveRegion: true, child: Text(_message!)),
          ),
        if (catalog == null && !_busy)
          FilledButton(onPressed: _load, child: const Text('Retry offices')),
        if (catalog != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              height: 300,
              child: FlutterMap(
                mapController: _map,
                options: MapOptions(
                  initialCenter: catalog.demoOrigin,
                  initialZoom: 14,
                  minZoom: 3,
                  maxZoom: 18,
                  interactionOptions: const InteractionOptions(
                    flags:
                        InteractiveFlag.drag |
                        InteractiveFlag.pinchZoom |
                        InteractiveFlag.doubleTapZoom |
                        InteractiveFlag.scrollWheelZoom,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName:
                        'NeneCourseDemo (https://github.com/tamir39/nene)',
                    tileProvider: widget.tileProvider,
                    errorTileCallback: (_, _, _) {
                      if (mounted && !_tileError) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) setState(() => _tileError = true);
                        });
                      }
                    },
                  ),
                  if (_route != null)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: _route!.points,
                          color: NeneColors.action,
                          strokeWidth: 5,
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: [
                      for (final branch in nearby)
                        Marker(
                          point: branch.point,
                          width: 44,
                          height: 44,
                          child: _marker(branch.point, branch.name),
                        ),
                      if (_origin != null)
                        Marker(
                          point: _origin!,
                          width: 44,
                          height: 44,
                          child: _marker(
                            _origin!,
                            _demo ? 'Demo starting point' : 'My location',
                            origin: true,
                          ),
                        ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Material(
                      color: Colors.white,
                      child: TextButton(
                        onPressed: () =>
                            _link('https://www.openstreetmap.org/copyright'),
                        child: const Text('© OpenStreetMap contributors'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () =>
                    _link('https://www.openstreetmap.org/fixthemap'),
                child: const Text('Fix the map'),
              ),
            ],
          ),
          if (_tileError)
            const Text(
              'Some map tiles could not load. The office list remains available. Reopen this screen to retry the map.',
            ),
          const SizedBox(height: 8),
          const Text(
            'Location is used once, not tracked. The map service receives the area you view. Requesting a route sends the starting point to our walking-route provider; Nene does not save it.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : () => _locate(demo: false),
            icon: const Icon(Icons.my_location),
            label: const Text('Use my location'),
          ),
          TextButton(
            onPressed: _busy ? null : () => _locate(demo: true),
            child: const Text('Use TDTU demo starting point'),
          ),
          if (_origin != null) ...[
            Text(
              _demo
                  ? 'Starting from: TDTU demo point'
                  : 'Starting from: your location',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Nearby means within 5 km in a straight line. The nearest office is selected using that distance.',
            ),
            if (nearby.isNotEmpty) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy ? null : _walk,
                icon: const Icon(Icons.directions_walk),
                label: const Text('Walking route to nearest'),
              ),
            ] else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No demo offices within 5 km. Try the TDTU demo starting point.',
                ),
              ),
          ],
          if (_route != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                'Walking to ${nearby.first.name}\n${_route!.distanceMeters} m · about ${(_route!.durationSeconds / 60).ceil()} min',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Text(
              'Shortest-distance walking route on available map paths. Demo destination only.',
            ),
            TextButton(
              onPressed: () => _link('https://valhalla.openstreetmap.de'),
              child: const Text('Routing: Valhalla / FOSSGIS'),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            _origin == null
                ? 'All ${nearby.length} demo offices'
                : '${nearby.length} nearby demo offices',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          for (final branch in nearby)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      branch.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(branch.area),
                    if (_origin != null)
                      Text(
                        '${branchDistance(_origin!, branch.point).round()} m in a straight line${branch == nearby.first ? ' · nearest' : ''}',
                      ),
                    const Text('Fictional office · no banking services here'),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}
