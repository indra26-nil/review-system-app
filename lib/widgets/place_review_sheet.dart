import 'package:flutter/material.dart';

import '../models/place.dart';
import '../services/reviews_repository.dart';
import '../theme/app_tokens.dart';
import 'review_widgets.dart';

/// The place detail sheet: the server's aggregate, the reviews, and the composer.
///
/// The headline number is the *adjusted, evidence-weighted* rating, not a plain
/// average, and the review count is the effective count rather than the raw
/// number of posts. A place with 100 reviews worth 42.7 in aggregate says
/// "≈43 full-weight reviews", because that is the honest claim.
class PlaceReviewSheet extends StatefulWidget {
  const PlaceReviewSheet({
    super.key,
    required this.place,
    required this.repository,
    required this.signedIn,
    this.distanceLabel,
    this.scrollController,
  });

  final Place place;
  final ReviewsRepository repository;
  final bool signedIn;
  final String? distanceLabel;

  /// Supplied by [DraggableScrollableSheet]. Without it the list scrolls but the
  /// sheet never grows, so a long review list is unreachable.
  final ScrollController? scrollController;

  @override
  State<PlaceReviewSheet> createState() => _PlaceReviewSheetState();
}

class _PlaceReviewSheetState extends State<PlaceReviewSheet> {
  PlaceRating? _rating;
  List<Review> _reviews = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.repository.ratingFor(widget.place.id),
        widget.repository.reviewsFor(widget.place.id),
      ]);
      if (!mounted) return;
      setState(() {
        _rating = results[0] as PlaceRating;
        _reviews = results[1] as List<Review>;
        _loading = false;
      });
    } on ReviewsException catch (e) {
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

  Future<void> _submit(int stars, String text) async {
    try {
      await widget.repository.submit(
        placeId: widget.place.id,
        rating: stars,
        text: text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Review posted')));
      await _load();
    } on ReviewsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(
        AppTokens.gutter, AppTokens.s8, AppTokens.gutter, AppTokens.s32),
      children: [
        _Header(place: widget.place, rating: _rating, distance: widget.distanceLabel),
        const SizedBox(height: AppTokens.s20),

        ReviewComposer(
          onSubmit: _submit,
          signedIn: widget.signedIn,
        ),
        const SizedBox(height: AppTokens.s24),

        Text('Reviews', style: AppTokens.titleMd),
        const SizedBox(height: AppTokens.s12),

        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppTokens.s24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          _Note(_error!, icon: Icons.cloud_off_rounded)
        else if (_reviews.isEmpty)
          const _Note('No reviews yet. Be the first to write one.',
              icon: Icons.rate_review_outlined)
        else
          for (final review in _reviews) ...[
            ReviewTile(review: review),
            const SizedBox(height: AppTokens.s8),
          ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.place, required this.rating, this.distance});

  final Place place;
  final PlaceRating? rating;
  final String? distance;

  @override
  Widget build(BuildContext context) {
    final r = rating;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(place.name, style: AppTokens.titleLg),
        const SizedBox(height: 4),
        Text(place.category.label, style: AppTokens.caption),
        const SizedBox(height: AppTokens.s12),

        if (r != null && r.rawReviews > 0) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(r.adjustedRating.toStringAsFixed(1),
                  style: AppTokens.titleLg),
              const SizedBox(width: AppTokens.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.rawReviews == 1
                          ? '1 review'
                          : '${r.rawReviews} reviews',
                      style: AppTokens.caption,
                    ),
                    // The effective count is a float: 100 posts can total 42.7.
                    Text(
                      '≈${r.effectiveReviews.toStringAsFixed(1)} '
                      'full-weight',
                      style: AppTokens.metadata,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.s8),
          _ConfidenceBar(value: r.confidence),
        ] else
          Text('No reviews yet', style: AppTokens.caption),

        if (distance != null) ...[
          const SizedBox(height: AppTokens.s8),
          Row(
            children: [
              const Icon(Icons.near_me_rounded, size: 14, color: AppTokens.textMuted),
              const SizedBox(width: 5),
              Text(distance!, style: AppTokens.caption),
            ],
          ),
        ],
      ],
    );
  }
}

/// Confidence, shown as a labelled bar rather than a number.
///
/// The number means "how much independent evidence backs this aggregate", not
/// "how good the place is", and a bare 0.72 would invite exactly that
/// misreading.
class _ConfidenceBar extends StatelessWidget {
  const _ConfidenceBar({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final label = value >= 0.65
        ? 'Strong evidence'
        : value >= 0.35
            ? 'Moderate evidence'
            : 'Limited evidence';
    final color = value >= 0.65
        ? AppTokens.success
        : value >= 0.35
            ? AppTokens.warning
            : AppTokens.textMuted;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: value.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: AppTokens.surfaceMuted,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        const SizedBox(height: 5),
        Text('$label backing this rating', style: AppTokens.metadata),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTokens.s20),
      decoration: BoxDecoration(
        color: AppTokens.surfaceMuted,
        borderRadius: BorderRadius.circular(AppTokens.radiusCard),
      ),
      child: Column(
        children: [
          Icon(icon, size: 24, color: AppTokens.textMuted),
          const SizedBox(height: AppTokens.s8),
          Text(text, style: AppTokens.caption, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
