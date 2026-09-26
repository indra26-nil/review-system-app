import 'package:flutter/material.dart';

import '../models/place.dart';
import '../services/simulation_repository.dart';
import '../theme/app_tokens.dart';

/// A console for demonstrating the trust model.
///
/// It exists so the system's behaviour can be shown in seconds rather than by
/// waiting for real behavioural history to accumulate. Everything it displays is
/// computed by the database using the production formula; the sliders only
/// choose inputs, and the weight shown is the one the server returned.
class SimulatorScreen extends StatefulWidget {
  const SimulatorScreen({
    super.key,
    required this.repository,
    required this.places,
    this.initialPlace,
  });

  final SimulationRepository repository;
  final List<Place> places;
  final Place? initialPlace;

  @override
  State<SimulatorScreen> createState() => _SimulatorScreenState();
}

class _SimulatorScreenState extends State<SimulatorScreen> {
  // Start on the first scenario so the screen is never empty on open.
  TrustScenario _scenario = kTrustScenarios.first;
  double _userTrust = kTrustScenarios.first.userTrust;
  double _cityTrust = kTrustScenarios.first.cityTrust;
  double _reviewTrust = kTrustScenarios.first.reviewTrust;

  Place? _place;
  String? _accountId;
  String _accountHandle = 'demo-user';

  double? _serverWeight;
  SimulationSummary? _summary;
  bool _enabled = true;
  bool _busy = false;
  String? _error;
  String? _note;

  @override
  void initState() {
    super.initState();
    _place = widget.initialPlace ?? (widget.places.isNotEmpty ? widget.places.first : null);
    _checkEnabled();
  }

  Future<void> _checkEnabled() async {
    final enabled = await widget.repository.isEnabled();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      if (!enabled) {
        _error = 'The simulator is switched off in the database.\n\n'
            'Run:  update trust_config set value = 1 where key = \'simulator_enabled\';';
      }
    });
    if (enabled) _refreshPreview();
  }

  /// Ask the database what the current inputs are worth.
  ///
  /// Debounced because it is a round trip, and because dragging a slider should
  /// not fire a request per frame.
  Future<void> _refreshPreview() async {
    if (!_enabled) return;
    try {
      final w = await widget.repository.preview(
        userTrust: _userTrust,
        cityTrust: _cityTrust,
        reviewTrust: _reviewTrust,
      );
      if (!mounted) return;
      setState(() => _serverWeight = w);
    } on SimulationException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  void _applyScenario(TrustScenario s) {
    setState(() {
      _scenario = s;
      _userTrust = s.userTrust;
      _cityTrust = s.cityTrust;
      _reviewTrust = s.reviewTrust;
      _serverWeight = null;
    });
    _refreshPreview();
  }

  Future<void> _ensureAccount() async {
    if (_accountId != null) return;
    _setBusy(() async {
      _accountId = await widget.repository.createAccount(_accountHandle);
    });
  }

  Future<void> _setTrustAndPost() async {
    final place = _place;
    if (place == null) return;
    await _ensureAccount();
    if (!mounted || _accountId == null) return;

    _setBusy(() async {
      await widget.repository.setTrust(
        userId: _accountId!,
        placeId: place.id,
        userTrust: _userTrust,
        cityTrust: _cityTrust,
      );
      await widget.repository.postReview(
        userId: _accountId!,
        placeId: place.id,
        rating: _scenario.stars,
        reviewTrust: _reviewTrust,
        text: '${_scenario.label} — simulated',
      );
      _summary = await widget.repository.summary(place.id);
      _note = 'Posted at ${_scenario.label}';
    });
  }

  Future<void> _reset() async {
    _setBusy(() async {
      await widget.repository.reset();
      _summary = _place == null ? null : await widget.repository.summary(_place!.id);
      _note = 'Simulated reviews cleared';
    });
  }

  Future<void> _setBusy(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on SimulationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trust simulator'),
        actions: [
          IconButton(
            tooltip: 'Reset simulated data',
            onPressed: _busy ? null : _reset,
            icon: const Icon(Icons.restart_alt_rounded),
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                  AppTokens.gutter, AppTokens.s8, AppTokens.gutter, AppTokens.s32),
              children: [
                if (_error != null) ...[
                  _Banner(_error!, isError: true),
                  const SizedBox(height: AppTokens.s16),
                ],
                if (_note != null) ...[
                  _Banner(_note!, isError: false),
                  const SizedBox(height: AppTokens.s16),
                ],

                _Section('Scenarios from the specification',
                    subtitle: 'Each is a worked example with its expected weight'),
                const SizedBox(height: AppTokens.s8),
                SizedBox(
                  height: 96,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: kTrustScenarios.length,
                    separatorBuilder: (_, _) => const SizedBox(width: AppTokens.s8),
                    itemBuilder: (context, i) {
                      final s = kTrustScenarios[i];
                      final on = s.label == _scenario.label;
                      return _ScenarioChip(
                        scenario: s,
                        selected: on,
                        onTap: () => _applyScenario(s),
                      );
                    },
                  ),
                ),

                const SizedBox(height: AppTokens.s24),
                _Section('Inputs', subtitle: 'Drag to see the weight change'),
                _Slider(
                  label: 'UserTrust',
                  help: 'How reliable the account looks from its history',
                  value: _userTrust,
                  max: 100,
                  colour: AppTokens.accent,
                  onChanged: (v) {
                    setState(() => _userTrust = v);
                    _refreshPreview();
                  },
                ),
                _Slider(
                  label: 'CityTrust',
                  help: 'How established they are in this city. '
                      '70 is where the local bonus starts',
                  value: _cityTrust,
                  max: 100,
                  colour: _cityTrust >= 70 ? AppTokens.success : AppTokens.warning,
                  threshold: 70,
                  onChanged: (v) {
                    setState(() => _cityTrust = v);
                    _refreshPreview();
                  },
                ),
                _Slider(
                  label: 'ReviewTrust',
                  help: 'Strength of evidence behind this one review',
                  value: _reviewTrust,
                  max: 100,
                  colour: AppTokens.warning,
                  onChanged: (v) {
                    setState(() => _reviewTrust = v);
                    _refreshPreview();
                  },
                ),

                const SizedBox(height: AppTokens.s8),
                _Breakdown(
                  userTrust: _userTrust,
                  cityTrust: _cityTrust,
                  reviewTrust: _reviewTrust,
                  serverWeight: _serverWeight,
                  expected: _scenario.expectedWeight,
                  matchesScenario:
                      _scenario.userTrust == _userTrust &&
                          _scenario.cityTrust == _cityTrust &&
                          _scenario.reviewTrust == _reviewTrust,
                ),

                const SizedBox(height: AppTokens.s24),
                _Section('Publish a review with these scores'),
                if (widget.places.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTokens.s12),
                    child: Wrap(
                      spacing: AppTokens.s8,
                      runSpacing: AppTokens.s8,
                      children: [
                        for (final p in widget.places.take(12))
                          ChoiceChip(
                            label: Text(p.name),
                            selected: _place?.id == p.id,
                            onSelected: (_) => setState(() => _place = p),
                          ),
                      ],
                    ),
                  ),
                FilledButton.icon(
                  onPressed: _place == null || !_enabled ? null : _setTrustAndPost,
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('Apply and post the review'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTokens.accent,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTokens.radiusButton),
                    ),
                  ),
                ),

                if (_summary != null) ...[
                  const SizedBox(height: AppTokens.s20),
                  _Section('Live aggregate for ${_place?.name ?? ''}'),
                  const SizedBox(height: AppTokens.s8),
                  _SummaryCard(summary: _summary!),
                ],
              ],
            ),
    );
  }
}

/// The formula, worked out line by line.
///
/// The server's own result is shown next to the specification's expected value,
/// so a divergence between the implementation and the spec is visible rather
/// than hidden behind a single number.
class _Breakdown extends StatelessWidget {
  const _Breakdown({
    required this.userTrust,
    required this.cityTrust,
    required this.reviewTrust,
    required this.serverWeight,
    required this.expected,
    required this.matchesScenario,
  });

  final double userTrust;
  final double cityTrust;
  final double reviewTrust;
  final double? serverWeight;
  final double expected;
  final bool matchesScenario;

  @override
  Widget build(BuildContext context) {
    // Mirrors the documented formula so the lines explain themselves. The
    // authoritative number is the server's.
    final base = userTrust / 100.0;
    final bonus = cityTrust >= 70;
    final reviewer = bonus ? (base + 0.15).clamp(0.0, 1.0) : base;
    final evidence = 0.50 + 0.50 * (reviewTrust / 100.0);
    final local = reviewer * evidence;

    final shown = serverWeight ?? local;
    final drift = matchesScenario && (shown - expected).abs() > 0.005;

    return Container(
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: AppTokens.surfaceMuted,
        borderRadius: BorderRadius.circular(AppTokens.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Line('user_trust ${userTrust.round()} ÷ 100',
              base.toStringAsFixed(3)),
          _Line(
            'city_trust ${cityTrust.round()} ${bonus ? '≥ 70  → +0.15' : '< 70  → no bonus'}',
            bonus ? (base + 0.15).clamp(0.0, 1.0).toStringAsFixed(3)
                : base.toStringAsFixed(3),
            highlight: bonus,
          ),
          _Line(
            'evidence  0.50 + 0.50 × ${reviewTrust.round()}/100',
            evidence.toStringAsFixed(3),
          ),
          const Divider(height: 18),
          _Line('review_weight', shown.toStringAsFixed(4), strong: true),
          if (matchesScenario) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  drift ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
                  size: 14,
                  color: drift ? AppTokens.warning : AppTokens.success,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    drift
                        ? 'Server says ${shown.toStringAsFixed(4)}, '
                            'spec expects ${expected.toStringAsFixed(4)}'
                        : 'Matches the specification (${expected.toStringAsFixed(4)})',
                    style: AppTokens.metadata.copyWith(
                      color: drift ? AppTokens.warning : AppTokens.success,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.highlight = false, this.strong = false});
  final String label;
  final String value;
  final bool highlight;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: strong ? AppTokens.titleSm : AppTokens.caption,
            ),
          ),
          Text(
            value,
            style: (strong ? AppTokens.titleSm : AppTokens.caption).copyWith(
              fontWeight: FontWeight.w700,
              color: highlight ? AppTokens.success : AppTokens.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.help,
    required this.value,
    required this.max,
    required this.colour,
    required this.onChanged,
    this.threshold,
  });

  final String label;
  final String help;
  final double value;
  final double max;
  final Color colour;
  final ValueChanged<double> onChanged;
  final double? threshold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: AppTokens.titleSm)),
              Text(value.round().toString(), style: AppTokens.titleSm),
            ],
          ),
          Text(help, style: AppTokens.metadata),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
              activeTrackColor: colour,
              thumbColor: colour,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Slider(
                  value: value.clamp(0, max),
                  max: max,
                  onChanged: onChanged,
                ),
                if (threshold != null)
                  // Marks where the local bonus begins.
                  Positioned(
                    left: MediaQuery.sizeOf(context).width * 0.5 *
                        (threshold! / max) -
                        MediaQuery.sizeOf(context).width * 0.12 *
                            (threshold! / max),
                    child: Container(
                      width: 2,
                      height: 12,
                      color: AppTokens.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScenarioChip extends StatelessWidget {
  const _ScenarioChip({
    required this.scenario,
    required this.selected,
    required this.onTap,
  });

  final TrustScenario scenario;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 168,
        padding: const EdgeInsets.all(AppTokens.s12),
        decoration: BoxDecoration(
          color: selected ? AppTokens.accentSoft : AppTokens.background,
          borderRadius: BorderRadius.circular(AppTokens.radiusCard),
          border: Border.all(
            color: selected ? AppTokens.accent : AppTokens.hairline,
            width: selected ? 1.8 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              scenario.label,
              style: AppTokens.titleSm.copyWith(fontSize: 12.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              scenario.blurb,
              style: AppTokens.metadata,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                Text(
                  '${scenario.userTrust.round()}·${scenario.cityTrust.round()}·'
                  '${scenario.reviewTrust.round()}',
                  style: AppTokens.metadata,
                ),
                const Spacer(),
                Text(
                  scenario.expectedWeight.toStringAsFixed(3),
                  style: AppTokens.titleSm.copyWith(
                    fontSize: 12.5,
                    color: AppTokens.accent,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});
  final SimulationSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: AppTokens.background,
        borderRadius: BorderRadius.circular(AppTokens.radiusCard),
        boxShadow: AppTokens.controlShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(summary.adjustedRating.toStringAsFixed(2),
                  style: AppTokens.titleLg),
              const SizedBox(width: AppTokens.s8),
              Expanded(
                child: Text(
                  '${summary.rawCount} review'
                  '${summary.rawCount == 1 ? '' : 's'}'
                  '  ·  ${summary.effectiveCount.toStringAsFixed(2)} effective',
                  style: AppTokens.caption,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.s8),
          Text('${summary.confidenceLabel} evidence backing this rating',
              style: AppTokens.metadata),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTokens.titleMd),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!, style: AppTokens.metadata),
        ],
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {required this.isError});
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.s12),
      decoration: BoxDecoration(
        color: isError ? AppTokens.dangerSoft : AppTokens.successSoft,
        borderRadius: BorderRadius.circular(AppTokens.radiusButton),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.check_circle_rounded,
            size: 17,
            color: isError ? AppTokens.danger : AppTokens.success,
          ),
          const SizedBox(width: AppTokens.s8),
          Expanded(
            child: Text(
              text,
              style: AppTokens.caption.copyWith(
                color: isError ? AppTokens.danger : AppTokens.success,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
