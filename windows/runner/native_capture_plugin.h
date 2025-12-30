#ifndef NATIVE_CAPTURE_PLUGIN_H_
#define NATIVE_CAPTURE_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <wmcodecdsp.h>
#include <d3d11.h>
#include <dxgi.h>

#include <wrl/client.h>
#include <memory>
#include <string>
#include <vector>
#include <mutex>
#include <atomic>
#include <thread>
#include <functional>
#include <algorithm>
#include <cctype>

namespace moq_flutter {

using Microsoft::WRL::ComPtr;

// Forward declaration
class NativeCapturePlugin;

// Camera information structure
struct CameraInfo {
  std::string id;
  std::string name;
  std::string position;
};

// Audio stream handler for event channel
class AudioStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  AudioStreamHandler() = default;
  virtual ~AudioStreamHandler() = default;

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) override;

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancelInternal(
      const flutter::EncodableValue* arguments) override;

  void SendAudioData(const std::vector<uint8_t>& data, int sample_rate,
                     int channels, int bits_per_sample, int64_t timestamp_ms);

 private:
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::mutex event_sink_mutex_;
};

// Video stream handler for event channel
class VideoStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  VideoStreamHandler() = default;
  virtual ~VideoStreamHandler() = default;

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) override;

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancelInternal(
      const flutter::EncodableValue* arguments) override;

  void SendVideoFrame(const std::vector<uint8_t>& data, int width, int height,
                      const std::string& format, int bytes_per_row, int64_t timestamp_ms);

 private:
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::mutex event_sink_mutex_;
};

// Main plugin class
class NativeCapturePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  NativeCapturePlugin(flutter::PluginRegistrarWindows* registrar);
  virtual ~NativeCapturePlugin();

  // Disallow copy and assign
  NativeCapturePlugin(const NativeCapturePlugin&) = delete;
  NativeCapturePlugin& operator=(const NativeCapturePlugin&) = delete;

 private:
  // Method call handler
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Audio methods
  void InitializeAudio(const flutter::EncodableMap& args,
                       std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StartAudioCapture(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopAudioCapture(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Video methods
  void InitializeVideo(const flutter::EncodableMap& args,
                       std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StartVideoCapture(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StopVideoCapture(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void GetAvailableCameras(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void SelectCamera(const flutter::EncodableMap& args,
                    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Permission methods (Windows doesn't require explicit permissions like macOS/iOS)
  void HasCameraPermission(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HasMicrophonePermission(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void RequestCameraPermission(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void RequestMicrophonePermission(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Internal capture methods
  bool SetupAudioCapture();
  void TeardownAudioCapture();
  bool SetupVideoCapture();
  void TeardownVideoCapture();

  // Capture thread functions
  void AudioCaptureLoop();
  void VideoCaptureLoop();

  // Enumerate devices
  std::vector<CameraInfo> EnumerateCameras();
  ComPtr<IMFActivate> FindAudioDevice();
  ComPtr<IMFActivate> FindVideoDevice(const std::string& device_id = "");

  // Stream handlers
  std::shared_ptr<AudioStreamHandler> audio_stream_handler_;
  std::shared_ptr<VideoStreamHandler> video_stream_handler_;

  // Media Foundation objects
  ComPtr<IMFMediaSource> audio_source_;
  ComPtr<IMFMediaSource> video_source_;
  ComPtr<IMFSourceReader> audio_reader_;
  ComPtr<IMFSourceReader> video_reader_;

  // Configuration
  int audio_sample_rate_ = 48000;
  int audio_channels_ = 2;
  int audio_bits_per_sample_ = 16;
  int video_width_ = 1280;
  int video_height_ = 720;
  int video_frame_rate_ = 30;
  std::string selected_camera_id_;

  // State
  std::atomic<bool> audio_capturing_{false};
  std::atomic<bool> video_capturing_{false};
  std::atomic<bool> mf_initialized_{false};

  // Capture threads
  std::unique_ptr<std::thread> audio_thread_;
  std::unique_ptr<std::thread> video_thread_;

  // Timestamps
  int64_t audio_start_timestamp_ = -1;
  int64_t video_start_timestamp_ = -1;

  // Mutex for thread safety
  std::mutex audio_mutex_;
  std::mutex video_mutex_;
};

}  // namespace moq_flutter

#endif  // NATIVE_CAPTURE_PLUGIN_H_
