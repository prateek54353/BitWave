import 'package:flutter/services.dart';

class Equalizer {
  static const _channel = MethodChannel('org.bitwave.dev/equalizer');

  bool _enabled = false;
  List<double> _bands = List.filled(10, 0.0);

  bool get enabled => _enabled;
  List<double> get bands => List.unmodifiable(_bands);

  String? _lastError;
  String? get lastError => _lastError;

  Future<void> setEnabled(bool value) async {
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': value});
      _enabled = value;
      _lastError = null;
    } on PlatformException catch (e) {
      _lastError = e.message ?? 'Equalizer is not available on this platform.';
      _enabled = false;
      rethrow;
    } on MissingPluginException {
      _lastError = 'Equalizer is not available on this platform.';
      _enabled = false;
      rethrow;
    }
  }

  Future<void> setBands(List<double> bands) async {
    if (bands.length != 10) return;
    _bands = List.from(bands);
    try {
      await _channel.invokeMethod('setBands', {'bands': bands});
      _lastError = null;
    } on PlatformException catch (e) {
      _lastError = e.message ?? 'Could not apply equalizer settings.';
      rethrow;
    } on MissingPluginException {
      _lastError = 'Equalizer is not available on this platform.';
      rethrow;
    }
  }

  Future<void> load() async {
    try {
      final result = await _channel.invokeMethod('getBands');
      if (result is Map) {
        _enabled = result['enabled'] as bool? ?? false;
        final bandValues = result['bands'] as List?;
        if (bandValues != null && bandValues.length == 10) {
          _bands = bandValues.map((e) => (e as num).toDouble()).toList();
        }
      }
    } on PlatformException catch (e) {
      _lastError = e.message ?? 'Equalizer is not available on this platform.';
    } on MissingPluginException {
      _lastError = 'Equalizer is not available on this platform.';
    }
  }

  static const List<String> bandLabels = [
    '32 Hz',
    '64 Hz',
    '125 Hz',
    '250 Hz',
    '500 Hz',
    '1 kHz',
    '2 kHz',
    '4 kHz',
    '8 kHz',
    '16 kHz',
  ];

  static const List<double> bandFrequencies = [
    32.0,
    64.0,
    125.0,
    250.0,
    500.0,
    1000.0,
    2000.0,
    4000.0,
    8000.0,
    16000.0,
  ];
}
