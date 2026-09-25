import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

/// A single position fix reported by the device.
class DeviceLocation {
  const DeviceLocation({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.provider,
    this.timestamp,
  });

  final double latitude;
  final double longitude;

  /// Estimated horizontal accuracy in metres, when the platform reports it.
  final double? accuracy;
  final String? provider;
  final DateTime? timestamp;

  LatLng get point => LatLng(latitude, longitude);
}

/// Why getting the location failed.
enum LocationFailure {
  /// The user has not granted (or has permanently denied) the permission.
  permissionDenied,

  /// Location is switched off at the OS level.
  serviceDisabled,

  /// No fix arrived before the platform's timeout.
  timeout,

  /// Something else went wrong; [DeviceLocationService] carries the detail.
  unknown,
}

/// Result of a location request: either a fix or a typed failure.
class LocationResult {
  const LocationResult.success(this.location)
      : failure = null,
        message = null;
  const LocationResult.failed(this.failure, [this.message]) : location = null;

  final DeviceLocation? location;
  final LocationFailure? failure;
  final String? message;

  bool get isSuccess => location != null;
}

/// Reads the phone's location through the `com.revamp/location` MethodChannel
/// implemented in `MainActivity.kt`.
///
/// The channel is hand-rolled rather than using the `geolocator` package so the
/// app pulls in no extra plugin for one feature; see the Kotlin side for why.
class DeviceLocationService {
  const DeviceLocationService();

  static const MethodChannel _channel = MethodChannel('com.revamp/location');

  /// Whether the OS has location switched on at all.
  Future<bool> isServiceEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isServiceEnabled') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Whether location permission has already been granted.
  Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Shows the OS permission prompt. Returns whether it was granted.
  ///
  /// Returns `false` immediately if permission was already denied permanently:
  /// the OS will not show a prompt again, so the UI must send the user to
  /// Settings instead of nagging with a dialog that does nothing.
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Asks the platform for a current position fix.
  ///
  /// Does **not** request permission; call [requestPermission] first.
  Future<LocationResult> getCurrentLocation() async {
    try {
      final raw = await _channel
          .invokeMapMethod<String, dynamic>('getCurrentLocation');
      if (raw == null) {
        return const LocationResult.failed(LocationFailure.unknown);
      }

      final lat = (raw['latitude'] as num?)?.toDouble();
      final lon = (raw['longitude'] as num?)?.toDouble();
      if (lat == null || lon == null) {
        return const LocationResult.failed(LocationFailure.unknown);
      }

      final timestamp = raw['timestamp'] is int
          ? DateTime.fromMillisecondsSinceEpoch(raw['timestamp'] as int)
          : null;

      return LocationResult.success(
        DeviceLocation(
          latitude: lat,
          longitude: lon,
          accuracy: (raw['accuracy'] as num?)?.toDouble(),
          provider: raw['provider']?.toString(),
          timestamp: timestamp,
        ),
      );
    } on PlatformException catch (e) {
      return LocationResult.failed(_mapCode(e.code), e.message);
    } on MissingPluginException {
      return const LocationResult.failed(
        LocationFailure.unknown,
        'Location support is unavailable in this build.',
      );
    }
  }

  static LocationFailure _mapCode(String code) => switch (code) {
        'permission_denied' => LocationFailure.permissionDenied,
        'service_disabled' => LocationFailure.serviceDisabled,
        'timeout' => LocationFailure.timeout,
        _ => LocationFailure.unknown,
      };
}
