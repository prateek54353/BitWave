import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/database/library_database.dart';
import 'features/library/data/library_repository.dart';
import 'features/player/data/bitwave_audio_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = LibraryDatabase();
  final library = LibraryRepository(database);
  final audio = await AudioService.init(
    builder: () => BitwaveAudioHandler(db: database),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'org.bitwave.dev.audio',
      androidNotificationChannelName: 'Bitwave playback',
      androidNotificationIcon: 'drawable/ic_stat_bitwave',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  runApp(BitwaveApp(library: library, audio: audio));
}
