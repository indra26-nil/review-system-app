import 'package:flutter/material.dart';

import '../models/place.dart';
import '../theme/app_tokens.dart';

/// The floating search control that sits above the map.
///
/// The control is **always in the same place**. Tapping it swaps the hint text
/// for a real [TextField] in the very same container — the bar never moves to
/// the bottom of the screen and never re-lays-out, so the keyboard appearing
/// cannot shift the map's chrome around. [isActive] is the only thing that
/// changes: hint in, field out.
class FloatingSearchBar extends StatefulWidget {
  const FloatingSearchBar({
    super.key,
    required this.onTap,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.isActive = false,
    this.hint = 'What are you looking for?',
    this.controller,
    this.focusNode,
    this.trailing,
  });

  /// Activates the bar when it is not yet active.
  final VoidCallback onTap;

  /// Fired on every keystroke while active, already debounced by the caller.
  final ValueChanged<String>? onChanged;

  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;

  /// When true the bar renders a focused [TextField]; otherwise a tappable hint.
  final bool isActive;

  final String hint;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Optional right-hand slot, e.g. a profile/avatar button.
  final Widget? trailing;

  @override
  State<FloatingSearchBar> createState() => _FloatingSearchBarState();
}

class _FloatingSearchBarState extends State<FloatingSearchBar> {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: AppTokens.searchBarHeight,
            padding: const EdgeInsets.symmetric(horizontal: AppTokens.s16),
            decoration: AppTokens.searchDecoration,
            child: Row(
              children: [
                const Icon(
                  Icons.search_rounded,
                  size: 23,
                  color: AppTokens.textSecondary,
                ),
                const SizedBox(width: AppTokens.s12),
                Expanded(
                  child: widget.isActive
                      ? TextField(
                          controller: widget.controller,
                          focusNode: widget.focusNode,
                          autofocus: true,
                          textInputAction: TextInputAction.search,
                          onChanged: widget.onChanged,
                          onSubmitted: widget.onSubmitted,
                          style: AppTokens.body.copyWith(fontSize: 16),
                          cursorColor: AppTokens.accent,
                          decoration: const InputDecoration(
                            hintText: 'Search places, addresses…',
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            hintStyle: TextStyle(
                              color: AppTokens.textMuted,
                              fontSize: 16,
                            ),
                          ),
                        )
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: widget.onTap,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              widget.hint,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTokens.body.copyWith(
                                fontSize: 16,
                                color: AppTokens.textMuted,
                              ),
                            ),
                          ),
                        ),
                ),
                if (widget.isActive && widget.onClear != null)
                  GestureDetector(
                    onTap: widget.onClear,
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.only(left: AppTokens.s8),
                      child: Icon(
                        Icons.cancel_rounded,
                        size: 22,
                        color: AppTokens.textMuted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (widget.trailing != null) ...[
          const SizedBox(width: AppTokens.s12),
          widget.trailing!,
        ],
      ],
    );
  }
}

/// A row of category shortcuts under the search bar.
///
/// Horizontally scrollable, because six pills plus a search field do not fit a
/// 375 pt screen without cramping the type.
class CategoryPills extends StatelessWidget {
  const CategoryPills({
    super.key,
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  final List<PlaceCategory> categories;
  final PlaceCategory? selected;

  /// Fires with `null` when the active pill is tapped again, so the caller can
  /// clear the filter.
  final ValueChanged<PlaceCategory?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppTokens.categoryPillHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppTokens.s8),
        itemBuilder: (context, i) {
          final c = categories[i];
          final isOn = selected == c;
          return GestureDetector(
            onTap: () => onSelected(isOn ? null : c),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isOn ? AppTokens.accent : AppTokens.background,
                borderRadius: BorderRadius.circular(AppTokens.radiusPill),
                boxShadow: AppTokens.controlShadow,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    c.icon,
                    size: 18,
                    color: isOn ? Colors.white : c.tint,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    c.label,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: isOn ? Colors.white : AppTokens.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A small white rounded control that floats over the map.
///
/// Used for current location, layers, zoom and compass. Tactile, unbordered,
/// never heavy.
class MapControlButton extends StatelessWidget {
  const MapControlButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.isActive = false,
    this.size = AppTokens.controlSize,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  /// Tints the icon to signal a toggled-on state.
  final bool isActive;
  final double size;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: AppTokens.background,
      borderRadius: BorderRadius.circular(AppTokens.radiusButton),
      elevation: 0,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppTokens.radiusButton),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            size: 23,
            color: isActive ? AppTokens.accent : AppTokens.textPrimary,
          ),
        ),
      ),
    );

    return tooltip == null
        ? Container(decoration: AppTokens.controlDecoration, child: button)
        : Tooltip(message: tooltip!, child: Container(decoration: AppTokens.controlDecoration, child: button));
  }
}

/// A vertical stack of floating controls, e.g. zoom in / zoom out.
class MapControlStack extends StatelessWidget {
  const MapControlStack({super.key, required this.children, this.gap = 1});

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: 10 + gap),
          children[i],
        ],
      ],
    );
  }
}
