import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Parses `#RGB`, `#RRGGBB` or `#AARRGGBB` (the `#` is optional).
Color? parseHexColor(String input) {
  var hex = input.trim().replaceFirst('#', '');
  if (hex.length == 3) hex = hex.split('').map((c) => '$c$c').join();
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  final v = int.tryParse(hex, radix: 16);
  return v == null ? null : Color(v);
}

String toHex(Color c) {
  final v = c.toARGB32();
  final rgb = (v & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
  final a = (v >> 24) & 0xFF;
  return a == 0xFF ? '#$rgb' : '#${a.toRadixString(16).padLeft(2, '0').toUpperCase()}$rgb';
}

Future<Color?> showColorPickerDialog(BuildContext context, {required Color initial}) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _ColorPickerDialog(initial: initial),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial});
  final Color initial;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final TextEditingController _hex = TextEditingController(text: toHex(widget.initial));
  String? _error;

  Color get _color => _hsv.toColor();

  void _setHsv(HSVColor hsv) {
    setState(() {
      _hsv = hsv;
      _hex.text = toHex(hsv.toColor());
      _error = null;
    });
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Custom colour'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 56,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              ),
            ),
            const SizedBox(height: 12),
            _labeledSlider('Hue', _hsv.hue, 0, 360, (v) => _setHsv(_hsv.withHue(v))),
            _labeledSlider('Saturation', _hsv.saturation, 0, 1, (v) => _setHsv(_hsv.withSaturation(v))),
            _labeledSlider('Brightness', _hsv.value, 0, 1, (v) => _setHsv(_hsv.withValue(v))),
            _labeledSlider('Opacity', _hsv.alpha, 0.1, 1, (v) => _setHsv(_hsv.withAlpha(v))),
            const SizedBox(height: 8),
            TextField(
              controller: _hex,
              decoration: InputDecoration(
                labelText: 'Hex (#RRGGBB or #AARRGGBB)',
                errorText: _error,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[#0-9a-fA-F]'))],
              onChanged: (text) {
                final c = parseHexColor(text);
                setState(() {
                  _error = c == null ? 'Invalid colour' : null;
                  if (c != null) _hsv = HSVColor.fromColor(c);
                });
              },
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Use colour')),
      ],
    );
  }

  void _submit() {
    final c = parseHexColor(_hex.text) ?? _color;
    Navigator.pop(context, c);
  }

  Widget _labeledSlider(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 84, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        Expanded(
          child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
        ),
      ],
    );
  }
}
