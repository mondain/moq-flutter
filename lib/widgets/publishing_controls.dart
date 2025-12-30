import 'package:flutter/material.dart';

/// Publishing controls bar with mute and stop buttons
class PublishingControls extends StatelessWidget {
  final bool isAudioMuted;
  final int videoFrames;
  final int audioFrames;
  final VoidCallback onMuteToggle;
  final VoidCallback onStop;

  const PublishingControls({
    super.key,
    required this.isAudioMuted,
    required this.videoFrames,
    required this.audioFrames,
    required this.onMuteToggle,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Mute button
          IconButton(
            onPressed: onMuteToggle,
            icon: Icon(
              isAudioMuted ? Icons.mic_off : Icons.mic,
              color: isAudioMuted ? Colors.red : Colors.white,
            ),
            tooltip: isAudioMuted ? 'Unmute audio' : 'Mute audio',
          ),
          const SizedBox(width: 8),
          // Status text
          Expanded(
            child: Text(
              '$videoFrames video / $audioFrames audio frames',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          // Stop button
          TextButton.icon(
            onPressed: onStop,
            icon: const Icon(Icons.stop, color: Colors.red),
            label: const Text('Stop', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
