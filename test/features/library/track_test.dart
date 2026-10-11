import 'package:bitwave/features/library/domain/track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('track metadata survives database map conversion', () {
    final original = Track(
      id: 'track-1',
      path: '/music/example.flac',
      title: 'Example',
      artist: 'Artist',
      album: 'Album',
      albumArtist: 'Album Artist',
      genre: 'Jazz',
      durationMs: 215000,
      format: 'FLAC',
      fileSize: 123456,
      modifiedMs: 1700000000000,
      year: 2024,
      trackNumber: 3,
      sampleRate: 96000,
      bitrate: 1200,
      favorite: true,
    );

    final restored = Track.fromMap(original.toMap());

    expect(restored.id, original.id);
    expect(restored.path, original.path);
    expect(restored.title, original.title);
    expect(restored.albumArtist, original.albumArtist);
    expect(restored.genre, original.genre);
    expect(restored.duration, original.duration);
    expect(restored.sampleRate, original.sampleRate);
    expect(restored.favorite, isTrue);
  });

  test('missing artist and album have readable display labels', () {
    const track = Track(
      id: 'track-2',
      path: '/music/untagged.mp3',
      title: 'untagged',
      artist: '',
      album: '',
      durationMs: 0,
      format: 'MP3',
      fileSize: 32,
      modifiedMs: 1,
    );
    expect(track.displayArtist, 'Unknown artist');
    expect(track.displayAlbum, 'Unknown album');
  });

  test('artwork override and crop preferences survive persistence mapping', () {
    final original = Track(
      id: 'art-track',
      path: '/music/art.mp3',
      title: 'Artwork',
      artist: 'Artist',
      album: 'Album',
      durationMs: 1000,
      format: 'MP3',
      fileSize: 100,
      modifiedMs: 1,
      customArtworkPath: '/private/artwork/cover.mp4',
      providerArtworkUrl: null,
      providerArtworkId: null,
      artworkAspectRatio: .75,
      artworkFocusX: .3,
      artworkFocusY: -.2,
      artworkFit: 'crop',
      animatedArtwork: true,
      artworkPosterPath: '/private/artwork/cover-poster.jpg',
    );

    final restored = Track.fromMap(original.toMap());

    expect(restored.customArtworkPath, original.customArtworkPath);
    expect(restored.artworkAspectRatio, .75);
    expect(restored.artworkFocusX, .3);
    expect(restored.artworkFocusY, -.2);
    expect(restored.animatedArtwork, isTrue);
    expect(restored.artworkPath, original.artworkPosterPath);
    expect(restored.motionArtworkPath, original.customArtworkPath);
  });

  test(
    'manually linked catalog art takes precedence over embedded artwork',
    () {
      const track = Track(
        id: 'catalog-art',
        path: '/music/catalog.mp3',
        title: 'Catalog',
        artist: 'Artist',
        album: 'Album',
        durationMs: 1000,
        format: 'MP3',
        fileSize: 100,
        modifiedMs: 1,
        embeddedArtworkPath: '/private/artwork/embedded.jpg',
        providerArtworkUrl: 'https://example.invalid/cover.jpg',
      );

      expect(track.artworkPath, isNull);
      expect(track.providerArtworkUrl, contains('cover.jpg'));
    },
  );
}
