import 'dart:io';
import 'dart:typed_data';

/// Parses audio file headers to extract codec, bit depth, and channels.
/// Used to supplement audio_metadata_reader which may not provide these fields.
class AudioFormatParser {
  static ({String? codec, int? bitDepth, int? channels, bool isLossless})
  parseFile(File file) {
    final bytes = file.readAsBytesSync();
    final ext = file.path.split('.').last.toLowerCase();

    return switch (ext) {
      'flac' => _parseFlac(bytes),
      'wav' => _parseWav(bytes),
      'aiff' => _parseAiff(bytes),
      'ape' => _parseApe(bytes),
      'm4a' || 'aac' => _parseMp4(bytes),
      'ogg' || 'opus' => _parseOgg(bytes),
      _ => (codec: null, bitDepth: null, channels: null, isLossless: false),
    };
  }

  static ({String? codec, int? bitDepth, int? channels, bool isLossless})
  _parseFlac(Uint8List bytes) {
    if (bytes.length < 42) {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final signature = String.fromCharCodes(bytes.sublist(0, 4));
    if (signature != 'fLaC') {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final blockHeader = bytes[4];
    final blockSize = _readInt24(bytes, 5);
    if (blockSize > bytes.length - 8) {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    if ((blockHeader & 0x7F) != 0) {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final channels = (bytes[22] >> 1) & 0x07;
    final bitDepth = ((bytes[22] & 0x01) << 4) + ((bytes[23] >> 4) & 0x0F) + 1;
    return (
      codec: 'FLAC',
      bitDepth: bitDepth,
      channels: channels + 1,
      isLossless: true,
    );
  }

  static ({String? codec, int? bitDepth, int? channels, bool isLossless})
  _parseWav(Uint8List bytes) {
    if (bytes.length < 44) {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final riff = String.fromCharCodes(bytes.sublist(0, 4));
    if (riff != 'RIFF') {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final wave = String.fromCharCodes(bytes.sublist(8, 12));
    if (wave != 'WAVE') {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final fmt = String.fromCharCodes(bytes.sublist(12, 16));
    if (fmt != 'fmt ') {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final audioFormat = _readInt16(bytes, 20);
    final channels = _readInt16(bytes, 22);
    final bitDepth = _readInt16(bytes, 34);
    final isLossless = audioFormat == 1;
    final codec = isLossless ? 'PCM' : _wavFormatToString(audioFormat);
    return (
      codec: codec,
      bitDepth: bitDepth,
      channels: channels,
      isLossless: isLossless,
    );
  }

  static ({String? codec, int? bitDepth, int? channels, bool isLossless})
  _parseAiff(Uint8List bytes) {
    if (bytes.length < 54) {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final form = String.fromCharCodes(bytes.sublist(0, 4));
    if (form != 'FORM') {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final aiff = String.fromCharCodes(bytes.sublist(8, 12));
    if (aiff != 'AIFF' && aiff != 'AIFC') {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    var offset = 12;
    while (offset < bytes.length - 8) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = _readInt32BigEndian(bytes, offset + 4);
      if (chunkId == 'COMM') {
        final channels = _readInt16BigEndian(bytes, offset + 8);
        final bitDepth = _readInt16BigEndian(bytes, offset + 14);
        if (aiff == 'AIFC') {
          final compressionType = String.fromCharCodes(
            bytes.sublist(offset + 26, offset + 30),
          );
          final isLossless =
              compressionType == 'NONE' || compressionType == 'none';
          return (
            codec: isLossless ? 'PCM' : compressionType,
            bitDepth: bitDepth,
            channels: channels,
            isLossless: isLossless,
          );
        }
        return (
          codec: 'PCM',
          bitDepth: bitDepth,
          channels: channels,
          isLossless: true,
        );
      }
      offset += 8 + chunkSize;
      if (chunkSize % 2 != 0) offset++;
    }
    return (codec: null, bitDepth: null, channels: null, isLossless: false);
  }

  static ({String? codec, int? bitDepth, int? channels, bool isLossless})
  _parseApe(Uint8List bytes) {
    if (bytes.length < 32) {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final signature = String.fromCharCodes(bytes.sublist(0, 4));
    if (signature != 'MAC ') {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    return (codec: 'APE', bitDepth: null, channels: null, isLossless: true);
  }

  static ({String? codec, int? bitDepth, int? channels, bool isLossless})
  _parseMp4(Uint8List bytes) {
    if (bytes.length < 12) {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    var offset = 0;
    while (offset < bytes.length - 8) {
      final boxSize = _readInt32BigEndian(bytes, offset);
      final boxType = String.fromCharCodes(
        bytes.sublist(offset + 4, offset + 8),
      );
      if (boxType == 'moov' ||
          boxType == 'trak' ||
          boxType == 'mdia' ||
          boxType == 'minf' ||
          boxType == 'stbl' ||
          boxType == 'stsd') {
        offset += 8;
        continue;
      }
      if (boxType == 'mp4a') {
        final isAlac =
            bytes.sublist(offset + 16, offset + 20).join(',') == 'alac';
        return (
          codec: isAlac ? 'ALAC' : 'AAC',
          bitDepth: isAlac ? 16 : null,
          channels: null,
          isLossless: isAlac,
        );
      }
      if (boxSize < 8) break;
      offset += boxSize;
    }
    return (codec: 'AAC', bitDepth: null, channels: null, isLossless: false);
  }

  static ({String? codec, int? bitDepth, int? channels, bool isLossless})
  _parseOgg(Uint8List bytes) {
    if (bytes.length < 28) {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final oggS = String.fromCharCodes(bytes.sublist(0, 4));
    if (oggS != 'OggS') {
      return (codec: null, bitDepth: null, channels: null, isLossless: false);
    }
    final opusHead = String.fromCharCodes(bytes.sublist(28, 36));
    if (opusHead == 'OpusHead') {
      final channels = bytes[35];
      return (
        codec: 'Opus',
        bitDepth: null,
        channels: channels,
        isLossless: false,
      );
    }
    return (codec: 'Vorbis', bitDepth: null, channels: null, isLossless: false);
  }

  static int _readInt16(Uint8List bytes, int offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  static int _readInt24(Uint8List bytes, int offset) {
    return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
  }

  static int _readInt16BigEndian(Uint8List bytes, int offset) {
    return (bytes[offset] << 8) | bytes[offset + 1];
  }

  static int _readInt32BigEndian(Uint8List bytes, int offset) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static String _wavFormatToString(int format) {
    return switch (format) {
      1 => 'PCM',
      3 => 'IEEE Float',
      6 => 'A-law',
      7 => 'μ-law',
      0x11 => 'IMA ADPCM',
      0x55 => 'MP3',
      0x2000 => 'AC-3',
      _ => 'Unknown',
    };
  }
}
