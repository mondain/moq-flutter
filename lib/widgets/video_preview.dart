import 'dart:ui' as ui;
import 'package:camera/camera.dart' show CameraPreview;
import 'package:flutter/material.dart';
import 'package:sizer/sizer.dart';
import '../moq/media/camera_capture.dart';
import '../moq/media/linux_capture.dart';

/// Video preview widget supporting both mobile camera and Linux FFmpeg capture
class VideoPreview extends StatelessWidget {
  final VideoCapture? videoCapture;
  final ui.Image? linuxPreviewImage;
  final int publishedFrames;

  const VideoPreview({
    super.key,
    required this.videoCapture,
    this.linuxPreviewImage,
    this.publishedFrames = 0,
  });

  @override
  Widget build(BuildContext context) {
    // Camera preview for mobile platforms
    if (videoCapture is CameraCapture &&
        (videoCapture as CameraCapture).cameraController?.value.isInitialized == true) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: CameraPreview((videoCapture as CameraCapture).cameraController!),
      );
    }

    // Linux capture with FFmpeg
    if (videoCapture is LinuxVideoCapture) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black87,
          child: linuxPreviewImage != null
              ? RawImage(
                  image: linuxPreviewImage,
                  fit: BoxFit.contain,
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                      ),
                      SizedBox(height: 1.h),
                      Text(
                        'Starting webcam...',
                        style: TextStyle(color: Colors.white70, fontSize: 12.sp),
                      ),
                      SizedBox(height: 0.5.h),
                      Text(
                        '$publishedFrames frames',
                        style: TextStyle(color: Colors.white54, fontSize: 10.sp),
                      ),
                    ],
                  ),
                ),
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
              Icon(Icons.videocam_off, size: 6.h, color: Colors.white54),
              SizedBox(height: 1.h),
              Text(
                videoCapture == null ? 'Camera not available' : 'Camera initializing...',
                style: TextStyle(color: Colors.white54, fontSize: 12.sp),
              ),
              if (videoCapture == null) ...[
                SizedBox(height: 0.5.h),
                Text(
                  '(Publishing test frames)',
                  style: TextStyle(color: Colors.white38, fontSize: 10.sp),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
