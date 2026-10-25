import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/bitwave_theme.dart';
import '../../library/domain/track.dart';
import '../domain/lrc_document.dart';

enum CardAspectRatio { square, portrait }

enum CardBackground { dark, gradient, blur }

class LyricsShareCard extends StatefulWidget {
  const LyricsShareCard({
    super.key,
    required this.track,
    required this.lyrics,
    required this.selectedLines,
    required this.lyricsSource,
    this.aspectRatio = CardAspectRatio.portrait,
    this.background = CardBackground.gradient,
  });

  final Track track;
  final String lyrics;
  final List<String> selectedLines;
  final String lyricsSource;
  final CardAspectRatio aspectRatio;
  final CardBackground background;

  @override
  State<LyricsShareCard> createState() => _LyricsShareCardState();
}

class _LyricsShareCardState extends State<LyricsShareCard> {
  final ScreenshotController _screenshotController = ScreenshotController();
  bool _sharing = false;

  Future<void> _shareCard() async {
    if (_sharing) return;
    setState(() => _sharing = true);

    try {
      final image = await _screenshotController.capture();
      if (image == null) return;

      final tempDir = await Directory.systemTemp.createTemp();
      final file = File('${tempDir.path}/lyrics_card.png');
      await file.writeAsBytes(image);

      if (mounted) {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(file.path)], text: 'Shared from Bitwave'),
        );
      }

      await file.delete();
      await tempDir.delete();
    } catch (e) {
      debugPrint('Error sharing card: $e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.aspectRatio == CardAspectRatio.square ? 400.0 : 360.0;
    final height = widget.aspectRatio == CardAspectRatio.square ? 400.0 : 640.0;

    return Screenshot(
      controller: _screenshotController,
      child: Container(
        width: width,
        height: height,
        decoration: _getBackgroundDecoration(),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildArtwork(),
                    const SizedBox(height: 20),
                    _buildTrackInfo(),
                    const SizedBox(height: 24),
                    _buildLyrics(),
                  ],
                ),
              ),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration _getBackgroundDecoration() {
    return switch (widget.background) {
      CardBackground.dark => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xFF1A1A1A), const Color(0xFF0D0D0D)],
        ),
      ),
      CardBackground.gradient => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF2D1B4E),
            const Color(0xFF1A1A2E),
            const Color(0xFF0D0D0D),
          ],
        ),
      ),
      CardBackground.blur => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF4A90E2).withValues(alpha: 0.3),
            const Color(0xFF9013FE).withValues(alpha: 0.3),
            const Color(0xFF0D0D0D),
          ],
        ),
      ),
    };
  }

  Widget _buildArtwork() {
    final artworkPath = widget.track.artworkPath;
    if (artworkPath != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(artworkPath),
          width: 80,
          height: 80,
          fit: BoxFit.cover,
          errorBuilder: (error, stackTrace, stack) => _fallbackArtwork(),
        ),
      );
    }
    return _fallbackArtwork();
  }

  Widget _fallbackArtwork() {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(
        Icons.music_note_rounded,
        size: 40,
        color: BitwaveColors.muted,
      ),
    );
  }

  Widget _buildTrackInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.track.title,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            height: 1.2,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          widget.track.displayArtist,
          style: const TextStyle(
            fontSize: 16,
            color: BitwaveColors.muted,
            height: 1.2,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (widget.track.displayAlbum.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            widget.track.displayAlbum,
            style: const TextStyle(
              fontSize: 14,
              color: BitwaveColors.muted,
              height: 1.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  Widget _buildLyrics() {
    if (widget.selectedLines.isEmpty) {
      return const SizedBox.shrink();
    }

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(color: Color(0xFF3A3A3A)),
          const SizedBox(height: 16),
          ...widget.selectedLines.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                line,
                style: const TextStyle(
                  fontSize: 18,
                  color: Colors.white,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Source: ${widget.lyricsSource}',
            style: const TextStyle(
              fontSize: 11,
              color: BitwaveColors.muted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: BitwaveColors.accent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'BITWAVE',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
                color: BitwaveColors.muted,
              ),
            ),
          ],
        ),
        if (_sharing)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(BitwaveColors.accent),
            ),
          )
        else
          IconButton(
            onPressed: _shareCard,
            icon: const Icon(Icons.share_rounded, color: BitwaveColors.accent),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
      ],
    );
  }
}

class LyricsShareCardSheet extends StatefulWidget {
  const LyricsShareCardSheet({
    super.key,
    required this.track,
    required this.lyrics,
    required this.lyricsSource,
  });

  final Track track;
  final String lyrics;
  final String lyricsSource;

  @override
  State<LyricsShareCardSheet> createState() => _LyricsShareCardSheetState();
}

class _LyricsShareCardSheetState extends State<LyricsShareCardSheet> {
  final List<String> _selectedLines = [];
  CardAspectRatio _aspectRatio = CardAspectRatio.portrait;
  CardBackground _background = CardBackground.gradient;
  late LrcDocument _document;

  @override
  void initState() {
    super.initState();
    _document = LrcDocument.parse(widget.lyrics);
  }

  void _toggleLine(String line) {
    setState(() {
      if (_selectedLines.contains(line)) {
        _selectedLines.remove(line);
      } else if (_selectedLines.length < 4) {
        _selectedLines.add(line);
      }
    });
  }

  List<String> _getConsecutiveLines() {
    if (_selectedLines.isEmpty) return [];
    final sortedLines =
        _document.lines.where((l) => _selectedLines.contains(l.text)).toList()
          ..sort((a, b) => a.at.compareTo(b.at));
    return sortedLines.map((l) => l.text).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Color(0xFF090A0B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildLineSelector()),
                const VerticalDivider(color: BitwaveColors.line),
                Expanded(child: _buildPreview()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Share Lyrics',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '${_selectedLines.length}/4 lines selected',
                style: const TextStyle(
                  color: BitwaveColors.muted,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              _aspectRatioToggle(),
              const SizedBox(width: 12),
              _backgroundToggle(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _aspectRatioToggle() {
    return SegmentedButton<CardAspectRatio>(
      segments: const [
        ButtonSegment(
          value: CardAspectRatio.portrait,
          label: Text('9:16', style: TextStyle(fontSize: 12)),
          icon: Icon(Icons.portrait_rounded, size: 18),
        ),
        ButtonSegment(
          value: CardAspectRatio.square,
          label: Text('1:1', style: TextStyle(fontSize: 12)),
          icon: Icon(Icons.crop_square_rounded, size: 18),
        ),
      ],
      selected: {_aspectRatio},
      onSelectionChanged: (Set<CardAspectRatio> selected) {
        setState(() => _aspectRatio = selected.first);
      },
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return BitwaveColors.accent.withValues(alpha: 0.2);
          }
          return const Color(0xFF2A2A2A);
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return BitwaveColors.accent;
          }
          return Colors.white;
        }),
      ),
    );
  }

  Widget _backgroundToggle() {
    return SegmentedButton<CardBackground>(
      segments: const [
        ButtonSegment(
          value: CardBackground.gradient,
          label: Text('Gradient', style: TextStyle(fontSize: 12)),
        ),
        ButtonSegment(
          value: CardBackground.dark,
          label: Text('Dark', style: TextStyle(fontSize: 12)),
        ),
        ButtonSegment(
          value: CardBackground.blur,
          label: Text('Blur', style: TextStyle(fontSize: 12)),
        ),
      ],
      selected: {_background},
      onSelectionChanged: (Set<CardBackground> selected) {
        setState(() => _background = selected.first);
      },
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return BitwaveColors.accent.withValues(alpha: 0.2);
          }
          return const Color(0xFF2A2A2A);
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return BitwaveColors.accent;
          }
          return Colors.white;
        }),
      ),
    );
  }

  Widget _buildLineSelector() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _document.lines.length,
      itemBuilder: (context, index) {
        final line = _document.lines[index];
        final isSelected = _selectedLines.contains(line.text);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          title: Text(
            line.text,
            style: TextStyle(
              color: isSelected ? BitwaveColors.accent : Colors.white,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            _formatDuration(line.at),
            style: const TextStyle(color: BitwaveColors.muted, fontSize: 11),
          ),
          onTap: () => _toggleLine(line.text),
          selected: isSelected,
          tileColor: isSelected
              ? BitwaveColors.accent.withValues(alpha: 0.1)
              : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        );
      },
    );
  }

  Widget _buildPreview() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: LyricsShareCard(
          track: widget.track,
          lyrics: widget.lyrics,
          selectedLines: _getConsecutiveLines(),
          lyricsSource: widget.lyricsSource,
          aspectRatio: _aspectRatio,
          background: _background,
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
