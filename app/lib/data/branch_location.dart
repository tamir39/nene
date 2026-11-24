import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

class BranchLocationException implements Exception {
  const BranchLocationException(this.message);
  final String message;
}

abstract interface class BranchLocation {
  Future<LatLng> current();
}

class DeviceBranchLocation implements BranchLocation {
  @override
  Future<LatLng> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const BranchLocationException(
          'Location services are off. Enable them, or use the demo starting point.',
        );
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw const BranchLocationException(
          'Location permission is blocked. Allow it in browser or device settings, or use the demo starting point.',
        );
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      return LatLng(position.latitude, position.longitude);
    } on BranchLocationException {
      rethrow;
    } catch (_) {
      throw const BranchLocationException(
        'Could not get your location. On a phone, an HTTP LAN address may block location access. Use the demo starting point, or test location on localhost in Edge.',
      );
    }
  }
}
