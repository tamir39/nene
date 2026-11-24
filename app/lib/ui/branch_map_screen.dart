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
import 'nene_components.dart';

/// Where a status message belongs on screen, so it appears next to the
/// action that produced it.
enum _Topic { offices, location, route, link }

final _compact = TextButton.styleFrom(
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: 8),
);

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
  _Topic _topic = _Topic.offices;
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
        setState(() {
          _topic = _Topic.offices;
          _message = 'Could not load demo offices. Try again.';
        });
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
      if (mounted) {
        setState(() {
          _topic = _Topic.location;
          _message = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _topic = _Topic.location;
          _message = 'Location unavailable. Try the demo starting point.';
        });
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
      if (mounted) {
        setState(() {
          _topic = _Topic.route;
          _message = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _topic = _Topic.route;
          _message =
              'Walking route unavailable. Check your connection and try again.';
        });
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
      setState(() {
        _topic = _Topic.link;
        _message = 'Could not open the map information link.';
      });
    }
  }

  /// The message for [topic], shown beside the action that produced it.
  Widget? _alert(_Topic topic, IconData icon) =>
      _message == null || _topic != topic ? null : _Alert(icon, _message!);

  Widget _marker(LatLng point, String label, {bool origin = false}) => Tooltip(
    message: label,
    child: Semantics(
      label: label,
      child: origin
          ? Center(
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: NeneColors.deep,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 4),
                  boxShadow: [
                    BoxShadow(
                      color: NeneColors.deep.withValues(alpha: .35),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            )
          : const Icon(Icons.location_on, color: NeneColors.action, size: 38),
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
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 14),
        const NeneBanner(
          icon: Icons.info_outline_rounded,
          title: 'Demo offices only',
          body:
              'Demo locations near TDTU, Ho Chi Minh City. These are fictional Nene offices, not real bank branches or TDTU facilities.',
        ),
        const SizedBox(height: 16),
        if (catalog == null)
          _busy
              ? const _StateCard(
                  icon: Icons.map_outlined,
                  title: 'Loading demo offices',
                  child: LinearProgressIndicator(
                    semanticsLabel: 'Loading map information',
                  ),
                )
              : _StateCard(
                  icon: Icons.cloud_off_outlined,
                  title: 'Offices unavailable',
                  body: _message,
                  child: FilledButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Retry offices'),
                  ),
                ),
        if (catalog != null) ...[
          _mapCard(catalog, nearby),
          const SizedBox(height: 16),
          _startCard(),
          if (_origin != null) ...[
            const SizedBox(height: 16),
            nearby.isEmpty
                ? const _StateCard(
                    icon: Icons.wrong_location_outlined,
                    title: 'No office nearby',
                    body:
                        'No demo offices within 5 km. Try the TDTU demo starting point.',
                  )
                : _nearestCard(nearby.first),
          ],
          if (nearby.isNotEmpty) ...[
            const SizedBox(height: 24),
            SectionTitle(
              _origin == null
                  ? 'All ${nearby.length} demo offices'
                  : '${nearby.length} nearby demo offices',
            ),
          ],
          for (final branch in nearby) ...[
            _OfficeTile(
              branch,
              meters: _origin == null
                  ? null
                  : branchDistance(_origin!, branch.point).round(),
              nearest: _origin != null && branch == nearby.first,
            ),
            const SizedBox(height: 12),
          ],
        ],
      ],
    );
  }

  Widget _mapCard(BranchCatalog catalog, List<DemoBranch> nearby) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: NeneColors.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 280,
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
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
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
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Material(
                    color: Colors.white.withValues(alpha: .92),
                    borderRadius: BorderRadius.circular(10),
                    child: TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: const TextStyle(
                          fontFamily: neneFontFamily,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      onPressed: () =>
                          _link('https://www.openstreetmap.org/copyright'),
                      child: const Text('© OpenStreetMap contributors'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_busy)
          const LinearProgressIndicator(
            minHeight: 3,
            semanticsLabel: 'Loading map information',
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.pinch_outlined, size: 18, color: NeneColors.muted),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Drag or pinch to explore',
                      style: TextStyle(color: NeneColors.muted, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () =>
                    _link('https://www.openstreetmap.org/fixthemap'),
                child: const Text('Fix the map'),
              ),
            ],
          ),
        ),
        if (_tileError)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: _Alert(
              Icons.cloud_off_outlined,
              'Some map tiles could not load. The office list remains available. Reopen this screen to retry the map.',
            ),
          ),
        if (_alert(_Topic.link, Icons.link_off_rounded) case final alert?)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: alert,
          ),
      ],
    ),
  );

  Widget _startCard() {
    final chosen = _origin != null;
    final alert = _alert(_Topic.location, Icons.location_off_outlined);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _IconTile(
                  chosen
                      ? (_demo ? Icons.school_outlined : Icons.my_location)
                      : Icons.near_me_outlined,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Starting point',
                        style: TextStyle(color: NeneColors.muted, fontSize: 13),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        !chosen
                            ? 'Choose where to start'
                            : _demo
                            ? 'Starting from: TDTU demo point'
                            : 'Starting from: your location',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (chosen) ...[
              const SizedBox(height: 12),
              const Text(
                'Nearby means within 5 km in a straight line. The nearest office is selected using that distance.',
                style: TextStyle(color: NeneColors.muted, fontSize: 13),
              ),
            ],
            if (alert != null) ...[const SizedBox(height: 14), alert],
            const SizedBox(height: 16),
            if (!chosen) ...[
              FilledButton.icon(
                onPressed: _busy ? null : () => _locate(demo: false),
                icon: const Icon(Icons.my_location),
                label: const Text('Use my location'),
              ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: _busy ? null : () => _locate(demo: true),
                icon: const Icon(Icons.school_outlined),
                label: const Text('Use TDTU demo starting point'),
              ),
            ] else
              // Changing the starting point is secondary once one is chosen.
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextButton.icon(
                    style: _compact,
                    onPressed: _busy ? null : () => _locate(demo: false),
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text('Use my location'),
                  ),
                  TextButton.icon(
                    style: _compact,
                    onPressed: _busy ? null : () => _locate(demo: true),
                    icon: const Icon(Icons.school_outlined, size: 18),
                    label: const Text('Use TDTU demo starting point'),
                  ),
                ],
              ),
            const Divider(height: 28),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 18,
                  color: NeneColors.muted,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Location is used once, not tracked. The map service receives the area you view. Requesting a route sends the starting point to our walking-route provider; Nene does not save it.',
                    style: TextStyle(color: NeneColors.muted, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _nearestCard(DemoBranch branch) {
    final route = _route;
    final alert = _alert(_Topic.route, Icons.directions_off_outlined);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _IconTile(Icons.storefront_outlined, filled: true),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _Pill('Nearest office'),
                      const SizedBox(height: 6),
                      Text(
                        branch.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        branch.area,
                        style: const TextStyle(
                          color: NeneColors.muted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (route != null) ...[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: NeneColors.pale,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Walking to ${branch.name}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 20,
                        runSpacing: 8,
                        children: [
                          _RouteStat(
                            icon: Icons.directions_walk_rounded,
                            value: '${route.distanceMeters} m',
                          ),
                          _RouteStat(
                            icon: Icons.schedule_rounded,
                            value:
                                'about ${(route.durationSeconds / 60).ceil()} min',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Shortest-distance walking route on available map paths. Demo destination only.',
                style: TextStyle(color: NeneColors.muted, fontSize: 12.5),
              ),
            ],
            if (alert != null) ...[const SizedBox(height: 14), alert],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _walk,
              icon: const Icon(Icons.directions_walk),
              label: const Text('Walking route to nearest'),
            ),
            if (route != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: const TextStyle(
                      fontFamily: neneFontFamily,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: () => _link('https://valhalla.openstreetmap.de'),
                  child: const Text('Routing: Valhalla / FOSSGIS'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile(this.icon, {this.filled = false});
  final IconData icon;
  final bool filled;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      color: filled ? NeneColors.action : NeneColors.pale,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Icon(icon, color: filled ? Colors.white : NeneColors.action),
  );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: NeneColors.apricotSoft,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: NeneColors.deep,
      ),
    ),
  );
}

class _RouteStat extends StatelessWidget {
  const _RouteStat({required this.icon, required this.value});
  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 20, color: NeneColors.action),
      const SizedBox(width: 6),
      Text(
        value,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          fontFeatures: neneTabularFigures,
        ),
      ),
    ],
  );
}

/// Inline status message with an icon, announced to assistive technology.
class _Alert extends StatelessWidget {
  const _Alert(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: NeneColors.apricotSoft,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: NeneColors.deep),
        const SizedBox(width: 10),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(text, style: const TextStyle(fontSize: 13.5)),
          ),
        ),
      ],
    ),
  );
}

/// Whole-section state (loading, unavailable, nothing nearby).
class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.title,
    this.body,
    this.child,
  });
  final IconData icon;
  final String title;
  final String? body;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: NeneColors.pale,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, size: 28, color: NeneColors.action),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (body != null) ...[
            const SizedBox(height: 6),
            Semantics(
              liveRegion: true,
              child: Text(
                body!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: NeneColors.muted),
              ),
            ),
          ],
          if (child != null) ...[const SizedBox(height: 18), child!],
        ],
      ),
    ),
  );
}

class _OfficeTile extends StatelessWidget {
  const _OfficeTile(this.branch, {this.meters, this.nearest = false});
  final DemoBranch branch;
  final int? meters;
  final bool nearest;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _IconTile(Icons.storefront_outlined),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  branch.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  branch.area,
                  style: const TextStyle(color: NeneColors.muted, fontSize: 13),
                ),
                if (meters != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '$meters m in a straight line${nearest ? ' · nearest' : ''}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: NeneColors.deep,
                      fontFeatures: neneTabularFigures,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                const Text(
                  'Fictional office · no banking services here',
                  style: TextStyle(color: NeneColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
