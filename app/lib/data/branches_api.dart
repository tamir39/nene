import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'profile_api.dart';

LatLng branchPoint(dynamic value) {
  final data = value as Map<String, dynamic>;
  final lat = (data['latitude'] as num).toDouble();
  final lon = (data['longitude'] as num).toDouble();
  if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
    throw const FormatException('Invalid coordinates');
  }
  return LatLng(lat, lon);
}

double branchDistance(LatLng a, LatLng b) {
  const rad = math.pi / 180;
  final h =
      math.pow(math.sin((b.latitude - a.latitude) * rad / 2), 2) +
      math.cos(a.latitude * rad) *
          math.cos(b.latitude * rad) *
          math.pow(math.sin((b.longitude - a.longitude) * rad / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(math.min(1, h)));
}

class DemoBranch {
  DemoBranch(Map<String, dynamic> data)
    : id = data['id'] as String,
      name = data['name'] as String,
      area = data['area'] as String,
      point = branchPoint(data) {
    if (id.isEmpty || name.isEmpty || data['isDemo'] != true) {
      throw const FormatException('Invalid demo office');
    }
  }
  final String id, name, area;
  final LatLng point;
}

class BranchCatalog {
  BranchCatalog(Map<String, dynamic> data)
    : branches = (data['branches'] as List)
          .map((b) => DemoBranch(b as Map<String, dynamic>))
          .toList(),
      demoOrigin = branchPoint(data['demoOrigin']),
      radiusMeters = data['nearbyRadiusMeters'] as int {
    if (branches.length > 100 ||
        branches.map((b) => b.id).toSet().length != branches.length ||
        radiusMeters != 5000) {
      throw const FormatException('Invalid catalog');
    }
  }
  final List<DemoBranch> branches;
  final LatLng demoOrigin;
  final int radiusMeters;
  List<DemoBranch> nearby(LatLng origin) =>
      branches
          .where((b) => branchDistance(origin, b.point) <= radiusMeters)
          .toList()
        ..sort((a, b) {
          final d = branchDistance(
            origin,
            a.point,
          ).compareTo(branchDistance(origin, b.point));
          return d != 0 ? d : a.id.compareTo(b.id);
        });
}

class BranchRoute {
  BranchRoute(Map<String, dynamic> data)
    : branchId = data['branchId'] as String,
      distanceMeters = data['distanceMeters'] as int,
      durationSeconds = data['durationSeconds'] as int,
      points = (data['points'] as List).map(branchPoint).toList() {
    if (branchId.isEmpty ||
        distanceMeters < 0 ||
        distanceMeters > 30000 ||
        durationSeconds < 0 ||
        durationSeconds > 86400 ||
        points.length < 2 ||
        points.length > 10000 ||
        data['mode'] != 'walking_shortest_distance' ||
        data['nearestBy'] != 'straight_line') {
      throw const FormatException('Invalid route');
    }
  }
  final String branchId;
  final int distanceMeters, durationSeconds;
  final List<LatLng> points;
}

class BranchRouteException implements Exception {
  const BranchRouteException(this.message);
  final String message;
}

class BranchesApi {
  BranchesApi({required this.baseUrl, required this.client});
  final Uri baseUrl;
  final http.Client client;
  Future<Map<String, dynamic>> _request(String token, {LatLng? origin}) async {
    final req =
        http.Request(
            origin == null ? 'GET' : 'POST',
            baseUrl.resolve(
              origin == null ? 'me/branches' : 'me/branches/route',
            ),
          )
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer $token';
    if (origin != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode({
        'latitude': origin.latitude,
        'longitude': origin.longitude,
      });
    }
    final response = await client
        .send(req)
        .then((stream) async {
          final bytes = <int>[];
          await for (final chunk in stream.stream) {
            if (bytes.length + chunk.length > 1048576) {
              throw const ApiException(ApiFailure.invalidResponse);
            }
            bytes.addAll(chunk);
          }
          return http.Response.bytes(bytes, stream.statusCode);
        })
        .timeout(const Duration(seconds: 18));
    if (response.statusCode == 401) {
      throw const ApiException(ApiFailure.unauthorized);
    }
    if (response.statusCode == 403) {
      throw const ApiException(ApiFailure.forbidden);
    }
    if (response.statusCode == 429) {
      throw const BranchRouteException(
        'Wait a moment, then try the route again.',
      );
    }
    if (response.statusCode == 404 && origin != null) {
      throw const BranchRouteException(
        'No demo office within 5 km of this starting point.',
      );
    }
    if (response.statusCode != 200) {
      throw const ApiException(ApiFailure.unavailable);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<BranchCatalog> read(String token) async =>
      BranchCatalog(await _request(token));
  Future<BranchRoute> route(String token, LatLng origin) async =>
      BranchRoute(await _request(token, origin: origin));
}
