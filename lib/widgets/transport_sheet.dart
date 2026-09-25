import 'package:flutter/material.dart';

import '../models/transport_route.dart';
import '../theme/app_tokens.dart';

/// Width of the column that holds the timeline nodes.
///
/// One number keeps the rail and every node on the same centre line, instead
/// of each step guessing its own.
const double _kNodeColumn = AppTokens.s24;

/// The timeline rail: two pixels of accent, the thinnest line in the app.
const double _kRailWidth = AppTokens.s2;

/// The "Public transport" bottom sheet.
///
/// Presentational by design: it renders the routes it is given, reports a tap
/// through [onSelectRoute], and holds no state that outlives itself. That way
/// the map screen stays the only owner of routing state and the sheet can be
/// dropped into any surface.
///
/// The list is the scannable view — duration leads, everything else supports
/// it. Selecting a route reveals the same numbers at full size plus a step
/// timeline, so opening a route is never a hunt for the same information.
class TransportSheet extends StatelessWidget {
  const TransportSheet({
    super.key,
    required this.origin,
    required this.destination,
    this.routes = const [],
    this.onSelectRoute,
    this.onBack,
    this.selectedMode,
    this.onModeChanged,
    this.selectedRoute,
    this.onBuyTickets,
  });

  /// e.g. "MG Road". Shown in the header subtitle.
  final String origin;

  /// e.g. "Indiranagar". Shown in the header subtitle.
  final String destination;

  /// The options to rank and show. Filtering and sorting happen upstream: the
  /// sheet shows what it is given, in the order it is given.
  final List<TransportRoute> routes;

  /// Fired when a route row is tapped, before the detail view opens.
  final ValueChanged<TransportRoute>? onSelectRoute;

  /// Fired by the header chevron when the sheet itself should close.
  final VoidCallback? onBack;

  /// The highlighted pill in the mode selector.
  final TransportMode? selectedMode;

  /// Fired when a mode pill is tapped.
  final ValueChanged<TransportMode>? onModeChanged;

  /// Opens straight into this route's detail view. The sheet also manages the
  /// selection internally, so this only has to be set when the parent wants to
  /// drive it from outside.
  final TransportRoute? selectedRoute;

  /// Fired by the "Buy tickets" button.
  final VoidCallback? onBuyTickets;

  /// Ready-made Bengaluru routes so the sheet can be previewed with realistic
  /// content before a routing backend exists.
  static List<TransportRoute> sampleRoutes() => const [
        TransportRoute(
          id: 'metro-purple',
          mode: TransportMode.train,
          durationMinutes: 17,
          priceLabel: '₹2.99',
          distanceKm: 4.2,
          isFastest: true,
          arrivalLabel: 'Arrive 14:32',
          legs: [
            RouteLeg(
              type: RouteLegType.walk,
              durationMinutes: 4,
              instruction: 'Walk to MG Road Metro',
              stopName: 'MG Road Metro',
            ),
            RouteLeg(
              type: RouteLegType.train,
              lineLabel: 'Purple',
              durationMinutes: 9,
              stops: 3,
              instruction: 'Take the Purple Line towards Baiyappanahalli',
              stopName: 'Cubbon Park',
            ),
            RouteLeg(
              type: RouteLegType.walk,
              durationMinutes: 4,
              instruction: 'Walk to 100 Feet Road',
              stopName: '12th Main, Indiranagar',
            ),
          ],
        ),
        TransportRoute(
          id: 'bus-52',
          mode: TransportMode.bus,
          durationMinutes: 28,
          priceLabel: '₹20',
          distanceKm: 4.6,
          arrivalLabel: 'Arrive 14:43',
          legs: [
            RouteLeg(
              type: RouteLegType.walk,
              durationMinutes: 3,
              instruction: 'Walk to the bus stop',
              stopName: 'MG Road (Towards Trinity)',
            ),
            RouteLeg(
              type: RouteLegType.bus,
              lineLabel: '52',
              durationMinutes: 18,
              stops: 7,
              instruction: 'Take bus 52 towards Whitefield',
              stopName: 'Trinity Circle',
            ),
            RouteLeg(
              type: RouteLegType.walk,
              durationMinutes: 7,
              instruction: 'Walk to your destination',
              stopName: '12th Main, Indiranagar',
            ),
          ],
        ),
        TransportRoute(
          id: 'cycle',
          mode: TransportMode.bicycle,
          durationMinutes: 21,
          priceLabel: '₹15',
          distanceKm: 4.4,
          arrivalLabel: 'Arrive 14:36',
          legs: [
            RouteLeg(
              type: RouteLegType.walk,
              durationMinutes: 2,
              instruction: 'Walk to the docking station',
              stopName: 'UB City Cycle Point',
            ),
            RouteLeg(
              type: RouteLegType.bicycle,
              durationMinutes: 17,
              stops: 6,
              instruction: 'Cycle along the Inner Ring Road',
              stopName: 'Domlur',
            ),
            RouteLeg(
              type: RouteLegType.walk,
              durationMinutes: 2,
              instruction: 'Walk to your destination',
              stopName: '12th Main, Indiranagar',
            ),
          ],
        ),
        TransportRoute(
          id: 'walk',
          mode: TransportMode.walking,
          durationMinutes: 34,
          priceLabel: 'Free',
          distanceKm: 2.6,
          legs: [
            RouteLeg(
              type: RouteLegType.walk,
              durationMinutes: 34,
              instruction: 'Head north-east along Brigade Road',
              stopName: '12th Main, Indiranagar',
            ),
          ],
        ),
      ];

  @override
  Widget build(BuildContext context) {
    return _TransportSheetView(
      origin: origin,
      destination: destination,
      routes: routes,
      selectedMode: selectedMode,
      selectedRoute: selectedRoute,
      onSelectRoute: onSelectRoute,
      onModeChanged: onModeChanged,
      onBack: onBack,
      onBuyTickets: onBuyTickets,
    );
  }
}

/// The sheet's body, stateful only for the route it has drilled into.
///
/// Splitting the state out here lets [TransportSheet] stay a `const` widget
/// the parent can build anywhere, while a tap can still open the detail view
/// without the parent lifting anything.
class _TransportSheetView extends StatefulWidget {
  const _TransportSheetView({
    required this.origin,
    required this.destination,
    required this.routes,
    required this.selectedMode,
    required this.selectedRoute,
    required this.onSelectRoute,
    required this.onModeChanged,
    required this.onBack,
    required this.onBuyTickets,
  });

  final String origin;
  final String destination;
  final List<TransportRoute> routes;
  final TransportMode? selectedMode;
  final TransportRoute? selectedRoute;
  final ValueChanged<TransportRoute>? onSelectRoute;
  final ValueChanged<TransportMode>? onModeChanged;
  final VoidCallback? onBack;
  final VoidCallback? onBuyTickets;

  @override
  State<_TransportSheetView> createState() => _TransportSheetViewState();
}

class _TransportSheetViewState extends State<_TransportSheetView> {
  TransportRoute? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selectedRoute;
  }

  @override
  void didUpdateWidget(covariant _TransportSheetView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent can drive the selection too; follow it whenever it moves so a
    // controlled sheet stays in step with an external "open details" action.
    if (widget.selectedRoute != oldWidget.selectedRoute) {
      _selected = widget.selectedRoute;
    }
  }

  void _open(TransportRoute route) {
    setState(() => _selected = route);
    widget.onSelectRoute?.call(route);
  }

  /// Always lands on the list first, so a second tap can close the sheet.
  void _close() {
    setState(() => _selected = null);
    widget.onBack?.call();
  }

  @override
  Widget build(BuildContext context) {
    final route = _selected;

    // Capping the height here means the sheet behaves the same whether it is
    // dropped into a modal or into a column, and the list still gets the
    // remaining space to scroll in.
    return ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetHeader(
            title: route == null ? 'Public transport' : 'Route details',
            subtitle: route == null
                ? '${widget.origin} → ${widget.destination}'
                : '${widget.origin} → ${widget.destination} · ${route.summary}',
            // Nothing to go back to on the last stop, so the control rests.
            onBack: route == null || widget.onBack != null ? _close : null,
          ),
          if (route == null) ...[
            _ModeSelector(
              selected: widget.selectedMode,
              onChanged: widget.onModeChanged,
            ),
            Expanded(
              child: _RouteList(routes: widget.routes, onSelect: _open),
            ),
          ] else
            Expanded(
              child: _RouteDetails(
                route: route,
                onBuyTickets: widget.onBuyTickets,
              ),
            ),
        ],
      ),
    );
  }
}

/// Back chevron plus the sheet title, and the one line that says where the
/// rider is going.
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.title,
    required this.subtitle,
    required this.onBack,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.gutter,
        AppTokens.s12,
        AppTokens.gutter,
        AppTokens.s12,
      ),
      child: Row(
        children: [
          _BackChip(onTap: onBack),
          const SizedBox(width: AppTokens.s12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTokens.titleLg,
                ),
                const SizedBox(height: AppTokens.s2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTokens.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A small white floating control, matching the map's icon buttons so the
/// sheet's affordances look like the rest of the app.
class _BackChip extends StatelessWidget {
  const _BackChip({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppTokens.radiusButton);
    return Container(
      width: 36,
      height: 36,
      decoration: AppTokens.controlDecoration,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Icon(
            Icons.chevron_left_rounded,
            size: 24,
            color: onTap == null ? AppTokens.textMuted : AppTokens.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// The mode selector: three equal pills, so the row reads as a set rather than
/// as a set of differently-sized buttons.
class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.selected, this.onChanged});

  final TransportMode? selected;
  final ValueChanged<TransportMode>? onChanged;

  /// The ways a rider chooses to travel. Bus is deliberately absent: it is a
  /// leg type here, and a bus *is* on the list already — the pill would just
  /// duplicate it.
  static const List<TransportMode> modes = <TransportMode>[
    TransportMode.train,
    TransportMode.walking,
    TransportMode.bicycle,
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.gutter,
        0,
        AppTokens.gutter,
        AppTokens.s12,
      ),
      child: Row(
        children: [
          for (var i = 0; i < modes.length; i++) ...[
            if (i > 0) const SizedBox(width: AppTokens.s8),
            Expanded(
              child: _ModePill(
                mode: modes[i],
                selected: selected == modes[i],
                onTap: onChanged == null
                    ? null
                    : () => onChanged!(modes[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One mode pill: accent fill when selected, white with a soft edge when not.
class _ModePill extends StatelessWidget {
  const _ModePill({
    required this.mode,
    required this.selected,
    this.onTap,
  });

  final TransportMode mode;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: AppTokens.s8),
        decoration: BoxDecoration(
          color: selected ? AppTokens.accent : AppTokens.background,
          borderRadius: BorderRadius.circular(AppTokens.radiusPill),
          border: selected ? null : Border.all(color: AppTokens.hairline),
          boxShadow: AppTokens.controlShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              mode.icon,
              size: 17,
              color: selected ? Colors.white : mode.tint,
            ),
            const SizedBox(width: AppTokens.s8),
            Flexible(
              child: Text(
                mode.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTokens.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppTokens.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The ranked list of routes.
class _RouteList extends StatelessWidget {
  const _RouteList({required this.routes, required this.onSelect});

  final List<TransportRoute> routes;
  final ValueChanged<TransportRoute> onSelect;

  @override
  Widget build(BuildContext context) {
    if (routes.isEmpty) return const _EmptyState();

    return ListView.separated(
      // Bottom room is a token-sized visual gap only — the parent owns the
      // safe-area inset.
      padding: const EdgeInsets.fromLTRB(
        AppTokens.gutter,
        AppTokens.s4,
        AppTokens.gutter,
        AppTokens.s24,
      ),
      itemCount: routes.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppTokens.s12),
      itemBuilder: (context, i) {
        final route = routes[i];
        return _RouteRow(
          key: ValueKey(route.id),
          route: route,
          onTap: () => onSelect(route),
        );
      },
    );
  }
}

/// One route as a floating card.
///
/// Duration is the strongest thing on the card because it is the number people
/// actually decide on; the walk figure, the price and the "Fastest" pill all
/// support it and none of them competes.
class _RouteRow extends StatelessWidget {
  const _RouteRow({super.key, required this.route, required this.onTap});

  final TransportRoute route;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppTokens.radiusCard);

    return Semantics(
      button: true,
      child: Material(
        color: AppTokens.background,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: AppTokens.floatShadow,
            ),
            padding: const EdgeInsets.all(AppTokens.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(route.durationLabel, style: AppTokens.titleLg),
                          const SizedBox(height: AppTokens.s4),
                          Row(
                            children: [
                              const Icon(
                                Icons.directions_walk_rounded,
                                size: 13,
                                color: AppTokens.textMuted,
                              ),
                              const SizedBox(width: AppTokens.s4),
                              Flexible(
                                child: Text(
                                  route.walkLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTokens.caption,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppTokens.s12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (route.isFastest) const _FastestPill(),
                        const SizedBox(height: AppTokens.s4),
                        Text(route.priceLabel, style: AppTokens.titleSm),
                        if (route.arrivalLabel != null) ...[
                          const SizedBox(height: AppTokens.s2),
                          Text(route.arrivalLabel!, style: AppTokens.metadata),
                        ],
                      ],
                    ),
                  ],
                ),
                if (route.lineLabels.isNotEmpty) ...[
                  const SizedBox(height: AppTokens.s12),
                  _LineBadges(legs: route.legs),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Fastest" — deliberately the quietest element on the card.
class _FastestPill extends StatelessWidget {
  const _FastestPill();

  static const String _label = 'Fastest';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.s8,
        vertical: AppTokens.s2,
      ),
      decoration: BoxDecoration(
        color: AppTokens.warningSoft,
        borderRadius: BorderRadius.circular(AppTokens.radiusPill),
      ),
      child: Text(
        _label.toUpperCase(),
        style: AppTokens.overline.copyWith(color: AppTokens.warning),
      ),
    );
  }
}

/// The line badges for a route, in leg order.
///
/// A [Wrap] rather than a [Row]: a route with four transfers should wrap onto a
/// second line instead of overflowing or getting truncated.
class _LineBadges extends StatelessWidget {
  const _LineBadges({required this.legs});

  final List<RouteLeg> legs;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppTokens.s8,
      runSpacing: AppTokens.s4,
      children: [
        for (final leg in legs)
          if ((leg.lineLabel ?? '').isNotEmpty)
            _LineBadge(label: leg.lineLabel!, tint: leg.tint),
      ],
    );
  }
}

/// A line number as a tiny rounded rectangle.
///
/// Tinted by the leg's mode and deliberately tiny: a badge is a label, and the
/// duration beside it has to stay the loudest thing in the row.
class _LineBadge extends StatelessWidget {
  const _LineBadge({required this.label, required this.tint});

  final String label;
  final Color tint;

  /// Badges are the only rounded rectangle in the app this tight — any larger
  /// a radius and an 11px label stops reading as a chip.
  static const double _radius = 6;

  /// Big enough to read at a glance, small enough to stay a badge.
  static const double _fontSize = 11;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.s8,
        vertical: AppTokens.s2,
      ),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(_radius),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: _fontSize,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: tint,
        ),
      ),
    );
  }
}

/// What a sheet with nothing to show says instead of an empty list.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.route_rounded,
              size: 28,
              color: AppTokens.textMuted,
            ),
            const SizedBox(height: AppTokens.s12),
            const Text('No routes right now', style: AppTokens.titleSm),
            const SizedBox(height: AppTokens.s4),
            const Text(
              'Try another departure point or travel mode.',
              textAlign: TextAlign.center,
              style: AppTokens.caption,
            ),
          ],
        ),
      ),
    );
  }
}

/// One route at full size: the headline numbers, the ticket button, the steps.
class _RouteDetails extends StatelessWidget {
  const _RouteDetails({required this.route, this.onBuyTickets});

  final TransportRoute route;
  final VoidCallback? onBuyTickets;

  @override
  Widget build(BuildContext context) {
    final details = TransportRouteDetails.from(route);

    return ListView(
      // Bottom room is a token-sized visual gap only — the parent owns the
      // safe-area inset.
      padding: const EdgeInsets.fromLTRB(
        AppTokens.gutter,
        AppTokens.s4,
        AppTokens.gutter,
        AppTokens.s24,
      ),
      children: [
        _StatsRow(details: details),
        const SizedBox(height: AppTokens.s16),
        _BuyButton(onTap: onBuyTickets),
        const SizedBox(height: AppTokens.s24),
        const Text('Steps', style: AppTokens.titleMd),
        const SizedBox(height: AppTokens.s12),
        _RouteTimeline(route: route),
      ],
    );
  }
}

/// Duration, distance and price, once each, in the order a rider weighs them.
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.details});

  final TransportRouteDetails details;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _Stat(
            value: details.durationLabel,
            label: 'Duration',
            isLead: true,
          ),
        ),
        Expanded(
          child: _Stat(value: details.distanceLabel, label: 'Distance'),
        ),
        Expanded(child: _Stat(value: details.priceLabel, label: 'Price')),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.value,
    required this.label,
    this.isLead = false,
  });

  final String value;
  final String label;

  /// The duration is the lead number, so it is set a step larger than the
  /// other two.
  final bool isLead;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: isLead ? AppTokens.titleLg : AppTokens.titleSm,
        ),
        const SizedBox(height: AppTokens.s2),
        Text(label, style: AppTokens.metadata),
      ],
    );
  }
}

/// The primary action: one accent-filled button, nothing competing near it.
class _BuyButton extends StatelessWidget {
  const _BuyButton({this.onTap});

  final VoidCallback? onTap;

  static const String _label = 'Buy tickets';

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onTap == null ? AppTokens.textMuted : AppTokens.accent,
      borderRadius: BorderRadius.circular(AppTokens.radiusButton),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusButton),
        child: SizedBox(
          height: 52,
          child: Center(
            child: Text(
              _label,
              style: AppTokens.titleSm.copyWith(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// The legs as a vertical timeline.
///
/// The rail is a single continuous line drawn behind the nodes rather than a
/// segment per row, so the steps read as one path instead of a stack of boxes.
class _RouteTimeline extends StatelessWidget {
  const _RouteTimeline({required this.route});

  final TransportRoute route;

  @override
  Widget build(BuildContext context) {
    final legs = route.legs;
    if (legs.isEmpty) {
      return const Text('No step details for this route.', style: AppTokens.caption);
    }

    return Stack(
      children: [
        Positioned(
          left: (_kNodeColumn - _kRailWidth) / 2,
          top: 0,
          bottom: 0,
          child: Container(
            width: _kRailWidth,
            color: AppTokens.accent.withValues(alpha: 0.22),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < legs.length; i++)
              _TimelineStep(
                leg: legs[i],
                isFirst: i == 0,
                isLast: i == legs.length - 1,
                // Arrival belongs to the end of the journey, not to every step.
                arrival: i == legs.length - 1 ? route.arrivalLabel : null,
              ),
          ],
        ),
      ],
    );
  }
}

/// One node on the rail and everything that says what happens there.
class _TimelineStep extends StatelessWidget {
  const _TimelineStep({
    required this.leg,
    required this.isFirst,
    required this.isLast,
    this.arrival,
  });

  final RouteLeg leg;
  final bool isFirst;
  final bool isLast;
  final String? arrival;

  @override
  Widget build(BuildContext context) {
    final label = leg.lineLabel;
    final name = leg.stopName ?? leg.instruction ?? leg.legLabel;
    final meta = arrival == null
        ? leg.metadataLabel
        : '${leg.metadataLabel} · $arrival';

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.s16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _kNodeColumn,
            child: Padding(
              padding: const EdgeInsets.only(top: AppTokens.s4),
              child: Center(
                child: _TimelineNode(
                  // The ends of the journey are the two things worth spotting.
                  emphasis: isFirst || isLast,
                  tint: leg.tint,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppTokens.s12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(leg.mode.icon, size: 14, color: leg.tint),
                    const SizedBox(width: AppTokens.s4),
                    if (label == null || label.isEmpty)
                      Text(leg.legLabel, style: AppTokens.metadata)
                    else
                      _LineBadge(label: label, tint: leg.tint),
                  ],
                ),
                const SizedBox(height: AppTokens.s4),
                Text(
                  name,
                  style: AppTokens.titleSm,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppTokens.s2),
                Text(meta, style: AppTokens.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A dot on the rail. The first and last are larger and filled with the accent
/// so the ends of the journey are obvious at a glance; the middle ones stay
/// small and hollow, tinted with their leg's mode.
class _TimelineNode extends StatelessWidget {
  const _TimelineNode({required this.emphasis, required this.tint});

  final bool emphasis;
  final Color tint;

  /// Node sizes live here rather than in the token scale: a dot has no token,
  /// and the step between a resting and an emphasised node is what makes the
  /// ends of the timeline readable.
  static const double _resting = 10;
  static const double _emphasised = 14;

  @override
  Widget build(BuildContext context) {
    final size = emphasis ? _emphasised : _resting;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: emphasis ? AppTokens.accent : AppTokens.background,
        border: emphasis ? null : Border.all(color: tint, width: 2),
      ),
    );
  }
}
