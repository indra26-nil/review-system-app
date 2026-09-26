import 'package:flutter/material.dart';

import '../services/reviews_repository.dart';
import '../theme/app_tokens.dart';

/// Star rating input, plus an optional note.
///
/// Deliberately does *not* offer a place to set a weight or claim a verified
/// visit. The client sends a rating and some words; the database decides what
/// that is worth.
class ReviewComposer extends StatefulWidget {
  const ReviewComposer({
    super.key,
    required this.onSubmit,
    this.signedIn = true,
  });

  /// Called with the chosen rating and text.
  final Future<void> Function(int rating, String text) onSubmit;

  /// When false, the composer explains that signing in is required instead of
  /// offering an input that could not be saved.
  final bool signedIn;

  @override
  State<ReviewComposer> createState() => _ReviewComposerState();
}

class _ReviewComposerState extends State<ReviewComposer> {
  int _stars = 0;
  final _text = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_stars == 0 || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSubmit(_stars, _text.text.trim());
      if (mounted) {
        setState(() {
          _stars = 0;
          _text.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.signedIn) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppTokens.s16),
        decoration: BoxDecoration(
          color: AppTokens.surfaceMuted,
          borderRadius: BorderRadius.circular(AppTokens.radiusButton),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_outline_rounded,
                size: 18, color: AppTokens.textMuted),
            const SizedBox(width: AppTokens.s8),
            Expanded(
              child: Text(
                'Sign in to leave a review',
                style: AppTokens.caption,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your review', style: AppTokens.titleSm),
        const SizedBox(height: AppTokens.s12),
        Row(
          children: [
            for (var i = 1; i <= 5; i++)
              GestureDetector(
                onTap: () => setState(() => _stars = i),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(
                    _stars >= i
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    size: 32,
                    color: _stars >= i
                        ? AppTokens.ratingStar
                        : AppTokens.textMuted,
                  ),
                ),
              ),
            if (_stars > 0) ...[
              const SizedBox(width: 6),
              Text('$_stars', style: AppTokens.titleSm),
            ],
          ],
        ),
        const SizedBox(height: AppTokens.s12),
        TextField(
          controller: _text,
          maxLines: 3,
          maxLength: 2000,
          style: AppTokens.body,
          decoration: InputDecoration(
            hintText:
                'What did you notice? Specific detail helps the next person.',
            filled: true,
            fillColor: AppTokens.surfaceMuted,
            counterText: '',
            border: InputBorder.none,
            contentPadding: const EdgeInsets.all(AppTokens.s16),
          ),
        ),
        const SizedBox(height: AppTokens.s12),
        FilledButton(
          onPressed: _stars == 0 || _busy ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppTokens.accent,
            disabledBackgroundColor: AppTokens.accent.withValues(alpha: 0.35),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTokens.radiusButton),
            ),
          ),
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('Post review',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: AppTokens.s8),
        Text(
          'Your review\'s influence is worked out from your account history and '
          'the strength of evidence behind the visit. You do not set it.',
          style: AppTokens.metadata,
        ),
      ],
    );
  }
}

/// A published review, with the evidence labels the database allows us to show.
class ReviewTile extends StatelessWidget {
  const ReviewTile({super.key, required this.review});

  final Review review;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: AppTokens.surfaceMuted,
        borderRadius: BorderRadius.circular(AppTokens.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppTokens.background,
                child: Text(
                  review.authorName,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTokens.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: AppTokens.s8),
              _StarRow(rating: review.rating.toDouble(), size: 15),
              const Spacer(),
              Text(
                _ago(review.createdAt),
                style: AppTokens.metadata,
              ),
            ],
          ),
          if (review.text.isNotEmpty) ...[
            const SizedBox(height: AppTokens.s8),
            Text(review.text, style: AppTokens.bodySecondary),
          ],
          const SizedBox(height: AppTokens.s8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (review.verifiedVisit)
                const _Badge(
                  label: 'Verified visit',
                  icon: Icons.verified_rounded,
                  color: AppTokens.success,
                  background: AppTokens.successSoft,
                ),
              _Badge(
                label: review.reviewerStatus.label,
                icon: Icons.person_rounded,
                color: AppTokens.textSecondary,
                background: AppTokens.background,
              ),
              _Badge(
                label: review.evidenceLevel.label,
                icon: Icons.shield_outlined,
                color: AppTokens.accent,
                background: AppTokens.background,
              ),
              if (review.isOwner)
                const _Badge(
                  label: 'Owner',
                  icon: Icons.storefront_rounded,
                  color: AppTokens.warning,
                  background: AppTokens.warningSoft,
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays > 365) return '${(d.inDays / 365).floor()}y ago';
    if (d.inDays > 30) return '${(d.inDays / 30).floor()}mo ago';
    if (d.inDays > 0) return '${d.inDays}d ago';
    if (d.inHours > 0) return '${d.inHours}h ago';
    return '${d.inMinutes}m ago';
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.icon,
    required this.color,
    required this.background,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTokens.s8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppTokens.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

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
          Icon(
            rating >= i
                ? Icons.star_rounded
                : rating >= i - 0.5
                    ? Icons.star_half_rounded
                    : Icons.star_outline_rounded,
            size: size,
            color: AppTokens.ratingStar,
          ),
      ],
    );
  }
}
