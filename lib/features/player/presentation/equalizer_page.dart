import 'package:flutter/material.dart';

import '../../../app/theme/bitwave_theme.dart';
import '../data/equalizer.dart';

class EqualizerPage extends StatefulWidget {
  const EqualizerPage({
    super.key,
    required this.equalizer,
    required this.onChanged,
  });

  final Equalizer equalizer;
  final VoidCallback onChanged;

  @override
  State<EqualizerPage> createState() => _EqualizerPageState();
}

class _EqualizerPageState extends State<EqualizerPage> {
  late List<double> _bands;

  @override
  void initState() {
    super.initState();
    _bands = List.from(widget.equalizer.bands);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090A0B),
      appBar: AppBar(
        title: const Text('Equalizer'),
        actions: [
          Switch(
            value: widget.equalizer.enabled,
            onChanged: (value) async {
              await widget.equalizer.setEnabled(value);
              widget.onChanged();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '10-Band Equalizer',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            widget.equalizer.enabled
                ? 'Equalizer is enabled'
                : 'Equalizer is disabled',
            style: const TextStyle(color: BitwaveColors.muted, fontSize: 14),
          ),
          const SizedBox(height: 24),
          const Text(
            'Presets',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          _presetButton('Flat', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
          _presetButton('Bass Boost', [3, 3, 2, 1, 0, 0, 0, 0, 0, 0]),
          _presetButton('Treble Boost', [0, 0, 0, 0, 0, 0, 1, 2, 3, 3]),
          _presetButton('Vocal', [0, 0, 0, 1, 2, 3, 2, 1, 0, 0]),
          _presetButton('Rock', [3, 2, 1, 0, 0, 0, 0, 1, 2, 3]),
          const SizedBox(height: 32),
          const Text(
            'Frequency Bands',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          ...List.generate(10, (index) => _bandSlider(index)),
          const SizedBox(height: 32),
          Center(
            child: OutlinedButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Reset to Flat'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _presetButton(String label, List<double> values) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton(
        onPressed: () => _applyPreset(values),
        child: Text(label),
      ),
    );
  }

  Widget _bandSlider(int index) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                Equalizer.bandLabels[index],
                style: const TextStyle(
                  fontSize: 13,
                  color: BitwaveColors.muted,
                ),
              ),
              Text(
                '${_bands[index].toStringAsFixed(1)} dB',
                style: const TextStyle(
                  fontSize: 13,
                  color: BitwaveColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
              activeTrackColor: BitwaveColors.accent,
              inactiveTrackColor: const Color(0xFF2A2A2A),
              thumbColor: BitwaveColors.accent,
              overlayColor: BitwaveColors.accent.withValues(alpha: 0.2),
            ),
            child: Slider(
              value: _bands[index],
              min: -12.0,
              max: 12.0,
              divisions: 24,
              onChanged: widget.equalizer.enabled
                  ? (value) {
                      setState(() {
                        _bands[index] = value;
                      });
                      widget.equalizer.setBands(_bands);
                    }
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyPreset(List<double> values) async {
    _bands = List.from(values);
    await widget.equalizer.setBands(_bands);
    widget.onChanged();
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    _bands = List.filled(10, 0.0);
    await widget.equalizer.setBands(_bands);
    widget.onChanged();
    if (mounted) setState(() {});
  }
}
