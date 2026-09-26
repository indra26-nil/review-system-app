import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/place.dart';
import '../services/auth_service.dart';
import '../services/stores_repository.dart';
import '../theme/app_tokens.dart';

/// The store owner's workspace: register a business, list places, publish them.
///
/// Uploading follows the same product rule as the map: a place is added by
/// tapping a location, so what gets listed is the point the owner chose rather
/// than a typed address that might not exist.
class OwnerDashboard extends StatefulWidget {
  const OwnerDashboard({
    super.key,
    required this.account,
    required this.repositories,
  });

  final Account account;

  /// One repository per session, so the token stays current.
  final StoresRepository Function(String? token) repositories;

  @override
  State<OwnerDashboard> createState() => _OwnerDashboardState();
}

class _OwnerDashboardState extends State<OwnerDashboard> {
  late final StoresRepository _repo = widget.repositories(widget.account.isOwner ? _token : null);
  String? _token;

  List<OwnerStore> _stores = const [];
  List<OwnerPlace> _places = const [];
  List<({String id, String name})> _cities = const [];
  bool _loading = true;
  String? _error;

  /// The point the owner chose on the map, if any; pre-fills a new listing.
  LatLng? _pickedPoint;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _repo.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _repo.myStores(),
        _repo.myPlaces(),
        _repo.cities(),
      ]);
      if (!mounted) return;
      setState(() {
        _stores = results[0] as List<OwnerStore>;
        _places = results[1] as List<OwnerPlace>;
        _cities = results[2] as List<({String id, String name})>;
        _loading = false;
      });
    } on StoresException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach the server.';
        _loading = false;
      });
    }
  }

  Future<void> _createStore() async {
    final result = await showModalBottomSheet<({String name, String cityId, String description})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTokens.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTokens.radiusSheet)),
      ),
      builder: (_) => _StoreForm(cities: _cities),
    );
    if (result == null || !mounted) return;
    try {
      await _repo.createStore(
        ownerId: widget.account.id,
        cityId: result.cityId,
        name: result.name,
        description: result.description,
      );
      await _load();
      if (mounted) _toast('Store created');
    } on StoresException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  /// Adds a place. [point] is the coordinate chosen on the map, so the listing
  /// sits exactly where the owner put it.
  /// Where a new listing starts: the point the owner chose on the map,
  /// so what they list is where they actually tapped.
  Future<void> _addPlace(OwnerStore store, {LatLng? pickedPoint}) async {
    final result = await showModalBottomSheet<
        ({String name, String category, String address, String description, LatLng point})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTokens.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTokens.radiusSheet)),
      ),
      builder: (_) => _PlaceForm(initialPoint: pickedPoint),
    );
    if (result == null || !mounted) return;
    try {
      await _repo.createPlace(
        storeId: store.id,
        cityId: _cities.isNotEmpty ? _cities.first.id : '',
        name: result.name,
        category: result.category,
        point: result.point,
        address: result.address,
        description: result.description,
      );
      await _load();
      if (mounted) _toast('Place added — publish it to make it visible');
    } on StoresException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  Future<void> _togglePublish(OwnerPlace place) async {
    try {
      await _repo.setPublished(place.id, !place.isPublished);
      await _load();
      if (mounted) {
        _toast(place.isPublished ? 'Place hidden from other users' : 'Place is now visible to everyone');
      }
    } on StoresException catch (e) {
      if (mounted) _toast(e.message);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your business')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorPane(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                        AppTokens.gutter, AppTokens.s12, AppTokens.gutter, AppTokens.s32),
                    children: [
                      _Header(account: widget.account, storeCount: _stores.length),
                      const SizedBox(height: AppTokens.s24),

                      Row(
                        children: [
                          Expanded(
                            child: Text('Your stores', style: AppTokens.titleMd),
                          ),
                          TextButton.icon(
                            onPressed: _createStore,
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('Register'),
                            style: TextButton.styleFrom(foregroundColor: AppTokens.accent),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppTokens.s8),
                      if (_stores.isEmpty)
                        const _EmptyNote('No stores yet. Register your business to start listing places.')
                      else
                        for (final store in _stores) ...[
                          _StoreCard(
                            store: store,
                            onAddPlace: () =>
                                _addPlace(store, pickedPoint: _pickedPoint),
                          ),
                          const SizedBox(height: AppTokens.s12),
                        ],

                      const SizedBox(height: AppTokens.s20),
                      Text('Your places', style: AppTokens.titleMd),
                      const SizedBox(height: AppTokens.s8),
                      if (_places.isEmpty)
                        const _EmptyNote('No places yet. Add one from a store above.')
                      else
                        for (final place in _places) ...[
                          _PlaceRow(
                            place: place,
                            onTogglePublish: () => _togglePublish(place),
                          ),
                          const SizedBox(height: AppTokens.s8),
                        ],
                    ],
                  ),
                ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.account, required this.storeCount});
  final Account account;
  final int storeCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: AppTokens.accentSoft,
            borderRadius: BorderRadius.circular(AppTokens.radiusButton),
          ),
          child: const Icon(Icons.storefront_rounded, size: 24, color: AppTokens.accent),
        ),
        const SizedBox(width: AppTokens.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(account.displayName, style: AppTokens.titleSm),
              const SizedBox(height: 2),
              Text(
                storeCount == 0
                    ? 'Store owner'
                    : '$storeCount store${storeCount == 1 ? '' : 's'}',
                style: AppTokens.metadata,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StoreCard extends StatelessWidget {
  const _StoreCard({required this.store, required this.onAddPlace});
  final OwnerStore store;
  final VoidCallback onAddPlace;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: AppTokens.background,
        borderRadius: BorderRadius.circular(AppTokens.radiusCard),
        boxShadow: AppTokens.controlShadow,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(store.name, style: AppTokens.titleSm),
                const SizedBox(height: 2),
                Text(
                  '${store.placeCount} place${store.placeCount == 1 ? '' : 's'}'
                  '${store.isPublished ? '' : '  ·  not visible yet'}',
                  style: AppTokens.metadata,
                ),
              ],
            ),
          ),
          FilledButton.tonal(
            onPressed: onAddPlace,
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.accentSoft,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusButton),
              ),
            ),
            child: const Text('Add place', style: TextStyle(fontSize: 13.5)),
          ),
        ],
      ),
    );
  }
}

class _PlaceRow extends StatelessWidget {
  const _PlaceRow({required this.place, required this.onTogglePublish});
  final OwnerPlace place;
  final VoidCallback onTogglePublish;

  @override
  Widget build(BuildContext context) {
    final published = place.isPublished;
    return Container(
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: AppTokens.background,
        borderRadius: BorderRadius.circular(AppTokens.radiusCard),
        boxShadow: AppTokens.controlShadow,
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: published ? AppTokens.successSoft : AppTokens.surfaceMuted,
              borderRadius: BorderRadius.circular(AppTokens.radiusButton - 4),
            ),
            child: Icon(
              published ? Icons.visibility_rounded : Icons.visibility_off_rounded,
              size: 19,
              color: published ? AppTokens.success : AppTokens.textMuted,
            ),
          ),
          const SizedBox(width: AppTokens.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(place.name, style: AppTokens.titleSm),
                const SizedBox(height: 2),
                Text(
                  published
                      ? 'Visible to everyone'
                      : 'Pending — only you can see this',
                  style: AppTokens.metadata.copyWith(
                    color: published ? AppTokens.success : AppTokens.warning,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onTogglePublish,
            style: TextButton.styleFrom(foregroundColor: AppTokens.accent),
            child: Text(published ? 'Hide' : 'Publish'),
          ),
        ],
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTokens.s20),
      decoration: BoxDecoration(
        color: AppTokens.surfaceMuted,
        borderRadius: BorderRadius.circular(AppTokens.radiusCard),
      ),
      child: Text(text, style: AppTokens.caption, textAlign: TextAlign.center),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 34, color: AppTokens.textMuted),
            const SizedBox(height: AppTokens.s12),
            Text(message, style: AppTokens.bodySecondary, textAlign: TextAlign.center),
            const SizedBox(height: AppTokens.s16),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- forms

class _StoreForm extends StatefulWidget {
  const _StoreForm({required this.cities});
  final List<({String id, String name})> cities;

  @override
  State<_StoreForm> createState() => _StoreFormState();
}

class _StoreFormState extends State<_StoreForm> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  late String _cityId = widget.cities.isNotEmpty ? widget.cities.first.id : '';

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppTokens.gutter,
        0,
        AppTokens.gutter,
        MediaQuery.viewInsetsOf(context).bottom + AppTokens.s24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTokens.grabber,
          Text('Register your business', style: AppTokens.titleMd),
          const SizedBox(height: AppTokens.s16),
          TextField(
            controller: _name,
            style: AppTokens.body,
            decoration: const InputDecoration(
              hintText: 'Business name',
              filled: true,
              fillColor: AppTokens.surfaceMuted,
              border: InputBorder.none,
            ),
          ),
          const SizedBox(height: AppTokens.s12),
          TextField(
            controller: _description,
            style: AppTokens.body,
            maxLines: 2,
            decoration: const InputDecoration(
              hintText: 'A short description (optional)',
              filled: true,
              fillColor: AppTokens.surfaceMuted,
              border: InputBorder.none,
            ),
          ),
          if (widget.cities.isNotEmpty) ...[
            const SizedBox(height: AppTokens.s12),
            DropdownButtonFormField<String>(
              initialValue: _cityId,
              style: AppTokens.body,
              decoration: const InputDecoration(
                labelText: 'City',
                filled: true,
                fillColor: AppTokens.surfaceMuted,
                border: InputBorder.none,
              ),
              items: [
                for (final c in widget.cities)
                  DropdownMenuItem(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _cityId = v ?? _cityId),
            ),
          ],
          const SizedBox(height: AppTokens.s20),
          FilledButton(
            onPressed: _name.text.trim().isEmpty
                ? null
                : () => Navigator.of(context).pop((
                      name: _name.text.trim(),
                      cityId: _cityId,
                      description: _description.text.trim(),
                    )),
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.accent,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTokens.radiusButton),
              ),
            ),
            child: const Text('Create store', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _PlaceForm extends StatefulWidget {
  const _PlaceForm({this.initialPoint});
  final LatLng? initialPoint;

  @override
  State<_PlaceForm> createState() => _PlaceFormState();
}

class _PlaceFormState extends State<_PlaceForm> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _description = TextEditingController();
  late double _lat = widget.initialPoint?.latitude ?? 12.9716;
  late double _lng = widget.initialPoint?.longitude ?? 77.5946;
  String _category = PlaceCategory.restaurant.name;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppTokens.gutter,
        0,
        AppTokens.gutter,
        MediaQuery.viewInsetsOf(context).bottom + AppTokens.s24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTokens.grabber,
            Text('Add a place', style: AppTokens.titleMd),
            const SizedBox(height: AppTokens.s16),
            TextField(
              controller: _name,
              style: AppTokens.body,
              decoration: const InputDecoration(
                hintText: 'Place name',
                filled: true,
                fillColor: AppTokens.surfaceMuted,
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: AppTokens.s12),
            DropdownButtonFormField<String>(
              initialValue: _category,
              style: AppTokens.body,
              decoration: const InputDecoration(
                labelText: 'Category',
                filled: true,
                fillColor: AppTokens.surfaceMuted,
                border: InputBorder.none,
              ),
              items: [
                for (final c in PlaceCategory.values)
                  DropdownMenuItem(value: c.name, child: Text(c.label)),
              ],
              onChanged: (v) => setState(() => _category = v ?? _category),
            ),
            const SizedBox(height: AppTokens.s12),
            TextField(
              controller: _address,
              style: AppTokens.body,
              decoration: const InputDecoration(
                hintText: 'Address (optional)',
                filled: true,
                fillColor: AppTokens.surfaceMuted,
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: AppTokens.s12),
            TextField(
              controller: _description,
              style: AppTokens.body,
              maxLines: 2,
              decoration: const InputDecoration(
                hintText: 'Description (optional)',
                filled: true,
                fillColor: AppTokens.surfaceMuted,
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: AppTokens.s16),
            // The map's chosen point, editable here for owners who are not
            // looking at the map right now.
            Container(
              padding: const EdgeInsets.all(AppTokens.s12),
              decoration: BoxDecoration(
                color: AppTokens.surfaceMuted,
                borderRadius: BorderRadius.circular(AppTokens.radiusButton),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Location', style: AppTokens.titleSm),
                  const SizedBox(height: 4),
                  Text(
                    '${_lat.toStringAsFixed(5)}, ${_lng.toStringAsFixed(5)}',
                    style: AppTokens.metadata,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: _lat.toStringAsFixed(5),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                          decoration: const InputDecoration(labelText: 'Latitude', isDense: true),
                          onChanged: (v) => setState(() => _lat = double.tryParse(v) ?? _lat),
                        ),
                      ),
                      const SizedBox(width: AppTokens.s12),
                      Expanded(
                        child: TextFormField(
                          initialValue: _lng.toStringAsFixed(5),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                          decoration: const InputDecoration(labelText: 'Longitude', isDense: true),
                          onChanged: (v) => setState(() => _lng = double.tryParse(v) ?? _lng),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTokens.s20),
            FilledButton(
              onPressed: _name.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop((
                        name: _name.text.trim(),
                        category: _category,
                        address: _address.text.trim(),
                        description: _description.text.trim(),
                        point: LatLng(_lat, _lng),
                      )),
              style: FilledButton.styleFrom(
                backgroundColor: AppTokens.accent,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTokens.radiusButton),
                ),
              ),
              child: const Text('Add place', style: TextStyle(color: Colors.white)),
            ),
            const SizedBox(height: AppTokens.s8),
            Text(
              'Added places start as pending. Publish them to make them visible to everyone.',
              style: AppTokens.metadata,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
