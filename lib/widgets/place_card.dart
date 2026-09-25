import 'package:flutter/material.dart';

import '../models/place.dart';
import '../theme/app_tokens.dart';
import 'place_image.dart';

/// The place card that rises from the bottom of the map.
///
/// Three pieces of hierarchy, in strict order of visual weight: the name, the
/// rating, then everything else. Actions sit below as compact pills rather than
/// full-width buttons so they read as navigation, not submission.
class PlaceCard extends StatelessWidget {
  const PlaceCard({
    super.key,
    required this.place,
    required this.distanceLabel,
    this.onAction,
    this.onReviews,
    this.onClose,
  });

  final Place place;

  /// e.g. "450 m" — computed by the caller from the user's own position.
  final String distanceLabel;

  final ValueChanged<PlaceAction>? onAction;
  final VoidCallback? onReviews;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Hero image, full-bleed to the sheet's rounded top corners.
        Stack(
          children: [
            PlaceImage(
              place: place,
              height: 172,
              width: double.infinity,
              borderRadius: 0,
              iconScale: 0.26,
            ),
            if (onClose != null)
              Positioned(
                top: AppTokens.s12,
                right: AppTokens.s12,
                child: GestureDetector(
                  onTap: onClose,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.32),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: AppTokens.s16,
              bottom: AppTokens.s12,
              child: _CategoryTag(category: place.category),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.gutter,
            AppTokens.s16,
            AppTokens.gutter,
            AppTokens.s20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. Name — the primary focus of the card.
              Text(place.name, style: AppTokens.titleLg),
              const SizedBox(height: AppTokens.s8),

              // 2. Rating, then count as muted metadata.
              // The rating block flexes and the open-status chip is allowed to
              // shrink, so a long review count and a closing time on one row
              // cannot overflow a narrow phone.
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (place.isRated) ...[
                          _StarRow(rating: place.rating),
                          const SizedBox(width: 6),
                          Text(place.ratingLabel, style: AppTokens.titleSm),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '(${place.reviewCountLabel})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTokens.metadata,
                            ),
                          ),
                        ] else
                          Flexible(
                            child: Text(
                              place.reviewCountLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTokens.metadata,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppTokens.s8),
                  Flexible(
                    child: _OpenStatusChip(
                      status: place.openStatus,
                      closingTime: place.closingTime,
                    ),
                  ),
                ],
              ),

              // 3. Metadata.
              const SizedBox(height: AppTokens.s8),
              Row(
                children: [
                  const Icon(Icons.near_me_rounded,
                      size: 14, color: AppTokens.textMuted),
                  const SizedBox(width: 5),
                  Text(distanceLabel, style: AppTokens.caption),
                  if (place.address.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        '· ${place.address}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTokens.caption,
                      ),
                    ),
                  ],
                ],
              ),

              if (place.description.isNotEmpty) ...[
                const SizedBox(height: AppTokens.s12),
                Text(
                  place.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTokens.bodySecondary,
                ),
              ],

              // Photo gallery.
              const SizedBox(height: AppTokens.s16),
              PlaceImageStrip(place: place),

              // Actions.
              const SizedBox(height: AppTokens.s16),
              _ActionRow(
                onAction: onAction,
                onReviews: onReviews,
                reviewCount: place.reviewCount,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Actions offered on a place card.
enum PlaceAction { directions, tickets, details, reviews }

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    this.onAction,
    this.onReviews,
    required this.reviewCount,
  });

  final ValueChanged<PlaceAction>? onAction;
  final VoidCallback? onReviews;
  final int reviewCount;

  @override
  Widget build(BuildContext context) {
    // Directions is the primary action, so it gets the accent treatment; the
    // rest stay quiet pills.
    final items = <({IconData icon, String label, bool primary, PlaceAction? action})>[
      (icon: Icons.directions_rounded, label: 'Directions', primary: true, action: PlaceAction.directions),
      (icon: Icons.confirmation_number_rounded, label: 'Tickets', primary: false, action: PlaceAction.tickets),
      (icon: Icons.info_rounded, label: 'Details', primary: false, action: PlaceAction.details),
      (icon: Icons.star_rounded, label: 'Reviews', primary: false, action: PlaceAction.reviews),
    ];

    return Row(
      children: [
        for (final item in items) ...[
          if (item.primary)
            Expanded(
              // "Directions" is the longest label; a 3:2 ratio keeps all four
              // actions on one row at iPhone text sizes without truncating.
              flex: 3,
              child: _PrimaryAction(
                label: item.label,
                icon: item.icon,
                onTap: () => _fire(item.action),
              ),
            )
          else
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.only(left: AppTokens.s8),
                child: _PillAction(
                  label: item.label,
                  icon: item.icon,
                  onTap: () => _fire(item.action),
                ),
              ),
            ),
        ],
      ],
    );
  }

  void _fire(PlaceAction? action) {
    if (action == PlaceAction.reviews) {
      onReviews?.call();
    } else if (action != null) {
      onAction?.call(action);
    }
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({required this.label, required this.icon, this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTokens.accent,
      borderRadius: BorderRadius.circular(AppTokens.radiusButton),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusButton),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 21, color: Colors.white),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
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

class _PillAction extends StatelessWidget {
  const _PillAction({required this.label, required this.icon, this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTokens.surfaceMuted,
      borderRadius: BorderRadius.circular(AppTokens.radiusButton),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusButton),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: AppTokens.textSecondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTokens.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
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

class _CategoryTag extends StatelessWidget {
  const _CategoryTag({required this.category});
  final PlaceCategory category;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(AppTokens.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(category.icon, size: 13, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            category.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenStatusChip extends StatelessWidget {
  const _OpenStatusChip({required this.status, this.closingTime});
  final OpenStatus status;
  final String? closingTime;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      OpenStatus.open => const Color(0xFF16A34A),
      OpenStatus.closingSoon => const Color(0xFFD97706),
      OpenStatus.closed => AppTokens.textSecondary,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          status == OpenStatus.open ? 'Open now' : status.label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        if (closingTime != null) ...[
          const SizedBox(width: 4),
          Text('· Closes $closingTime', style: AppTokens.metadata),
        ],
      ],
    );
  }
}

/// Five stars with a partial fill for the fractional part of a rating.
class _StarRow extends StatelessWidget {
  const _StarRow({required this.rating, this.size = 14});
  final double rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Padding(
            padding: const EdgeInsets.only(right: 1),
            child: Icon(
              rating >= i
                  ? Icons.star_rounded
                  : rating >= i - 0.5
                      ? Icons.star_half_rounded
                      : Icons.star_outline_rounded,
              size: size,
              color: AppTokens.ratingStar,
            ),
          ),
      ],
    );
  }
}

/// Public star row, reused by transport and list rows.
class RatingStars extends StatelessWidget {
  const RatingStars({super.key, required this.rating, this.size = 14});
  final double rating;
  final double size;

  @override
  Widget build(BuildContext context) => _StarRow(rating: rating, size: size);
}
