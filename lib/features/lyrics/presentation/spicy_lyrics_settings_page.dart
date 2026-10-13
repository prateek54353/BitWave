import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../app/theme/bitwave_theme.dart';

class SpicyLyricsSettingsPage extends StatefulWidget {
  const SpicyLyricsSettingsPage({super.key});

  @override
  State<SpicyLyricsSettingsPage> createState() =>
      _SpicyLyricsSettingsPageState();
}

class _SpicyLyricsSettingsPageState extends State<SpicyLyricsSettingsPage> {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'spicy_lyrics_api_key';
  final _controller = TextEditingController();
  bool _loading = true;
  bool _obscure = true;
  bool _hasKey = false;

  @override
  void initState() {
    super.initState();
    _loadKey();
  }

  Future<void> _loadKey() async {
    final value = await _storage.read(key: _keyName);
    if (!mounted) return;
    setState(() {
      _hasKey = value?.isNotEmpty == true;
      _controller.text = value ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      await _storage.delete(key: _keyName);
      if (mounted) setState(() => _hasKey = false);
      _message('Spicy Lyrics API key removed.');
      return;
    }
    await _storage.write(key: _keyName, value: value);
    if (mounted) setState(() => _hasKey = true);
    _message('Spicy Lyrics API key saved securely.');
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Spicy Lyrics')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(22),
            children: [
              const Icon(
                Icons.lyrics_rounded,
                size: 46,
                color: BitwaveColors.accent,
              ),
              const SizedBox(height: 16),
              Text(
                'Word-synced lyrics',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Add your Spicy Lyrics API key to request syllable and word timed lyrics. Keys are stored in the device secure storage.',
                style: TextStyle(color: BitwaveColors.muted),
              ),
              const SizedBox(height: 22),
              TextField(
                controller: _controller,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'API key',
                  hintText: 'sl_pk_…',
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Show key' : 'Hide key',
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(onPressed: _save, child: const Text('Save API key')),
              if (_hasKey)
                TextButton(
                  onPressed: () {
                    _controller.clear();
                    _save();
                  },
                  child: const Text('Remove API key'),
                ),
              const SizedBox(height: 14),
              const Text(
                'Use a publishable client key (sl_pk_…), not a secret server key (sl_sk_…). In the Spicy Lyrics dashboard, enable native clients that send no Origin header. A Spotify track ID or track link is required when fetching lyrics.',
                style: TextStyle(color: BitwaveColors.muted, fontSize: 12),
              ),
            ],
          ),
  );
}
