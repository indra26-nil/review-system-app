import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/search_result.dart';
import '../services/geocoding_service.dart';


/// The search box and its result list, drawn over the map.
///
/// Owns its own debounce so a fast typist does not fire one request per
/// keystroke. [onResultSelected] fires when the user picks a place.
class SearchPanel extends StatefulWidget {
  const SearchPanel({
    super.key,
    required this.geocoding,
    required this.onResultSelected,
    this.onDismissed,
    this.initialQuery = '',
    this.near,
    this.controller,
    this.showField = true,
  });

  final GeocodingService geocoding;
  final ValueChanged<SearchResult> onResultSelected;
  final VoidCallback? onDismissed;
  final String initialQuery;

  /// Biases results towards this point, when the device position is known.
  final LatLng? near;

  /// When false the panel renders only the result list, leaving the visible
  /// search field to [FloatingSearchBar] so the two never overlap.
  final bool showField;

  /// Optional externally-owned controller. When supplied, the panel drives it
  /// instead of creating its own, so a quick-search shortcut can pre-fill the
  /// query. The panel will not dispose a controller it did not create.
  final TextEditingController? controller;

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel> {
  static const _debounce = Duration(milliseconds: 450);

  /// True when the controller belongs to the caller and must not be disposed.
  late final bool _ownsController = widget.controller == null;

  late final TextEditingController _controller = widget.controller ??
      TextEditingController(text: widget.initialQuery);
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Repaint the clear affordance when the query changes externally.
    _controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Timer? _debounceTimer;

  /// Guards against an older, slower response overwriting a newer one.
  int _requestId = 0;

  List<SearchResult> _results = const [];
  bool _loading = false;
  String? _error;

  bool get _isOpen => _results.isNotEmpty || _error != null || _loading;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    // Only dispose a controller this widget created.
    if (_ownsController) _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounceTimer?.cancel();
    final term = value.trim();

    if (term.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
        _loading = false;
      });
      return;
    }

    // Anything shorter than two characters would only return noise, and
    // Nominatim treats it as a match-everything query.
    if (term.length < 2) return;

    setState(() => _loading = true);
    _debounceTimer = Timer(_debounce, () => _runSearch(term));
  }

  Future<void> _runSearch(String term) async {
    final id = ++_requestId;
    try {
      final results = await widget.geocoding.search(term, near: widget.near);
      // A newer query has already been issued; drop this stale answer.
      if (!mounted || id != _requestId) return;
      debugPrint('[RevMap] search "$term" -> ${results.length} result(s)');
      setState(() {
        _results = results;
        _error = results.isEmpty ? 'No places matched "$term".' : null;
        _loading = false;
      });
    } on GeocodingException catch (e) {
      if (!mounted || id != _requestId) return;
      debugPrint('[RevMap] search "$term" failed: ${e.message}');
      setState(() {
        _error = e.message;
        _results = const [];
        _loading = false;
      });
    }
  }

  void _clear() {
    _debounceTimer?.cancel();
    _requestId++;
    _controller.clear();
    setState(() {
      _results = const [];
      _error = null;
      _loading = false;
    });
    _focusNode.requestFocus();
  }

  void _select(SearchResult result) {
    _debounceTimer?.cancel();
    _focusNode.unfocus();
    widget.onResultSelected(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The field is optional: when the map owns the visible search bar, this
        // panel renders results only, so results appear directly beneath the
        // bar rather than in a separate sheet.
        if (widget.showField)
          Material(
          elevation: 6,
          shadowColor: Colors.black.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(16),
          color: theme.colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.search, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    textInputAction: TextInputAction.search,
                    onChanged: _onQueryChanged,
                    decoration: InputDecoration(
                      hintText: 'Search places, addresses…',
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      suffixIcon: _controller.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: 'Clear',
                              onPressed: _clear,
                            ),
                    ),
                  ),
                ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_isOpen) _buildResults(theme),
      ],
    );
  }

  Widget _buildResults(ThemeData theme) {
    return Material(
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(16),
      color: theme.colorScheme.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: theme.colorScheme.outline),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _results.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final result = _results[index];
                    return ListTile(
                      key: ValueKey(result.id),
                      dense: true,
                      leading: Icon(_iconFor(result.category)),
                      title: Text(
                        result.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      subtitle: result.subtitle.isEmpty
                          ? null
                          : Text(
                              result.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                      onTap: () => _select(result),
                    );
                  },
                ),
              ),
            // Nominatim's terms require visible attribution.
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Search data © OpenStreetMap contributors',
                style: theme.textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Picks a recognisable icon from the coarse feature type Nominatim returns.
  static IconData _iconFor(String? category) => switch (category) {
        'city' || 'town' || 'village' || 'hamlet' => Icons.location_city,
        'state' || 'region' || 'county' => Icons.map_outlined,
        'country' => Icons.public,
        'road' || 'pedestrian' || 'path' => Icons.alt_route,
        'amenity' || 'shop' || 'tourism' || 'leisure' => Icons.place_outlined,
        'building' || 'house' => Icons.home_outlined,
        'waterway' || 'natural' => Icons.water_outlined,
        _ => Icons.place_outlined,
      };
}
