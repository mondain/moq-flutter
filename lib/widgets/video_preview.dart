import 'package:flutter/foundation.dart';
import 'dart:ui' as ui;
import 'package:camera/camera.dart' show CameraPreview;
import 'package:flutter/material.dart';
import '../moq/media/camera_capture.dart';
import '../moq/media/linux_capture.dart';

/// Video preview widget supporting both mobile camera and Linux FFmpeg capture
class VideoPreview extends StatelessWidget {
  final VideoCapture? videoCapture;
  final ValueListenable<ui.Image?>? linuxPreviewImageListenable;
  final int publishedFrames;
  final bool isStopping;

  const VideoPreview({
    super.key,
    required this.videoCapture,
    this.linuxPreviewImageListenable,
    this.publishedFrames = 0,
    this.isStopping = false,
  });

  @override
  Widget build(BuildContext context) {
    // Camera preview for mobile platforms
    if (videoCapture is CameraCapture &&
        (videoCapture as CameraCapture).cameraController?.value.isInitialized ==
            true) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: CameraPreview((videoCapture as CameraCapture).cameraController!),
      );
    }

    // Linux capture with FFmpeg
    if (videoCapture is LinuxVideoCapture) {
      final previewListenable = linuxPreviewImageListenable;
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: RepaintBoundary(
          child: previewListenable == null
              ? _buildLinuxPreview(null)
              : ValueListenableBuilder<ui.Image?>(
                  valueListenable: previewListenable,
                  builder: (context, linuxPreviewImage, _) {
                    return _buildLinuxPreview(linuxPreviewImage);
                  },
                ),
        ),
      );
    }

    if (videoCapture is NativeVideoCapture) {
      final nativeCapture = videoCapture as NativeVideoCapture;
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: ValueListenableBuilder<Uint8List?>(
          valueListenable: nativeCapture.previewJpegListenable,
          builder: (context, previewBytes, _) {
            if (previewBytes != null) {
              return ColoredBox(
                color: Colors.black87,
                child: Image.memory(
                  previewBytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                ),
              );
            }

            return const ColoredBox(
              color: Colors.black87,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Starting Android camera preview...',
                      style: TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    // Fallback - camera not available
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.black87,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off, size: 48, color: Colors.white54),
              const SizedBox(height: 8),
              Text(
                isStopping
                    ? 'Stopping publisher...'
                    : videoCapture == null
                    ? 'Camera not available'
                    : 'Camera initializing...',
                style: const TextStyle(color: Colors.white54, fontSize: 15),
              ),
              if (videoCapture == null && !isStopping) ...[
                const SizedBox(height: 4),
                const Text(
                  '(Publishing test frames)',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLinuxPreview(ui.Image? linuxPreviewImage) {
    return Container(
      color: Colors.black87,
      child: linuxPreviewImage != null
          ? RawImage(
              image: linuxPreviewImage,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.low,
            )
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Starting webcam...',
                    style: TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                  SizedBox(height: 4),
                ],
              ),
            ),
    );
  }
}
