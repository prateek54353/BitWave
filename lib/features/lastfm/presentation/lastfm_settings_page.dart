import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme/bitwave_theme.dart';
import '../data/lastfm_scrobbler.dart';

class LastFmSettingsPage extends StatefulWidget {
  const LastFmSettingsPage({super.key, required this.scrobbler});

  final LastFmScrobbler scrobbler;

  @override
  State<LastFmSettingsPage> createState() => _LastFmSettingsPageState();
}

class _LastFmSettingsPageState extends State<LastFmSettingsPage> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startAuthorization() => _run(() async {
    final uri = await widget.scrobbler.beginAuthorization();
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const LastFmException(
        'Could not open the Last.fm authorization page.',
      );
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Authorize Bitwave'),
        content: const Text(
          'Approve Bitwave on Last.fm in your browser, then return here and tap “Finish connection”.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  });

  Future<void> _finishAuthorization() => _run(() async {
    await widget.scrobbler.completeAuthorization();
    if (mounted) setState(() {});
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Last.fm scrobbling')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Icon(
          Icons.radio_button_checked_rounded,
          size: 48,
          color: BitwaveColors.accent,
        ),
        const SizedBox(height: 14),
        Text(
          widget.scrobbler.connected
              ? 'Connected as ${widget.scrobbler.username}'
              : 'Connect Bitwave to Last.fm',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'Bitwave submits your currently playing track and scrobbles eligible listens. Local playback works without a network connection.',
          style: TextStyle(color: BitwaveColors.muted),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 24),
        if (!widget.scrobbler.connected) ...[
          FilledButton.icon(
            onPressed: _busy ? null : _startAuthorization,
            icon: const Icon(Icons.open_in_browser_rounded),
            label: const Text('Connect to Last.fm'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _finishAuthorization,
            child: const Text('I’ve approved access · Finish connection'),
          ),
        ] else ...[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enable scrobbling'),
            subtitle: const Text('Send now-playing updates and eligible plays'),
            value: widget.scrobbler.enabled,
            onChanged: _busy
                ? null
                : (value) => _run(() => widget.scrobbler.setEnabled(value)),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _run(widget.scrobbler.disconnect),
            icon: const Icon(Icons.link_off_rounded),
            label: const Text('Disconnect Last.fm'),
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: 22),
        const Text(
          'Bitwave never asks for your Last.fm password. Authorization happens on Last.fm and can be revoked from your Last.fm account settings.',
          style: TextStyle(color: BitwaveColors.muted, fontSize: 12),
        ),
      ],
    ),
  );
}
