import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';

/// A business listing owned by a signed-in owner.
class OwnerStore {
  const OwnerStore({
    required this.id,
    required this.name,
    required this.description,
    required this.status,
    this.placeCount = 0,
  });

  final String id;
  final String name;
  final String description;
  final String status;
  final int placeCount;

  bool get isPublished => status == 'published';
}

/// A place owned by a store, as the owner sees it (pending or published).
class OwnerPlace {
  const OwnerPlace({
    required this.id,
    required this.name,
    required this.category,
    required this.latitude,
    required this.longitude,
    required this.status,
    this.address = '',
    this.description = '',
  });

  final String id;
  final String name;
  final String category;
  final double latitude;
  final double longitude;
  final String status;
  final String address;
  final String description;

  bool get isPublished => status == 'published';
  LatLng get point => LatLng(latitude, longitude);
}

/// Read and write access for the store-owner side of the product.
///
/// The upload rules are enforced by the database, not here: an owner may only
/// attach a place to a store they own, and publication goes through the guarded
/// `set_place_published` function. This class just reports what the server says
/// when it refuses.
class StoresRepository {
  StoresRepository({http.Client? client, String? accessToken})
      : _client = client ?? http.Client(),
        _token = accessToken;

  final http.Client _client;
  final String? _token;

  Map<String, String> get _headers => {
        'apikey': AppConfig.supabaseAnonKey,
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  String get _rest => '${AppConfig.supabaseUrl}/rest/v1';

  /// Stores belonging to the signed-in owner.
  Future<List<OwnerStore>> myStores() async {
    final res = await _client.get(
      Uri.parse('$_rest/stores?select=id,name,description,status&order=created_at.desc'),
      headers: _headers,
    );
    _throwIfFailed(res, 'Could not load your stores');
    final rows = _rows(res);

    final stores = <OwnerStore>[];
    for (final r in rows) {
      final id = '${r['id']}';
      // PostgREST can count the related rows for us.
      final countRes = await _client.get(
        Uri.parse('$_rest/places?select=id&store_id=eq.$id'),
        headers: _headers,
      );
      stores.add(OwnerStore(
        id: id,
        name: '${r['name']}',
        description: '${r['description'] ?? ''}',
        status: '${r['status'] ?? 'pending'}',
        placeCount: _rows(countRes).length,
      ));
    }
    return stores;
  }

  /// Places belonging to the signed-in owner, pending ones included.
  Future<List<OwnerPlace>> myPlaces() async {
    final res = await _client.get(
      Uri.parse('$_rest/places?select=id,name,category,description,address_text,'
          'latitude,longitude,status&order=created_at.desc'),
      headers: _headers,
    );
    _throwIfFailed(res, 'Could not load your places');
    return _rows(res).map((r) => OwnerPlace(
          id: '${r['id']}',
          name: '${r['name']}',
          category: '${r['category'] ?? 'other'}',
          latitude: (r['latitude'] as num).toDouble(),
          longitude: (r['longitude'] as num).toDouble(),
          status: '${r['status'] ?? 'pending'}',
          address: '${r['address_text'] ?? ''}',
          description: '${r['description'] ?? ''}',
        )).toList();
  }

  /// Cities available when registering a store.
  Future<List<({String id, String name})>> cities() async {
    final res = await _client.get(
      Uri.parse('$_rest/cities?select=id,name&order=name'),
      headers: _headers,
    );
    _throwIfFailed(res, 'Could not load cities');
    return _rows(res)
        .map((r) => (id: '${r['id']}', name: '${r['name']}'))
        .toList();
  }

  /// Creates a store for the signed-in owner.
  ///
  /// [ownerId] is the caller's own id. The database re-checks it against the
  /// JWT, so a mismatch is refused rather than obeyed.
  Future<String> createStore({
    required String ownerId,
    required String cityId,
    required String name,
    String description = '',
    bool publish = true,
  }) async {
    final res = await _client.post(
      Uri.parse('$_rest/stores'),
      headers: {..._headers, 'Prefer': 'return=representation'},
      body: jsonEncode({
        'owner_id': ownerId,
        'city_id': cityId,
        'name': name,
        'description': description,
        'status': publish ? 'published' : 'pending',
      }),
    );
    _throwIfFailed(res, 'Could not create the store');
    final rows = _rows(res);
    if (rows.isEmpty) throw StoresException('The store was created but not returned.');
    return '${rows.first['id']}';
  }

  /// Adds a place to a store the caller owns.
  ///
  /// The place starts `pending`, so it is visible to the owner and to nobody
  /// else until it is published.
  Future<String> createPlace({
    required String storeId,
    required String cityId,
    required String name,
    required String category,
    required LatLng point,
    String address = '',
    String description = '',
  }) async {
    final res = await _client.post(
      Uri.parse('$_rest/places'),
      headers: {..._headers, 'Prefer': 'return=representation'},
      body: jsonEncode({
        'store_id': storeId,
        'city_id': cityId,
        'name': name,
        'category': category,
        'description': description,
        'address_text': address,
        'latitude': point.latitude,
        'longitude': point.longitude,
        'status': 'pending',
      }),
    );
    _throwIfFailed(res, 'Could not add the place');
    final rows = _rows(res);
    if (rows.isEmpty) throw StoresException('The place was created but not returned.');
    return '${rows.first['id']}';
  }

  /// Publishes or unpublishes a place, through the guarded server function.
  Future<void> setPublished(String placeId, bool published) async {
    final res = await _client.post(
      Uri.parse('$_rest/rpc/set_place_published'),
      headers: _headers,
      body: jsonEncode({'p_place_id': placeId, 'p_published': published}),
    );
    _throwIfFailed(res,
        published ? 'Could not publish the place' : 'Could not unpublish the place');
  }

  void close() => _client.close();

  // ----------------------------------------------------------------- plumbing

  List<Map<String, dynamic>> _rows(http.Response res) {
    if (res.body.isEmpty) return const [];
    final decoded = jsonDecode(res.body);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  /// Turns a PostgREST error into something worth showing.
  ///
  /// Row-level security refusals are called out explicitly: "permission denied"
  /// on its own is not an answer a person can act on.
  void _throwIfFailed(http.Response res, String fallback) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    var message = fallback;
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['message'] != null) {
        final raw = '${body['message']}'.toLowerCase();
        if (res.statusCode == 401) {
          message = 'Please sign in again.';
        } else if (raw.contains('row-level security') || res.statusCode == 42501) {
          message = 'You do not have permission to do that.';
        } else if (raw.contains('not your place')) {
          message = 'That listing belongs to another store.';
        } else {
          message = '${body['message']}';
        }
      }
    } catch (_) {
      if (res.statusCode >= 500) message = 'The server had a problem. Try again.';
    }
    throw StoresException(message);
  }
}

class StoresException implements Exception {
  StoresException(this.message);
  final String message;
  @override
  String toString() => message;
}
