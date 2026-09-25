import 'package:flutter/material.dart';

import '../models/search_result.dart';
import '../theme/app_tokens.dart';

/// The result list for a place search, shown as a floating panel under the
/// search bar.
///
/// Deliberately separate from [SearchPanel]: on the map the field and the
/// results live in *different* widgets, so the caller owns the query and this
/// widget only renders what it is given. Driving both from one stateful widget
/// is what previously made search look broken — the panel's results never
/// received the query typed into the map's own field.
class SearchResultsPanel extends StatelessWidget {
  const SearchResultsPanel({
    super.key,
    required this.results,
    required this.onResultSelected,
    this.error,
    this.loading = false,
    this.maxHeight = 320,
  });

  final List<SearchResult> results;
  final ValueChanged<SearchResult> onResultSelected;
  final String? error;
  final bool loading;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTokens.background,
        borderRadius: BorderRadius.circular(AppTokens.radiusButton),
        boxShadow: AppTokens.floatShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(AppTokens.s16),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 19, color: AppTokens.textMuted),
                    const SizedBox(width: AppTokens.s12),
                    Expanded(
                      child: Text(error!, style: AppTokens.bodySecondary),
                    ),
                  ],
                ),
              )
            else if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppTokens.s20),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: results.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final result = results[index];
                    return ListTile(
                      key: ValueKey(result.id),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppTokens.s16,
                        vertical: 2,
                      ),
                      leading: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: AppTokens.surfaceMuted,
                          borderRadius:
                              BorderRadius.circular(AppTokens.radiusButton - 4),
                        ),
                        child: Icon(
                          iconFor(result.category),
                          size: 19,
                          color: AppTokens.textSecondary,
                        ),
                      ),
                      title: Text(
                        result.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTokens.titleSm,
                      ),
                      subtitle: result.subtitle.isEmpty
                          ? null
                          : Text(
                              result.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTokens.caption,
                            ),
                      onTap: () => onResultSelected(result),
                    );
                  },
                ),
              ),
            // The geocoder's terms require visible attribution.
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.gutter,
                vertical: 8,
              ),
              child: Text(
                'Search data © OpenStreetMap contributors',
                style: AppTokens.metadata,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A recognisable icon from the coarse feature type the geocoder returns.
  static IconData iconFor(String? category) => switch (category) {
        'city' || 'town' || 'village' || 'hamlet' => Icons.location_city_rounded,
        'state' || 'region' || 'county' => Icons.map_outlined,
        'country' => Icons.public_rounded,
        'road' || 'pedestrian' || 'path' => Icons.alt_route_rounded,
        'amenity' || 'shop' || 'tourism' || 'leisure' => Icons.place_outlined,
        'building' || 'house' => Icons.home_outlined,
        'waterway' || 'natural' => Icons.water_outlined,
        _ => Icons.place_outlined,
      };
}
