import 'package:flutter/material.dart';

import '../features/library/data/library_repository.dart';
import '../features/player/data/bitwave_audio_handler.dart';
import '../features/library/presentation/library_screen.dart';
import 'theme/bitwave_theme.dart';

class BitwaveApp extends StatelessWidget {
  const BitwaveApp({super.key, required this.library, required this.audio});
  final LibraryRepository library;
  final BitwaveAudioHandler audio;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Bitwave',
    debugShowCheckedModeBanner: false,
    theme: bitwaveTheme(),
    home: LibraryScreen(library: library, audio: audio),
  );
}
