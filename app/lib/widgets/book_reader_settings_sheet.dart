import 'package:flutter/material.dart';

import '../persist/book_reader_prefs.dart';
import '../theme.dart';

class BookReaderSettingsSheet extends StatefulWidget {
  const BookReaderSettingsSheet({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  final ReaderSettings initial;
  final ValueChanged<ReaderSettings> onChanged;

  @override
  State<BookReaderSettingsSheet> createState() => _BookReaderSettingsSheetState();
}

class _BookReaderSettingsSheetState extends State<BookReaderSettingsSheet> {
  late ReaderSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.initial;
  }

  void _update(ReaderSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = _settings.palette;
    return Container(
      decoration: BoxDecoration(
        color: Wx.raised,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Wx.inset, 12, Wx.inset, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Wx.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('阅读设置', style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              Text('背景', style: theme.textTheme.labelSmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  _ThemeChip(
                    label: '浅色',
                    selected: _settings.theme == ReaderThemeMode.light,
                    preview: ReaderPalette.forMode(ReaderThemeMode.light).paper,
                    onTap: () => _update(_settings.copyWith(theme: ReaderThemeMode.light)),
                  ),
                  const SizedBox(width: 8),
                  _ThemeChip(
                    label: '护眼',
                    selected: _settings.theme == ReaderThemeMode.sepia,
                    preview: ReaderPalette.forMode(ReaderThemeMode.sepia).paper,
                    onTap: () => _update(_settings.copyWith(theme: ReaderThemeMode.sepia)),
                  ),
                  const SizedBox(width: 8),
                  _ThemeChip(
                    label: '深色',
                    selected: _settings.theme == ReaderThemeMode.dark,
                    preview: ReaderPalette.forMode(ReaderThemeMode.dark).paper,
                    onTap: () => _update(_settings.copyWith(theme: ReaderThemeMode.dark)),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _SliderRow(
                label: '字号',
                value: _settings.fontSize,
                min: 15,
                max: 28,
                divisions: 13,
                display: _settings.fontSize.round().toString(),
                onChanged: (v) => _update(_settings.copyWith(fontSize: v)),
              ),
              _SliderRow(
                label: '行距',
                value: _settings.lineHeight,
                min: 1.35,
                max: 2.05,
                divisions: 14,
                display: _settings.lineHeight.toStringAsFixed(2),
                onChanged: (v) => _update(_settings.copyWith(lineHeight: v)),
              ),
              _SliderRow(
                label: '边距',
                value: _settings.horizontalPadding,
                min: 8,
                max: 36,
                divisions: 14,
                display: _settings.horizontalPadding.round().toString(),
                onChanged: (v) => _update(_settings.copyWith(horizontalPadding: v)),
              ),
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.paper,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Wx.hairline),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: _settings.horizontalPadding,
                    vertical: 16,
                  ),
                  child: Text(
                    '预览：阅读是为了遇见更大的世界。',
                    style: TextStyle(
                      fontSize: _settings.fontSize,
                      height: _settings.lineHeight,
                      color: palette.ink,
                    ),
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

class _ThemeChip extends StatelessWidget {
  const _ThemeChip({
    required this.label,
    required this.selected,
    required this.preview,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: preview,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? Wx.accent : Wx.hairline,
                width: selected ? 2 : 1,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? Wx.accent : Wx.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            const Spacer(),
            Text(display, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
