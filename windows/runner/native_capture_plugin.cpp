#include "native_capture_plugin.h"

#include <shlwapi.h>
#include <propvarutil.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>

#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "shlwapi.lib")

namespace moq_flutter {

// Helper to convert wide string to UTF-8
static std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                        static_cast<int>(wide.length()),
                                        nullptr, 0, nullptr, nullptr);
  std::string result(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                      static_cast<int>(wide.length()),
                      &result[0], size_needed, nullptr, nullptr);
  return result;
}

// Helper to convert UTF-8 to wide string
static std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int size_needed = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                        static_cast<int>(utf8.length()),
                                        nullptr, 0);
  std::wstring result(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                      static_cast<int>(utf8.length()),
                      &result[0], size_needed);
  return result;
}

// AudioStreamHandler implementation
std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
AudioStreamHandler::OnListenInternal(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  std::lock_guard<std::mutex> lock(event_sink_mutex_);
  event_sink_ = std::move(events);
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
AudioStreamHandler::OnCancelInternal(const flutter::EncodableValue* arguments) {
  std::lock_guard<std::mutex> lock(event_sink_mutex_);
  event_sink_ = nullptr;
  return nullptr;
}

void AudioStreamHandler::SendAudioData(const std::vector<uint8_t>& data,
                                        int sample_rate, int channels,
                                        int bits_per_sample,
                                        int64_t timestamp_ms) {
  std::lock_guard<std::mutex> lock(event_sink_mutex_);
  if (!event_sink_) return;

  flutter::EncodableMap event_data;
  event_data[flutter::EncodableValue("data")] = flutter::EncodableValue(data);
  event_data[flutter::EncodableValue("sampleRate")] = flutter::EncodableValue(sample_rate);
  event_data[flutter::EncodableValue("channels")] = flutter::EncodableValue(channels);
  event_data[flutter::EncodableValue("bitsPerSample")] = flutter::EncodableValue(bits_per_sample);
  event_data[flutter::EncodableValue("timestampMs")] = flutter::EncodableValue(timestamp_ms);

  event_sink_->Success(flutter::EncodableValue(event_data));
}

// VideoStreamHandler implementation
std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
VideoStreamHandler::OnListenInternal(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  std::lock_guard<std::mutex> lock(event_sink_mutex_);
  event_sink_ = std::move(events);
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
VideoStreamHandler::OnCancelInternal(const flutter::EncodableValue* arguments) {
  std::lock_guard<std::mutex> lock(event_sink_mutex_);
  event_sink_ = nullptr;
  return nullptr;
}

void VideoStreamHandler::SendVideoFrame(const std::vector<uint8_t>& data,
                                         int width, int height,
                                         const std::string& format,
                                         int bytes_per_row,
                                         int64_t timestamp_ms) {
  std::lock_guard<std::mutex> lock(event_sink_mutex_);
  if (!event_sink_) return;

  flutter::EncodableMap event_data;
  event_data[flutter::EncodableValue("data")] = flutter::EncodableValue(data);
  event_data[flutter::EncodableValue("width")] = flutter::EncodableValue(width);
  event_data[flutter::EncodableValue("height")] = flutter::EncodableValue(height);
  event_data[flutter::EncodableValue("format")] = flutter::EncodableValue(format);
  event_data[flutter::EncodableValue("bytesPerRow")] = flutter::EncodableValue(bytes_per_row);
  event_data[flutter::EncodableValue("timestampMs")] = flutter::EncodableValue(timestamp_ms);

  event_sink_->Success(flutter::EncodableValue(event_data));
}

// NativeCapturePlugin implementation
void NativeCapturePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<NativeCapturePlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

NativeCapturePlugin::NativeCapturePlugin(flutter::PluginRegistrarWindows* registrar) {
  // Initialize COM
  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (SUCCEEDED(hr) || hr == S_FALSE || hr == RPC_E_CHANGED_MODE) {
    // Initialize Media Foundation
    hr = MFStartup(MF_VERSION);
    if (SUCCEEDED(hr)) {
      mf_initialized_ = true;
    }
  }

  // Create stream handlers
  audio_stream_handler_ = std::make_shared<AudioStreamHandler>();
  video_stream_handler_ = std::make_shared<VideoStreamHandler>();

  // Method channel
  auto method_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.moq_flutter/native_capture",
      &flutter::StandardMethodCodec::GetInstance());

  method_channel->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  // Audio event channel
  auto audio_event_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.moq_flutter/audio_samples",
      &flutter::StandardMethodCodec::GetInstance());
  audio_event_channel->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            return audio_stream_handler_->OnListenInternal(arguments, std::move(events));
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            return audio_stream_handler_->OnCancelInternal(arguments);
          }));

  // Video event channel
  auto video_event_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.moq_flutter/video_frames",
      &flutter::StandardMethodCodec::GetInstance());
  video_event_channel->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            return video_stream_handler_->OnListenInternal(arguments, std::move(events));
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            return video_stream_handler_->OnCancelInternal(arguments);
          }));
}

NativeCapturePlugin::~NativeCapturePlugin() {
  // Stop capture if running
  if (audio_capturing_) {
    audio_capturing_ = false;
    if (audio_thread_ && audio_thread_->joinable()) {
      audio_thread_->join();
    }
  }
  if (video_capturing_) {
    video_capturing_ = false;
    if (video_thread_ && video_thread_->joinable()) {
      video_thread_->join();
    }
  }

  TeardownAudioCapture();
  TeardownVideoCapture();

  if (mf_initialized_) {
    MFShutdown();
  }
  CoUninitialize();
}

void NativeCapturePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "initializeAudio") {
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (args) {
      InitializeAudio(*args, std::move(result));
    } else {
      result->Error("INVALID_ARGS", "Invalid arguments");
    }
  } else if (method == "startAudioCapture") {
    StartAudioCapture(std::move(result));
  } else if (method == "stopAudioCapture") {
    StopAudioCapture(std::move(result));
  } else if (method == "initializeVideo") {
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (args) {
      InitializeVideo(*args, std::move(result));
    } else {
      result->Error("INVALID_ARGS", "Invalid arguments");
    }
  } else if (method == "startVideoCapture") {
    StartVideoCapture(std::move(result));
  } else if (method == "stopVideoCapture") {
    StopVideoCapture(std::move(result));
  } else if (method == "getAvailableCameras") {
    GetAvailableCameras(std::move(result));
  } else if (method == "selectCamera") {
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (args) {
      SelectCamera(*args, std::move(result));
    } else {
      result->Error("INVALID_ARGS", "Invalid arguments");
    }
  } else if (method == "hasCameraPermission") {
    HasCameraPermission(std::move(result));
  } else if (method == "hasMicrophonePermission") {
    HasMicrophonePermission(std::move(result));
  } else if (method == "requestCameraPermission") {
    RequestCameraPermission(std::move(result));
  } else if (method == "requestMicrophonePermission") {
    RequestMicrophonePermission(std::move(result));
  } else {
    result->NotImplemented();
  }
}

void NativeCapturePlugin::InitializeAudio(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  auto sample_rate_it = args.find(flutter::EncodableValue("sampleRate"));
  if (sample_rate_it != args.end()) {
    audio_sample_rate_ = std::get<int>(sample_rate_it->second);
  }

  auto channels_it = args.find(flutter::EncodableValue("channels"));
  if (channels_it != args.end()) {
    audio_channels_ = std::get<int>(channels_it->second);
  }

  auto bits_it = args.find(flutter::EncodableValue("bitsPerSample"));
  if (bits_it != args.end()) {
    audio_bits_per_sample_ = std::get<int>(bits_it->second);
  }

  result->Success();
}

void NativeCapturePlugin::StartAudioCapture(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (audio_capturing_) {
    result->Success();
    return;
  }

  std::lock_guard<std::mutex> lock(audio_mutex_);

  if (!SetupAudioCapture()) {
    result->Error("AUDIO_ERROR", "Failed to setup audio capture");
    return;
  }

  audio_capturing_ = true;
  audio_start_timestamp_ = -1;
  audio_thread_ = std::make_unique<std::thread>(&NativeCapturePlugin::AudioCaptureLoop, this);

  result->Success();
}

void NativeCapturePlugin::StopAudioCapture(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!audio_capturing_) {
    result->Success();
    return;
  }

  audio_capturing_ = false;

  if (audio_thread_ && audio_thread_->joinable()) {
    audio_thread_->join();
    audio_thread_.reset();
  }

  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    TeardownAudioCapture();
  }

  result->Success();
}

void NativeCapturePlugin::InitializeVideo(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  auto width_it = args.find(flutter::EncodableValue("width"));
  if (width_it != args.end()) {
    video_width_ = std::get<int>(width_it->second);
  }

  auto height_it = args.find(flutter::EncodableValue("height"));
  if (height_it != args.end()) {
    video_height_ = std::get<int>(height_it->second);
  }

  auto fps_it = args.find(flutter::EncodableValue("frameRate"));
  if (fps_it != args.end()) {
    video_frame_rate_ = std::get<int>(fps_it->second);
  }

  auto camera_it = args.find(flutter::EncodableValue("cameraId"));
  if (camera_it != args.end()) {
    const auto* camera_id = std::get_if<std::string>(&camera_it->second);
    if (camera_id) {
      selected_camera_id_ = *camera_id;
    }
  }

  result->Success();
}

void NativeCapturePlugin::StartVideoCapture(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (video_capturing_) {
    result->Success();
    return;
  }

  std::lock_guard<std::mutex> lock(video_mutex_);

  if (!SetupVideoCapture()) {
    result->Error("VIDEO_ERROR", "Failed to setup video capture");
    return;
  }

  video_capturing_ = true;
  video_start_timestamp_ = -1;
  video_thread_ = std::make_unique<std::thread>(&NativeCapturePlugin::VideoCaptureLoop, this);

  result->Success();
}

void NativeCapturePlugin::StopVideoCapture(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!video_capturing_) {
    result->Success();
    return;
  }

  video_capturing_ = false;

  if (video_thread_ && video_thread_->joinable()) {
    video_thread_->join();
    video_thread_.reset();
  }

  {
    std::lock_guard<std::mutex> lock(video_mutex_);
    TeardownVideoCapture();
  }

  result->Success();
}

void NativeCapturePlugin::GetAvailableCameras(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto cameras = EnumerateCameras();

  flutter::EncodableList camera_list;
  for (const auto& camera : cameras) {
    flutter::EncodableMap camera_map;
    camera_map[flutter::EncodableValue("id")] = flutter::EncodableValue(camera.id);
    camera_map[flutter::EncodableValue("name")] = flutter::EncodableValue(camera.name);
    camera_map[flutter::EncodableValue("position")] = flutter::EncodableValue(camera.position);
    camera_list.push_back(flutter::EncodableValue(camera_map));
  }

  result->Success(flutter::EncodableValue(camera_list));
}

void NativeCapturePlugin::SelectCamera(
    const flutter::EncodableMap& args,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto camera_it = args.find(flutter::EncodableValue("cameraId"));
  if (camera_it != args.end()) {
    const auto* camera_id = std::get_if<std::string>(&camera_it->second);
    if (camera_id) {
      selected_camera_id_ = *camera_id;

      // If currently capturing, restart with new camera
      if (video_capturing_) {
        video_capturing_ = false;
        if (video_thread_ && video_thread_->joinable()) {
          video_thread_->join();
          video_thread_.reset();
        }

        {
          std::lock_guard<std::mutex> lock(video_mutex_);
          TeardownVideoCapture();
          if (!SetupVideoCapture()) {
            result->Error("CAMERA_ERROR", "Failed to switch camera");
            return;
          }
        }

        video_capturing_ = true;
        video_thread_ = std::make_unique<std::thread>(&NativeCapturePlugin::VideoCaptureLoop, this);
      }
    }
  }

  result->Success();
}

// Windows doesn't require explicit permission requests like macOS/iOS
void NativeCapturePlugin::HasCameraPermission(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // On Windows, we just check if we can enumerate video devices
  auto cameras = EnumerateCameras();
  result->Success(flutter::EncodableValue(!cameras.empty()));
}

void NativeCapturePlugin::HasMicrophonePermission(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // On Windows, check if we can find an audio device
  auto device = FindAudioDevice();
  result->Success(flutter::EncodableValue(device != nullptr));
}

void NativeCapturePlugin::RequestCameraPermission(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Windows doesn't have a permission dialog like macOS/iOS
  // The permission is implicitly granted when the app accesses the camera
  auto cameras = EnumerateCameras();
  result->Success(flutter::EncodableValue(!cameras.empty()));
}

void NativeCapturePlugin::RequestMicrophonePermission(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // Windows doesn't have a permission dialog like macOS/iOS
  auto device = FindAudioDevice();
  result->Success(flutter::EncodableValue(device != nullptr));
}

bool NativeCapturePlugin::SetupAudioCapture() {
  if (!mf_initialized_) return false;

  HRESULT hr;

  // Find audio device
  auto activate = FindAudioDevice();
  if (!activate) return false;

  // Activate the media source
  hr = activate->ActivateObject(IID_PPV_ARGS(&audio_source_));
  if (FAILED(hr)) return false;

  // Create source reader
  ComPtr<IMFAttributes> attributes;
  hr = MFCreateAttributes(&attributes, 1);
  if (FAILED(hr)) return false;

  hr = MFCreateSourceReaderFromMediaSource(audio_source_.Get(), attributes.Get(), &audio_reader_);
  if (FAILED(hr)) return false;

  // Configure output format (PCM)
  ComPtr<IMFMediaType> outputType;
  hr = MFCreateMediaType(&outputType);
  if (FAILED(hr)) return false;

  hr = outputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  if (FAILED(hr)) return false;

  hr = outputType->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  if (FAILED(hr)) return false;

  hr = outputType->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, audio_sample_rate_);
  if (FAILED(hr)) return false;

  hr = outputType->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, audio_channels_);
  if (FAILED(hr)) return false;

  hr = outputType->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, audio_bits_per_sample_);
  if (FAILED(hr)) return false;

  hr = outputType->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT,
                              audio_channels_ * (audio_bits_per_sample_ / 8));
  if (FAILED(hr)) return false;

  hr = outputType->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                              audio_sample_rate_ * audio_channels_ * (audio_bits_per_sample_ / 8));
  if (FAILED(hr)) return false;

  hr = audio_reader_->SetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
                                           nullptr, outputType.Get());
  if (FAILED(hr)) return false;

  return true;
}

void NativeCapturePlugin::TeardownAudioCapture() {
  audio_reader_.Reset();
  if (audio_source_) {
    audio_source_->Shutdown();
    audio_source_.Reset();
  }
}

bool NativeCapturePlugin::SetupVideoCapture() {
  if (!mf_initialized_) return false;

  HRESULT hr;

  // Find video device
  auto activate = FindVideoDevice(selected_camera_id_);
  if (!activate) return false;

  // Activate the media source
  hr = activate->ActivateObject(IID_PPV_ARGS(&video_source_));
  if (FAILED(hr)) return false;

  // Create source reader
  ComPtr<IMFAttributes> attributes;
  hr = MFCreateAttributes(&attributes, 1);
  if (FAILED(hr)) return false;

  hr = MFCreateSourceReaderFromMediaSource(video_source_.Get(), attributes.Get(), &video_reader_);
  if (FAILED(hr)) return false;

  // Configure output format (RGB32/BGRA)
  ComPtr<IMFMediaType> outputType;
  hr = MFCreateMediaType(&outputType);
  if (FAILED(hr)) return false;

  hr = outputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (FAILED(hr)) return false;

  // Use RGB32 (BGRA) format for easier processing
  hr = outputType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (FAILED(hr)) return false;

  hr = MFSetAttributeSize(outputType.Get(), MF_MT_FRAME_SIZE, video_width_, video_height_);
  if (FAILED(hr)) return false;

  hr = MFSetAttributeRatio(outputType.Get(), MF_MT_FRAME_RATE, video_frame_rate_, 1);
  if (FAILED(hr)) return false;

  hr = video_reader_->SetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
                                           nullptr, outputType.Get());
  if (FAILED(hr)) return false;

  return true;
}

void NativeCapturePlugin::TeardownVideoCapture() {
  video_reader_.Reset();
  if (video_source_) {
    video_source_->Shutdown();
    video_source_.Reset();
  }
}

void NativeCapturePlugin::AudioCaptureLoop() {
  // Initialize COM on this thread
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);

  while (audio_capturing_) {
    ComPtr<IMFSample> sample;
    DWORD streamFlags = 0;
    LONGLONG timestamp = 0;

    HRESULT hr;
    {
      std::lock_guard<std::mutex> lock(audio_mutex_);
      if (!audio_reader_) break;

      hr = audio_reader_->ReadSample(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
          0,
          nullptr,
          &streamFlags,
          &timestamp,
          &sample);
    }

    if (FAILED(hr) || (streamFlags & MF_SOURCE_READERF_ENDOFSTREAM)) {
      break;
    }

    if (sample) {
      // Calculate relative timestamp
      if (audio_start_timestamp_ < 0) {
        audio_start_timestamp_ = timestamp;
      }
      int64_t relativeTimestamp = (timestamp - audio_start_timestamp_) / 10000; // Convert to ms

      // Get buffer from sample
      ComPtr<IMFMediaBuffer> buffer;
      hr = sample->ConvertToContiguousBuffer(&buffer);
      if (SUCCEEDED(hr)) {
        BYTE* data = nullptr;
        DWORD length = 0;

        hr = buffer->Lock(&data, nullptr, &length);
        if (SUCCEEDED(hr)) {
          std::vector<uint8_t> audioData(data, data + length);
          buffer->Unlock();

          // Send to Flutter
          audio_stream_handler_->SendAudioData(
              audioData, audio_sample_rate_, audio_channels_,
              audio_bits_per_sample_, relativeTimestamp);
        }
      }
    }
  }

  CoUninitialize();
}

void NativeCapturePlugin::VideoCaptureLoop() {
  // Initialize COM on this thread
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);

  while (video_capturing_) {
    ComPtr<IMFSample> sample;
    DWORD streamFlags = 0;
    LONGLONG timestamp = 0;

    HRESULT hr;
    {
      std::lock_guard<std::mutex> lock(video_mutex_);
      if (!video_reader_) break;

      hr = video_reader_->ReadSample(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
          0,
          nullptr,
          &streamFlags,
          &timestamp,
          &sample);
    }

    if (FAILED(hr) || (streamFlags & MF_SOURCE_READERF_ENDOFSTREAM)) {
      break;
    }

    if (sample) {
      // Calculate relative timestamp
      if (video_start_timestamp_ < 0) {
        video_start_timestamp_ = timestamp;
      }
      int64_t relativeTimestamp = (timestamp - video_start_timestamp_) / 10000; // Convert to ms

      // Get buffer from sample
      ComPtr<IMFMediaBuffer> buffer;
      hr = sample->ConvertToContiguousBuffer(&buffer);
      if (SUCCEEDED(hr)) {
        BYTE* data = nullptr;
        DWORD length = 0;

        hr = buffer->Lock(&data, nullptr, &length);
        if (SUCCEEDED(hr)) {
          std::vector<uint8_t> videoData(data, data + length);
          buffer->Unlock();

          int bytesPerRow = video_width_ * 4; // BGRA = 4 bytes per pixel

          // Send to Flutter
          video_stream_handler_->SendVideoFrame(
              videoData, video_width_, video_height_,
              "bgra", bytesPerRow, relativeTimestamp);
        }
      }
    }
  }

  CoUninitialize();
}

std::vector<CameraInfo> NativeCapturePlugin::EnumerateCameras() {
  std::vector<CameraInfo> cameras;

  if (!mf_initialized_) return cameras;

  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 1);
  if (FAILED(hr)) return cameras;

  hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                           MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  if (FAILED(hr)) return cameras;

  IMFActivate** devices = nullptr;
  UINT32 deviceCount = 0;

  hr = MFEnumDeviceSources(attributes.Get(), &devices, &deviceCount);
  if (FAILED(hr)) return cameras;

  for (UINT32 i = 0; i < deviceCount; i++) {
    CameraInfo info;

    // Get device ID (symbolic link)
    WCHAR* symbolicLink = nullptr;
    UINT32 symbolicLinkLength = 0;
    hr = devices[i]->GetAllocatedString(
        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
        &symbolicLink, &symbolicLinkLength);
    if (SUCCEEDED(hr)) {
      info.id = WideToUtf8(symbolicLink);
      CoTaskMemFree(symbolicLink);
    }

    // Get friendly name
    WCHAR* friendlyName = nullptr;
    UINT32 friendlyNameLength = 0;
    hr = devices[i]->GetAllocatedString(
        MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,
        &friendlyName, &friendlyNameLength);
    if (SUCCEEDED(hr)) {
      info.name = WideToUtf8(friendlyName);
      CoTaskMemFree(friendlyName);
    }

    // Determine position (Windows doesn't provide this directly)
    std::string nameLower = info.name;
    std::transform(nameLower.begin(), nameLower.end(), nameLower.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (nameLower.find("front") != std::string::npos) {
      info.position = "front";
    } else if (nameLower.find("back") != std::string::npos ||
               nameLower.find("rear") != std::string::npos) {
      info.position = "back";
    } else {
      info.position = "external";
    }

    cameras.push_back(info);
    devices[i]->Release();
  }

  CoTaskMemFree(devices);
  return cameras;
}

ComPtr<IMFActivate> NativeCapturePlugin::FindAudioDevice() {
  if (!mf_initialized_) return nullptr;

  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 1);
  if (FAILED(hr)) return nullptr;

  hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                           MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_AUDCAP_GUID);
  if (FAILED(hr)) return nullptr;

  IMFActivate** devices = nullptr;
  UINT32 deviceCount = 0;

  hr = MFEnumDeviceSources(attributes.Get(), &devices, &deviceCount);
  if (FAILED(hr) || deviceCount == 0) return nullptr;

  ComPtr<IMFActivate> result;
  result.Attach(devices[0]);

  // Release other devices
  for (UINT32 i = 1; i < deviceCount; i++) {
    devices[i]->Release();
  }
  CoTaskMemFree(devices);

  return result;
}

ComPtr<IMFActivate> NativeCapturePlugin::FindVideoDevice(const std::string& device_id) {
  if (!mf_initialized_) return nullptr;

  ComPtr<IMFAttributes> attributes;
  HRESULT hr = MFCreateAttributes(&attributes, 1);
  if (FAILED(hr)) return nullptr;

  hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                           MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  if (FAILED(hr)) return nullptr;

  IMFActivate** devices = nullptr;
  UINT32 deviceCount = 0;

  hr = MFEnumDeviceSources(attributes.Get(), &devices, &deviceCount);
  if (FAILED(hr) || deviceCount == 0) return nullptr;

  ComPtr<IMFActivate> result;

  if (device_id.empty()) {
    // Use first device
    result.Attach(devices[0]);
    for (UINT32 i = 1; i < deviceCount; i++) {
      devices[i]->Release();
    }
  } else {
    // Find specific device by ID
    for (UINT32 i = 0; i < deviceCount; i++) {
      WCHAR* symbolicLink = nullptr;
      UINT32 symbolicLinkLength = 0;
      hr = devices[i]->GetAllocatedString(
          MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
          &symbolicLink, &symbolicLinkLength);

      if (SUCCEEDED(hr)) {
        std::string currentId = WideToUtf8(symbolicLink);
        CoTaskMemFree(symbolicLink);

        if (currentId == device_id) {
          result.Attach(devices[i]);
        } else {
          devices[i]->Release();
        }
      } else {
        devices[i]->Release();
      }
    }

    // If not found, use first device
    if (!result && deviceCount > 0) {
      result.Attach(devices[0]);
    }
  }

  CoTaskMemFree(devices);
  return result;
}

}  // namespace moq_flutter
