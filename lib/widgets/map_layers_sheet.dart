import 'package:flutter/material.dart';

import '../models/map_layer.dart';
import '../theme/app_tokens.dart';

/// Result returned by [showMapLayersSheet].
class MapLayersSelection {
  const MapLayersSelection({
    required this.baseLayerId,
    required this.enabledOverlays,
  });

  final String baseLayerId;
  final Set<MapOverlay> enabledOverlays;
}

/// Base-layer and overlay picker.
///
/// Presented as a light sheet so it belongs to the same system as the map and
/// the place card: white surface, generous radii, hairline separation instead
/// of dark borders.
Future<MapLayersSelection?> showMapLayersSheet({
  required BuildContext context,
  required String currentBaseLayerId,
  required Set<MapOverlay> currentOverlays,
}) {
  return showModalBottomSheet<MapLayersSelection>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTokens.background,
    elevation: 0,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppTokens.radiusSheet),
      ),
    ),
    builder: (_) => _MapLayersSheet(
      currentBaseLayerId: currentBaseLayerId,
      currentOverlays: currentOverlays,
    ),
  );
}

class _MapLayersSheet extends StatefulWidget {
  const _MapLayersSheet({
    required this.currentBaseLayerId,
    required this.currentOverlays,
  });

  final String currentBaseLayerId;
  final Set<MapOverlay> currentOverlays;

  @override
  State<_MapLayersSheet> createState() => _MapLayersSheetState();
}

class _MapLayersSheetState extends State<_MapLayersSheet> {
  late String _selectedId = widget.currentBaseLayerId;
  late final Set<MapOverlay> _overlays = Set.of(widget.currentOverlays);

  bool get _isDirty =>
      _selectedId != widget.currentBaseLayerId ||
      !_setEquals(_overlays, widget.currentOverlays);

  static bool _setEquals(Set<MapOverlay> a, Set<MapOverlay> b) =>
      a.length == b.length && a.containsAll(b);

  void _submit() {
    Navigator.of(context).pop(
      MapLayersSelection(
        baseLayerId: _selectedId,
        enabledOverlays: _overlays,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTokens.grabber,
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.gutter,
                0,
                AppTokens.s12,
                AppTokens.s12,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Map layers', style: AppTokens.titleLg),
                        const SizedBox(height: 2),
                        Text(
                          'Base style and troubleshooting overlays',
                          style: AppTokens.caption,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.gutter,
                  AppTokens.s16,
                  AppTokens.gutter,
                  AppTokens.s16,
                ),
                children: [
                  for (final layer in MapBaseLayer.osmLayers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppTokens.s12),
                      child: _LayerCard(
                        layer: layer,
                        selected: layer.id == _selectedId,
                        onTap: () => setState(() => _selectedId = layer.id),
                      ),
                    ),
                  const SizedBox(height: AppTokens.s8),
                  Text('Troubleshooting overlays',
                      style: AppTokens.titleSm),
                  const SizedBox(height: AppTokens.s8),
                  for (final overlay in MapOverlay.values)
                    _OverlayRow(
                      overlay: overlay,
                      value: _overlays.contains(overlay),
                      onChanged: (on) => setState(() {
                        on ? _overlays.add(overlay) : _overlays.remove(overlay);
                      }),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.gutter,
                0,
                AppTokens.gutter,
                AppTokens.s12,
              ),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _isDirty ? _submit : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTokens.accent,
                    disabledBackgroundColor: AppTokens.surfaceMuted,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppTokens.radiusButton),
                    ),
                  ),
                  child: Text(
                    'Apply',
                    style: AppTokens.titleSm.copyWith(
                      color: _isDirty ? Colors.white : AppTokens.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LayerCard extends StatelessWidget {
  const _LayerCard({
    required this.layer,
    required this.selected,
    required this.onTap,
  });

  final MapBaseLayer layer;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppTokens.accentSoft : AppTokens.background,
      borderRadius: BorderRadius.circular(AppTokens.radiusCard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.radiusCard),
        child: Container(
          padding: const EdgeInsets.all(AppTokens.s12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTokens.radiusCard),
            border: Border.all(
              color: selected ? AppTokens.accent : AppTokens.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              // Preview swatch tinted from the layer's own seed colour.
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: layer.previewSeed,
                  borderRadius: BorderRadius.circular(AppTokens.radiusImage),
                ),
                child: Icon(
                  Icons.map_rounded,
                  size: 20,
                  color: Colors.black.withValues(alpha: 0.32),
                ),
              ),
              const SizedBox(width: AppTokens.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            layer.name,
                            style: AppTokens.titleSm,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (layer.needsApiKey) ...[
                          const SizedBox(width: 6),
                          const _Tag('KEY'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      layer.attribution,
                      style: AppTokens.metadata,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (layer.tileWarning != null) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.info_outline,
                              size: 12, color: AppTokens.warning),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              layer.tileWarning!,
                              style: AppTokens.metadata.copyWith(
                                color: AppTokens.warning,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle,
                    color: AppTokens.accent, size: 22)
              else
                IconButton(
                  tooltip: 'About ${layer.name}',
                  onPressed: () => _showInfo(context, layer),
                  icon: const Icon(Icons.info_outline_rounded,
                      size: 19, color: AppTokens.textMuted),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showInfo(BuildContext context, MapBaseLayer layer) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTokens.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTokens.radiusSheet),
        ),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.gutter,
            0,
            AppTokens.gutter,
            AppTokens.s24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppTokens.grabber,
              Text(layer.name, style: AppTokens.titleLg),
              const SizedBox(height: AppTokens.s12),
              Text(layer.sourceNote, style: AppTokens.bodySecondary),
              const SizedBox(height: AppTokens.s16),
              Row(
                children: [
                  const Icon(Icons.copyright_rounded,
                      size: 15, color: AppTokens.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(layer.attribution, style: AppTokens.metadata),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTokens.warningSoft,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: AppTokens.warning,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _OverlayRow extends StatelessWidget {
  const _OverlayRow({
    required this.overlay,
    required this.value,
    required this.onChanged,
  });

  final MapOverlay overlay;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onChanged(!value),
          borderRadius: BorderRadius.circular(AppTokens.radiusButton),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: Checkbox(
                    value: value,
                    onChanged: (v) => onChanged(v ?? false),
                    activeColor: AppTokens.accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    side: const BorderSide(
                      color: Color(0x33000000),
                      width: 1.5,
                    ),
                  ),
                ),
                const SizedBox(width: AppTokens.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(overlay.title, style: AppTokens.titleSm),
                      const SizedBox(height: 1),
                      Text(overlay.subtitle, style: AppTokens.metadata),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
