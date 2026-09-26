import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'data/sample_data.dart';
import 'models/map_layer.dart';
import 'models/place.dart';
import 'models/search_result.dart';
import 'screens/auth_screen.dart';
import 'screens/owner_dashboard.dart';
import 'screens/simulator_screen.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/geocoding_service.dart';
import 'services/location_service.dart';
import 'services/places_repository.dart';
import 'services/reviews_repository.dart';
import 'services/simulation_repository.dart';
import 'services/stores_repository.dart';
import 'theme/app_tokens.dart';
import 'widgets/compass.dart';
import 'widgets/floating_search.dart';
import 'widgets/map_layers_sheet.dart';
import 'widgets/place_card.dart';
import 'widgets/place_marker.dart';
import 'widgets/place_review_sheet.dart';
import 'widgets/search_results_panel.dart';
import 'widgets/transport_sheet.dart';

/// The map screen.
///
/// The map is the application, not a widget inside one: every control is a
/// floating layer over the tile canvas, and the only opaque surface is the
/// bottom sheet, which the user drags.
///
/// Structure, top to bottom:
///   • floating search + category pills
///   • floating control stack (layers, locate, zoom)
///   • map with category markers and the user's own position
///   • a draggable sheet carrying either the discovery prompt, a place card,
///     or the transport planner
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

enum _SheetMode { discovery, place, picked, transport }

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final GeocodingService _geocoding = GeocodingService();
  final DeviceLocationService _location = const DeviceLocationService();
  late final ApiClient _api = ApiClient();
  late final PlacesRepository _placesRepo = PlacesRepository(_api);
  final AuthService _auth = AuthService();

  /// Signed-in person, or null when browsing anonymously.
  Account? _account;
  final TextEditingController _searchController = TextEditingController();
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  // ------------------------------------------------------------------ state

  PlaceCategory? _activeCategory;
  Place? _selectedPlace;
  DeviceLocation? _myLocation;
  bool _locating = false;
  bool _busyAll = false;
  String? _statusMessage;

  /// Dropped by tapping empty map, and the one selection mode that survives
  /// every other one. This is how a location is chosen by hand — and it is the
  /// same gesture a store owner would use to place a new listing.
  LatLng? _pickedPoint;

  /// What reverse geocoding says is at [_pickedPoint]. Null means "not looked up
  /// yet" or "nothing recognisable there", in which case the sheet falls back to
  /// bare coordinates rather than showing an empty name.
  SearchResult? _pickedPlaceDetail;
  bool _pickedDetailLoading = false;

  /// Current map rotation in degrees, kept in state so the compass can reflect
  /// it and stay hidden while the map is north-up.
  double _rotation = 0;

  /// Current sheet contents. Only one is ever visible.
  _SheetMode _sheetMode = _SheetMode.discovery;

  // Base layer / overlays, kept so the layers sheet stays meaningful.
  // Defaults to the key-less OSM standard style: CARTO and MapTiler endpoints
  // return a flat "API key required" placeholder tile without a key.
  String _baseLayerId = MapBaseLayer.defaultLayerId;
  final Set<MapOverlay> _overlays = {};

  // Route target, used by the transport sheet.
  LatLng? _routeDestination;
  String _routeDestinationLabel = '';

  /// Increments when the map moves, so marker work can be skipped until idle.
  bool _mapBusy = false;

  // ------------------------------------------------------- inline search state

  static const _searchDebounceDelay = Duration(milliseconds: 420);
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;
  int _searchRequestId = 0;

  /// True while the top bar is a live text field. The bar never moves; only its
  /// contents swap, so the keyboard cannot shift the map's chrome.
  bool _searchActive = false;
  List<SearchResult> _searchResults = const [];
  bool _searchLoading = false;
  String? _searchError;

  // Places loaded from Supabase. Null means "not loaded yet", which is
  // different from "loaded and there are none" (an empty list).
  List<Place>? _remotePlaces;

  /// Set when the backend could not be reached, so the UI can say so rather
  /// than silently showing sample data as if it were real.
  String? _dataSourceNote;

  /// True when showing every published place rather than the current viewport,
  /// so panning does not discard the wider list.
  bool _showingAll = false;

  /// Last time places were successfully loaded, shown in the source chip so a
  /// stale map is obvious during a demonstration.
  DateTime? _lastLoaded;

  String get _loadedLabel {
    final at = _lastLoaded;
    if (at == null) return '';
    final s = DateTime.now().difference(at).inSeconds;
    return s < 5 ? 'just now' : s < 60 ? '${s}s ago' : '${(s / 60).floor()}m ago';
  }

  bool get _searchPanelOpen =>
      _searchActive &&
      (_searchResults.isNotEmpty || _searchError != null || _searchLoading);

  /// The only heights the sheet may rest at. Every _expandSheet call must use
  /// one of these, or the sheet will animate and then snap away from itself.
  static const List<double> _sheetSnapSizes = [0.12, 0.4, 0.62, 0.92];

  // ----------------------------------------------------------------- helpers

  MapBaseLayer get _baseLayer => MapBaseLayer.byId(_baseLayerId);

  /// Remote places when the backend answered, sample data otherwise. The
  /// bundled data is a genuine fallback, not a stub: this device loses the
  /// network regularly, and an empty map is worse than labelled sample data.
  List<Place> get _allPlaces => _remotePlaces ?? SampleData.places;

  List<Place> get _visiblePlaces {
    final all = _allPlaces;
    if (_activeCategory == null) return all;
    return all.where((p) => p.category == _activeCategory).toList();
  }

  LatLng get _userPoint =>
      _myLocation?.point ?? const LatLng(12.9716, 77.5946);

  @override
  void initState() {
    super.initState();
    // A marker tap or category change should collapse the sheet back to its
    // minimum so the card never covers the thing it describes.
    _sheetController.addListener(_onSheetScroll);
    // Ask for a position once the first frame is up, so the map controller is
    // attached before it is moved. locateMe() manages _locating itself.
    WidgetsBinding.instance.addPostFrameCallback((_) => locateMe());
    // Pull places from the backend for the initial viewport. A failure leaves
    // _remotePlaces null, so the map keeps showing the bundled sample data.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPlaces());
    // Isolate a connection failure from a bad query before anything else.
    WidgetsBinding.instance.addPostFrameCallback((_) => _api.probe());
    // Restore a previous session so nobody is signed out between launches.
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreSession());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchFocus.dispose();
    _geocoding.dispose();
    _searchController.dispose();
    _api.close();
    _auth.close();
    _sheetController.dispose();
    super.dispose();
  }

  /// Sheet height alone is not a dismissal signal: dragging *up* to read a tall
  /// card passes through the same small sizes as dragging *down* to dismiss it.
  /// Inferring intent from height therefore wiped the selection the moment the
  /// user tried to expand it.
  ///
  /// Dismissal is now explicit instead — the close button on each card, or
  /// tapping empty map — and the sheet springs to a height that actually fits
  /// its content when a selection is made.
  void _onSheetScroll() {
    // Retained only so the controller has a listener; dismissal is explicit.
  }

  // ----------------------------------------------------------------- account

  /// Restore a previous login, so returning users are not asked to sign in
  /// again every launch.
  Future<void> _restoreSession() async {
    try {
      final account = await _auth.restore();
      if (account != null && mounted) setState(() => _account = account);
    } catch (_) {
      // A failed restore is not an error the user needs to see; browsing
      // anonymously still works.
    }
  }

  /// Opens sign-in, or the sign-out confirmation when already signed in.
  Future<void> _openAccount() async {
    final account = _account;
    if (account == null) {
      final signedIn = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => AuthScreen(auth: _auth)),
      );
      if (signedIn == true && mounted) {
        setState(() => _account = _auth.account);
        _toast('Signed in as ${_auth.account?.displayName ?? ''}');
      }
      return;
    }

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTokens.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTokens.radiusSheet)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTokens.grabber,
            ListTile(
              leading: const CircleAvatar(
                backgroundColor: AppTokens.accentSoft,
                child: Icon(Icons.person, color: AppTokens.accent),
              ),
              title: Text(account.displayName, style: AppTokens.titleSm),
              subtitle: Text(account.role.label, style: AppTokens.metadata),
            ),
            const Divider(height: 1),
            if (account.isOwner)
              ListTile(
                leading: const Icon(Icons.storefront_outlined),
                title: const Text('Your business'),
                subtitle: const Text('Register a store and list your places'),
                onTap: () => Navigator.of(sheetContext).pop('owner'),
              ),
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Trust simulator'),
              subtitle: const Text('Drive the scoring model by hand'),
              onTap: () => Navigator.of(sheetContext).pop('simulator'),
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: AppTokens.danger),
              title: const Text('Sign out', style: TextStyle(color: AppTokens.danger)),
              onTap: () => Navigator.of(sheetContext).pop('signout'),
            ),
            const SizedBox(height: AppTokens.s8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    if (action == 'simulator') {
      final repo = SimulationRepository(accessToken: _auth.accessToken);
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SimulatorScreen(
            repository: repo,
            places: _allPlaces,
            initialPlace: _selectedPlace,
          ),
        ),
      );
      repo.close();
      if (mounted) _loadPlaces();
    } else if (action == 'owner') {
      final token = _auth.accessToken;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => OwnerDashboard(
            account: account,
            repositories: (t) => StoresRepository(accessToken: t ?? token),
          ),
        ),
      );
      if (mounted) _loadPlaces(); // a newly published place should appear
    } else if (action == 'signout') {
      await _auth.signOut();
      if (mounted) {
        setState(() => _account = null);
        _toast('Signed out');
      }
    }
  }

  // -------------------------------------------------------------- places

  /// Fetches places inside the current viewport.
  ///
  /// Failures are deliberately quiet about the network and loud in the UI: the
  /// map keeps its markers, and a chip explains that they are sample data.
  /// Re-fetches places and the view the user is actually looking at.
  ///
  /// The data changes underneath the app -- a store is registered in the
  /// simulator, a review is posted -- and the map has no other way to notice.
  Future<void> _refreshPlaces() async {
    setState(() => _showingAll = false);
    await _loadPlaces();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
          _dataSourceNote == null
              ? 'Updated'
              : 'Could not refresh: ${_dataSourceNote!}',
        ),
        duration: const Duration(seconds: 2),
      ));
  }

  /// Fits the camera to every published place.
  ///
  /// Listings can be created anywhere, and the viewport query only reaches a
  /// few kilometres. Without this, a place made in another city is simply
  /// absent from the map and its reviews are unreachable.
  Future<void> _showAllPlaces() async {
    setState(() => _busyAll = true);
    try {
      final all = await _placesRepo.fetchAll();
      if (!mounted) return;
      if (all.isEmpty) {
        _toast('No published places');
        return;
      }
      setState(() {
        _remotePlaces = all;
        _showingAll = true;
        _dataSourceNote = null;
      });
      if (all.length == 1) {
        _mapController.move(all.first.point, 15);
      } else {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: all.map((p) => p.point).toList(),
            padding: const EdgeInsets.fromLTRB(56, 180, 56, 320),
            maxZoom: 15,
          ),
        );
      }
      _toast('Showing ${all.length} places');
    } on ApiException catch (e) {
      if (mounted) _toast(e.userMessage);
    } finally {
      if (mounted) setState(() => _busyAll = false);
    }
  }

  Future<void> _loadPlaces() async {
    final camera = _mapController.camera;
    try {
      // The phone's DNS is unreliable: a host that pings can still fail to
      // resolve a moment later, so a single attempt is not proof the backend is
      // down. Retry briefly before falling back to sample data.
      List<Place>? places;
      ApiException? last;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          places = await _placesRepo.fetchInBounds(camera.center, camera.zoom);
          break;
        } on ApiException catch (e) {
          last = e;
          if (e.kind != ApiErrorKind.network) {
            break;  // a rejection will not fix itself by asking again
          }
          if (attempt < 3) {
            debugPrint('[RevMap] load attempt $attempt failed (${e.kind}), retrying');
            await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
          }
        }
      }
      if (places == null) {
        throw last ?? ApiException(ApiErrorKind.unknown, 'Could not load places');
      }

      if (!mounted) return;
      _lastLoaded = DateTime.now();
      setState(() {
        _remotePlaces = places;
        _dataSourceNote = null;   // live data: nothing to explain
      });
      // Makes the data source unambiguous in logcat: without this there is no
      // way to tell a live load from a silent fallback.
      debugPrint('[RevMap] loaded ${places.length} place(s) from Supabase');
    } on ApiException catch (e) {
      if (!mounted) return;
      debugPrint('[RevMap] falling back to sample data: ${e.kind} ${e.message}');
      setState(() {
        _remotePlaces = null;
        _dataSourceNote = switch (e.kind) {
          ApiErrorKind.notConfigured => 'Backend not configured',
          ApiErrorKind.network => 'Offline \u2014 showing sample places',
          _ => e.userMessage,
        };
      });
    }
  }

  // -------------------------------------------------------------- my location

  Future<void> locateMe() async {
    if (_locating) return;
    setState(() => _locating = true);
    final messenger = ScaffoldMessenger.of(context);

    Future<void> fail(String message) async {
      if (!mounted) return;
      setState(() {
        _locating = false;
        _statusMessage = message;
      });
      messenger.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
    }

    if (!await _location.isServiceEnabled()) {
      await fail('Location is switched off on this device.');
      return;
    }
    if (!await _location.hasPermission()) {
      if (!await _location.requestPermission()) {
        await fail('RevMap needs location access to show where you are.');
        return;
      }
    }

    final result = await _location.getCurrentLocation();
    if (!mounted) return;
    if (result.isSuccess) {
      setState(() {
        _myLocation = result.location;
        _locating = false;
        _statusMessage = null;
      });
      _mapController.move(result.location!.point, 15);
    } else {
      await fail(switch (result.failure) {
        LocationFailure.timeout => 'Timed out getting a location fix.',
        LocationFailure.serviceDisabled => 'Location is switched off.',
        LocationFailure.permissionDenied => 'Location permission denied.',
        _ => result.message ?? 'Could not determine your location.',
      });
    }
  }

  // ------------------------------------------------------------------ markers

  void _selectPlace(Place place) {
    setState(() {
      _selectedPlace = place;
      _sheetMode = _SheetMode.place;
      _activeCategory = null;
      // One selection at a time: a place supersedes a hand-picked point.
      _pickedPoint = null;
      _pickedPlaceDetail = null;
      _pickedDetailLoading = false;
    });
    _mapController.move(place.point, 16);
    _expandSheet(fraction: 0.62);
  }

  void _onCategorySelected(PlaceCategory? category) {
    setState(() {
      _activeCategory = category;
      _selectedPlace = null;
      if (category == null) {
        _sheetMode = _SheetMode.discovery;
      }
    });
    if (category != null) {
      // Frame the whole filtered set so nothing is stranded off-screen.
      final points = _visiblePlaces.map((p) => p.point).toList();
      if (points.isNotEmpty) {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: points,
            padding: const EdgeInsets.fromLTRB(56, 180, 56, 320),
            maxZoom: 15,
          ),
        );
      }
      setState(() => _sheetMode = _SheetMode.discovery);
      _expandSheet();
    }
  }

  /// Springs the sheet open to [fraction] of the screen.
  ///
  /// [fraction] must be one of [sheetSnapSizes]. With `snap: true`, a value
  /// outside that list animates the sheet to a position it then immediately
  /// snaps away from, which reads as the sheet "floating" or bouncing.
  void _expandSheet({double fraction = 0.4}) {
    if (!_sheetController.isAttached) return;
    _sheetController.animateTo(
      fraction,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  // ------------------------------------------------------------------- search

  /// Activates the inline search field. The bar stays exactly where it is — no
  /// sheet, no repositioning — and results drop in beneath it over the map.
  void _activateSearch() {
    setState(() {
      _searchActive = true;
      _activeCategory = null;
    });
  }

  void _deactivateSearch() {
    _searchDebounce?.cancel();
    setState(() {
      _searchActive = false;
      _searchResults = const [];
      _searchError = null;
      _searchLoading = false;
    });
    _searchController.clear();
    _searchFocus.unfocus();
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchResults = const [];
      _searchError = null;
      _searchLoading = false;
    });
  }

  /// Debounced keystroke handler. The geocoding service applies its own
  /// rate limit; this just avoids firing a request per character.
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final term = value.trim();
    if (term.length < 2) {
      setState(() {
        _searchResults = const [];
        _searchError = null;
        _searchLoading = false;
      });
      return;
    }
    setState(() => _searchLoading = true);
    _searchDebounce =
        Timer(_searchDebounceDelay, () => _runSearch(term));
  }

  Future<void> _runSearch(String term) async {
    final id = ++_searchRequestId;
    try {
      final results = await _geocoding.search(term, near: _myLocation?.point);
      // A newer keystroke already started a search; drop this stale answer.
      if (!mounted || id != _searchRequestId) return;
      setState(() {
        _searchResults = results;
        _searchError =
            results.isEmpty ? 'No places matched "$term".' : null;
        _searchLoading = false;
      });
    } on GeocodingException catch (e) {
      if (!mounted || id != _searchRequestId) return;
      setState(() {
        _searchError = e.message;
        _searchResults = const [];
        _searchLoading = false;
      });
    }
  }

  /// A geocoding result was chosen: centre on it and plan a route.
  void _onSearchResult(SearchResult result) {
    _searchDebounce?.cancel();
    setState(() {
      _searchActive = false;
      _searchResults = const [];
      _searchController.clear();
      _searchFocus.unfocus();
      _activeCategory = null;
      _selectedPlace = null;
      _pickedPoint = null;
      _routeDestination = result.point;
      _routeDestinationLabel = result.title;
      _sheetMode = _SheetMode.transport;
    });
    _mapController.move(result.point, 15);
    // Transport is the densest sheet: a single snap must show a few routes.
    _expandSheet(fraction: 0.62);
  }

  void _quickSearch(String term) {
    _searchController
      ..text = term
      ..selection = TextSelection.collapsed(offset: term.length);
    setState(() => _searchActive = true);
    // Run immediately: the term is already complete, so no debounce needed.
    _searchDebounce?.cancel();
    _runSearch(term);
  }

  // ------------------------------------------------------------------ actions

  void _onPlaceAction(PlaceAction action) {
    final place = _selectedPlace;
    if (place == null) return;
    switch (action) {
      case PlaceAction.directions:
        setState(() {
          _routeDestination = place.point;
          _routeDestinationLabel = place.name;
          _sheetMode = _SheetMode.transport;
        });
        _mapController.move(place.point, 15);
        _expandSheet(fraction: 0.62);
      case PlaceAction.tickets:
        _toast('Tickets are not wired up yet.');
      case PlaceAction.details:
        _toast('Full details are not wired up yet.');
      case PlaceAction.reviews:
        _openReviews(place);
    }
  }

  /// Opens the place's reviews, aggregate and composer.
  ///
  /// A repository is built per open so it carries the token of whoever is
  /// signed in right now, rather than a token captured at startup.
  Future<void> _openReviews(Place place) async {
    final repository = ReviewsRepository(accessToken: _auth.accessToken);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTokens.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTokens.radiusSheet)),
      ),
      builder: (_) => DraggableScrollableSheet(
        // Reviews are a long list, so give them most of the screen.
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, controller) => PlaceReviewSheet(
          place: place,
          repository: repository,
          signedIn: _auth.isSignedIn,
          distanceLabel: place.distanceLabelFrom(_userPoint),
          scrollController: controller,
        ),
      ),
    );
    repository.close();
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------- layers

  Future<void> _openLayers() async {
    final selection = await showMapLayersSheet(
      context: context,
      currentBaseLayerId: _baseLayerId,
      currentOverlays: _overlays,
    );
    if (selection == null || !mounted) return;
    setState(() {
      _baseLayerId = selection.baseLayerId;
      _overlays
        ..clear()
        ..addAll(selection.enabledOverlays);
    });
  }

  // --------------------------------------------------------------------- zoom

  void _zoomBy(double delta) {
    final camera = _mapController.camera;
    _mapController.move(camera.center, (camera.zoom + delta).clamp(2, 19));
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // No app bar: the map owns the full screen.
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // ---- 1. the map, the dominant element -------------------------
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: const LatLng(12.9716, 77.5946),
                initialZoom: 13,
                minZoom: 2,
                maxZoom: 19,
                backgroundColor: AppTokens.mapLand,
                onMapEvent: (event) {
                  if (event is MapEventMoveStart && !_mapBusy) {
                    setState(() => _mapBusy = true);
                  } else if (event is MapEventMoveEnd && _mapBusy) {
                    setState(() => _mapBusy = false);
                    _loadPlaces();
                  }
                  // Track rotation so the compass can show heading, and only
                  // appear once the map is actually off north.
                  if (event is MapEventRotate) {
                    final next = _mapController.camera.rotation;
                    if ((next - _rotation).abs() > 0.5) {
                      setState(() => _rotation = next);
                    }
                  }
                },
                onTap: (_, point) {
                  // Tapping the map drops a pin there. This supersedes a place
                  // selection but deliberately survives category filtering and
                  // a dismissed card, so a hand-picked point is never lost by
                  // an unrelated interaction.
                  setState(() {
                    _pickedPoint = point;
                    _selectedPlace = null;
                    _sheetMode = _SheetMode.picked;
                    _pickedPlaceDetail = null;
                  });
                  debugPrint('[RevMap] picked ${point.latitude},'
                      '${point.longitude}');
                  _describePickedPoint(point);
                  // Open straight away: the picked card is taller than the
                  // collapsed peek, so leaving it shut would hide the very
                  // details the user just asked for.
                  _expandSheet(fraction: 0.62);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: _baseLayer.urlTemplate,
                  subdomains: _baseLayer.subdomains,
                  userAgentPackageName: 'com.revmap.revamp',
                  maxNativeZoom: _baseLayer.maxZoom.round(),
                ),
                // Accuracy halo sits beneath the markers.
                if (_myLocation?.accuracy != null)
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: _myLocation!.point,
                        radius: _myLocation!.accuracy!,
                        useRadiusInMeter: true,
                        color: AppTokens.accent.withValues(alpha: 0.10),
                        borderColor: AppTokens.accent.withValues(alpha: 0.30),
                        borderStrokeWidth: 1,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    for (final place in _visiblePlaces)
                      Marker(
                        key: ValueKey(place.id),
                        point: place.point,
                        width: 54,
                        height: 54,
                        alignment: Alignment.center,
                        child: PlaceMarker(
                          category: place.category,
                          isSelected: _selectedPlace?.id == place.id,
                          onTap: () => _selectPlace(place),
                        ),
                      ),
                    if (_myLocation != null)
                      Marker(
                        point: _myLocation!.point,
                        width: 28,
                        height: 28,
                        child: const MyLocationDot(),
                      ),
                    // The hand-picked point reads as a crosshair, so it never
                    // gets confused with a place pin or the route pin.
                    if (_pickedPoint != null)
                      Marker(
                        key: const ValueKey('picked-point'),
                        point: _pickedPoint!,
                        width: 48,
                        height: 48,
                        child: GestureDetector(
                          onTap: () {
                            setState(() => _sheetMode = _SheetMode.picked);
                            _expandSheet();
                          },
                          child: PickedPointPin(
                            selected: _sheetMode == _SheetMode.picked,
                          ),
                        ),
                      ),
                    if (_routeDestination != null)
                      Marker(
                        point: _routeDestination!,
                        width: 44,
                        height: 44,
                        child: const DestinationPin(),
                      ),
                  ],
                ),
                // Attribution is legally required, but the full string is far
                // too wide for a phone. Collapse it to the bare source name and
                // wrap the whole widget so a tap reveals the full text.
                GestureDetector(
                  onTap: () => _toast(_baseLayer.attribution),
                  child: SimpleAttributionWidget(
                    source: Text(
                      _shortAttribution(_baseLayer.attribution),
                      style: const TextStyle(fontSize: 10),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ---- 2. floating search + results + category pills -----------
          Positioned(
            top: MediaQuery.paddingOf(context).top + AppTokens.s8,
            left: AppTokens.gutter,
            right: AppTokens.gutter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FloatingSearchBar(
                  isActive: _searchActive,
                  controller: _searchController,
                  focusNode: _searchFocus,
                  onTap: _activateSearch,
                  onChanged: _onSearchChanged,
                  onClear: _clearSearch,
                  onSubmitted: (_) {
                    if (_searchResults.isNotEmpty) {
                      _onSearchResult(_searchResults.first);
                    }
                  },
                  trailing: _searchActive
                      ? MapControlButton(
                          icon: Icons.close_rounded,
                          tooltip: 'Cancel search',
                          onPressed: _deactivateSearch,
                        )
                      : null,
                ),
                // Results land directly under the bar, over the map, so the
                // search control itself never moves.
                if (_searchPanelOpen) ...[
                  const SizedBox(height: AppTokens.s8),
                  // Driven by this screen's own query state. Routing this
                  // through SearchPanel left the panel searching nothing,
                  // because the field it listens to is not rendered here.
                  SearchResultsPanel(
                    results: _searchResults,
                    error: _searchError,
                    loading: _searchLoading,
                    onResultSelected: _onSearchResult,
                  ),
                ] else
                  const SizedBox(height: AppTokens.s12),
                CategoryPills(
                  categories: SampleData.categories,
                  selected: _activeCategory,
                  onSelected: _onCategorySelected,
                ),
              ],
            ),
          ),

          // ---- 3. data-source honesty chip ----------------------------
          if (_dataSourceNote != null || _lastLoaded != null)
            Positioned(
              left: AppTokens.gutter,
              bottom: _sheetPeek() + AppTokens.s12,
              child: _SourceChip(
                note: _dataSourceNote ?? 'Updated $_loadedLabel'
                    '${_showingAll ? ' — showing all places' : ''}',
                onRetry: _loadPlaces,
              ),
            ),

          // ---- 3. floating map controls --------------------------------
          Positioned(
            right: AppTokens.gutter,
            // Sit just above the collapsed sheet.
            bottom: _sheetPeek() + AppTokens.s12,
            child: MapControlStack(
              children: [
                MapControlButton(
                  icon: _account == null
                      ? Icons.account_circle_outlined
                      : Icons.account_circle_rounded,
                  tooltip: _account == null ? 'Sign in' : _account!.displayName,
                  isActive: _account != null,
                  onPressed: _openAccount,
                ),
                MapControlButton(
                  icon: _busyAll
                      ? Icons.hourglass_empty_rounded
                      : Icons.travel_explore_rounded,
                  tooltip: 'Show all places',
                  isActive: _showingAll,
                  onPressed: _busyAll ? () {} : _showAllPlaces,
                ),
                MapControlButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Refresh places',
                  onPressed: _refreshPlaces,
                ),
                MapControlButton(
                  icon: Icons.layers_rounded,
                  tooltip: 'Map layers',
                  onPressed: _openLayers,
                ),
                // Only worth the space once the map is off north.
                if (_rotation.abs() > 0.5)
                  CompassButton(
                    rotationDegrees: _rotation,
                    onTap: _resetNorth,
                  ),
                MapControlButton(
                  icon: _locating
                      ? Icons.location_searching_rounded
                      : Icons.my_location_rounded,
                  tooltip: 'My location',
                  isActive: _myLocation != null,
                  onPressed: _locating ? () {} : locateMe,
                ),
                MapControlButton(
                  icon: Icons.add_rounded,
                  tooltip: 'Zoom in',
                  onPressed: () => _zoomBy(1),
                ),
                MapControlButton(
                  icon: Icons.remove_rounded,
                  tooltip: 'Zoom out',
                  onPressed: () => _zoomBy(-1),
                ),
              ],
            ),
          ),

          // ---- 4. the draggable bottom sheet ---------------------------
          _buildSheet(),
        ],
      ),
    );
  }

  /// Shrinks a long attribution string to its source name, e.g.
  /// "© OpenStreetMap contributors, © CARTO" -> "OSM / CARTO".
  ///
  /// The full string stays available on tap; this only exists so the required
  /// attribution fits a narrow screen instead of overflowing it.
  static String _shortAttribution(String attribution) {
    final cleaned = attribution
        .replaceAll('©', '')
        .replaceAll('OpenStreetMap contributors', 'OSM')
        .trim();
    if (cleaned.length <= 22) return cleaned;
    return '${cleaned.substring(0, 21)}…';
  }

  /// How much of the screen the collapsed sheet occupies, so the floating
  /// controls can sit just above it.
  double _sheetPeek() {
    final size = _sheetController.isAttached ? _sheetController.size : 0.12;
    return MediaQuery.sizeOf(context).height * size.clamp(0.0, 1.0);
  }

  Widget _buildSheet() {
    return DraggableScrollableSheet(
      controller: _sheetController,
      // Collapsed: a peek. Expanded: nearly the full screen.
      minChildSize: 0.12,
      initialChildSize: 0.12,
      maxChildSize: 0.92,
      snap: true,
      snapSizes: _sheetSnapSizes,
      builder: (context, scrollController) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: AppTokens.background,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppTokens.radiusSheet),
            ),
            boxShadow: AppTokens.floatShadow,
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppTokens.radiusSheet),
            ),
            child: ListView(
              controller: scrollController,
              padding: EdgeInsets.zero,
              children: [
                Center(child: AppTokens.grabber),
                switch (_sheetMode) {
                  _SheetMode.discovery => _DiscoverySheet(
                      onCategory: _onCategorySelected,
                      onSearch: _activateSearch,
                      onQuickSearch: _quickSearch,
                      status: _statusMessage,
                    ),
                  _SheetMode.place => _buildPlaceSheet(),
                  _SheetMode.picked => _buildPickedSheet(),
                  _SheetMode.transport => _buildTransportSheet(),
                },
                SizedBox(height: MediaQuery.paddingOf(context).bottom),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaceSheet() {
    final place = _selectedPlace;
    if (place == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PlaceCard(
          place: place,
          distanceLabel: place.distanceLabelFrom(_userPoint),
          onAction: _onPlaceAction,
          onClose: () => setState(() {
            _selectedPlace = null;
            _sheetMode = _SheetMode.discovery;
          }),
        ),
      ],
    );
  }

  /// Asks the geocoder what is at [point] so the picked sheet can show a real
  /// name and address rather than bare coordinates.
  ///
  /// A failure is deliberately silent: coordinates alone are still useful, so a
  /// dead network must not leave the sheet empty or block the pick.
  Future<void> _describePickedPoint(LatLng point) async {
    setState(() => _pickedDetailLoading = true);
    try {
      final detail = await _geocoding.reverse(
        latitude: point.latitude,
        longitude: point.longitude,
      );
      // A newer tap may have superseded this one.
      if (!mounted || _pickedPoint != point) return;
      setState(() {
        _pickedPlaceDetail = detail;
        _pickedDetailLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _pickedDetailLoading = false);
    }
  }

  /// Snaps the map back to north.
  void _resetNorth() {
    _mapController.rotate(0);
    setState(() => _rotation = 0);
  }

  Widget _buildPickedSheet() {
    final point = _pickedPoint;
    if (point == null) return const SizedBox.shrink();
    return _PickedPointSheet(
      point: point,
      detail: _pickedPlaceDetail,
      detailLoading: _pickedDetailLoading,
      distanceLabel: _myLocation == null
          ? null
          : 'You are ${_formatDistance(_haversineKm(_myLocation!.point, point))} away',
      onRoute: () => setState(() {
        _routeDestination = point;
        _routeDestinationLabel = 'Pinned location';
        _sheetMode = _SheetMode.transport;
      }),
      onCopy: () {
        Clipboard.setData(ClipboardData(
          text: '${point.latitude}, ${point.longitude}',
        ));
        _toast('Coordinates copied');
      },
      onClear: () => setState(() {
        _pickedPoint = null;
        _pickedPlaceDetail = null;
        _pickedDetailLoading = false;
        _sheetMode = _SheetMode.discovery;
      }),
    );
  }

  /// Great-circle distance in kilometres. Straight-line, not a route length.
  static double _haversineKm(LatLng a, LatLng b) {
    const earthKm = 6371.0;
    double rad(double d) => math.pi / 180.0 * d;
    final dLat = rad(b.latitude - a.latitude);
    final dLon = rad(b.longitude - a.longitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(a.latitude)) *
            math.cos(rad(b.latitude)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return earthKm * 2 * math.asin(math.min(1.0, math.sqrt(h)));
  }

  static String _formatDistance(double km) {
    final m = km * 1000;
    if (m < 950) return '${m.round()} m';
    return '${km.toStringAsFixed(1)} km';
  }

  Widget _buildTransportSheet() {
    final dest = _routeDestinationLabel.isEmpty
        ? 'Selected place'
        : _routeDestinationLabel;
    return TransportSheet(
      origin: 'Your location',
      destination: dest,
      routes: TransportSheet.sampleRoutes(),
    );
  }
}

/// Explains that the markers on screen are not live data, and offers a retry.
///
/// Shown whenever the backend could not be reached. Without it, sample places
/// would look exactly like real ones, which is the opposite of trustworthy.
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.note, this.onRetry});

  final String note;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      constraints: const BoxConstraints(maxWidth: 300),
      decoration: BoxDecoration(
        color: AppTokens.background,
        borderRadius: BorderRadius.circular(AppTokens.radiusPill),
        boxShadow: AppTokens.controlShadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded,
              size: 16, color: AppTokens.textMuted),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTokens.metadata.copyWith(
                color: AppTokens.textSecondary,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Retry', style: TextStyle(fontSize: 12.5)),
            ),
        ],
      ),
    );
  }
}

/// Sheet content for a point the user tapped on the map.
///
/// Reverse geocoding names the point, so the card leads with a real place or
/// address rather than raw coordinates — a bare "12.97, 77.59" is not a
/// description of anywhere. Coordinates stay visible underneath, because this
/// is also the gesture a store owner uses to place a listing and will need them.
class _PickedPointSheet extends StatelessWidget {
  const _PickedPointSheet({
    required this.point,
    this.detail,
    this.detailLoading = false,
    this.distanceLabel,
    this.onRoute,
    this.onCopy,
    this.onClear,
  });

  final LatLng point;

  /// What the geocoder says is here, once resolved.
  final SearchResult? detail;
  final bool detailLoading;
  final String? distanceLabel;
  final VoidCallback? onRoute;
  final VoidCallback? onCopy;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.gutter,
        AppTokens.s8,
        AppTokens.gutter,
        AppTokens.s16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppTokens.accentSoft,
                  borderRadius: BorderRadius.circular(AppTokens.radiusButton),
                ),
                child: const Icon(Icons.add_location_alt_rounded,
                    size: 21, color: AppTokens.accent),
              ),
              const SizedBox(width: AppTokens.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Named place first: that is what the user recognises.
                    if (detailLoading)
                      Row(
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          ),
                          const SizedBox(width: AppTokens.s8),
                          Flexible(
                            child: Text(
                              'Looking up this location…',
                              style: AppTokens.caption,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      )
                    else if (detail != null)
                      Text(
                        detail!.title,
                        style: AppTokens.titleSm,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    else
                      Text('Picked location', style: AppTokens.titleSm),
                    const SizedBox(height: 2),
                    Text(
                      detail?.subtitle.isNotEmpty == true
                          ? detail!.subtitle
                          : '${point.latitude.toStringAsFixed(5)}, '
                              '${point.longitude.toStringAsFixed(5)}',
                      style: AppTokens.metadata,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // Coordinates are kept even when named: this is how a store
                    // owner would confirm exactly where a listing will sit.
                    if (detail != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${point.latitude.toStringAsFixed(5)}, '
                        '${point.longitude.toStringAsFixed(5)}',
                        style: AppTokens.metadata.copyWith(
                          color: AppTokens.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onClear != null)
                IconButton(
                  tooltip: 'Clear pin',
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded,
                      size: 20, color: AppTokens.textMuted),
                ),
            ],
          ),
          if (distanceLabel != null) ...[
            const SizedBox(height: AppTokens.s12),
            Row(
              children: [
                const Icon(Icons.near_me_rounded,
                    size: 15, color: AppTokens.textMuted),
                const SizedBox(width: 6),
                Text(distanceLabel!, style: AppTokens.caption),
              ],
            ),
          ],
          const SizedBox(height: AppTokens.s16),
          Row(
            children: [
              Expanded(
                child: _PickedAction(
                  label: 'Directions',
                  icon: Icons.directions_rounded,
                  primary: true,
                  onTap: onRoute,
                ),
              ),
              const SizedBox(width: AppTokens.s8),
              Expanded(
                child: _PickedAction(
                  label: 'Copy',
                  icon: Icons.copy_rounded,
                  onTap: onCopy,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PickedAction extends StatelessWidget {
  const _PickedAction({
    required this.label,
    required this.icon,
    this.onTap,
    this.primary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: primary ? AppTokens.accent : AppTokens.surfaceMuted,
      borderRadius: BorderRadius.circular(AppTokens.radiusButton),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusButton),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 17),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 22,
                  color: primary ? Colors.white : AppTokens.textSecondary),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: primary ? Colors.white : AppTokens.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The default bottom-sheet content: the exploratory prompt.
class _DiscoverySheet extends StatelessWidget {
  const _DiscoverySheet({
    required this.onCategory,
    required this.onSearch,
    required this.onQuickSearch,
    this.status,
  });

  final ValueChanged<PlaceCategory?> onCategory;
  final VoidCallback onSearch;
  final ValueChanged<String> onQuickSearch;
  final String? status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.gutter,
        AppTokens.s8,
        AppTokens.gutter,
        AppTokens.s16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Explore nearby', style: AppTokens.titleMd),
          const SizedBox(height: 4),
          Text(
            status ?? 'Search, or pick a category to see it on the map.',
            style: AppTokens.caption,
          ),
          const SizedBox(height: AppTokens.s16),
          // Horizontal row of small image cards, each a discovery entry point.
          // A horizontally-scrolling view still needs a bounded height, so the
          // tile is given one — but its own content is what decides the inner
          // layout, so a longer label or a larger text scale wraps rather than
          // overflowing.
          SizedBox(
            height: 148,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              children: [
                for (final c in SampleData.categories)
                  Padding(
                    padding: const EdgeInsets.only(right: AppTokens.s12),
                    child: _CategoryTile(
                      category: c,
                      count: SampleData.filter(c).length,
                      onTap: () => onCategory(c),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.s20),
          Text('Popular searches', style: AppTokens.titleSm),
          const SizedBox(height: AppTokens.s12),
          Wrap(
            spacing: AppTokens.s8,
            runSpacing: AppTokens.s8,
            children: [
              for (final term in const ['Coffee', 'Parks', 'Museums', 'Shopping'])
                _SuggestionChip(label: term, onTap: () => onQuickSearch(term)),
            ],
          ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.count,
    required this.onTap,
  });

  final PlaceCategory category;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 92,
        // Height is decided by the content rather than fixed, so a longer
        // category name or a larger text scale cannot overflow the card.
        padding: const EdgeInsets.all(AppTokens.s12),
        decoration: BoxDecoration(
          color: AppTokens.surfaceMuted,
          borderRadius: BorderRadius.circular(AppTokens.radiusCard),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(category.icon, size: 22, color: category.tint),
            const SizedBox(height: AppTokens.s12),
            Text(
              category.label,
              style: AppTokens.titleSm.copyWith(fontSize: 13.5),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text('$count nearby', style: AppTokens.metadata),
          ],
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTokens.surfaceMuted,
      borderRadius: BorderRadius.circular(AppTokens.radiusPill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusPill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Text(
            label,
            style: AppTokens.caption.copyWith(
              fontWeight: FontWeight.w600,
              color: AppTokens.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
