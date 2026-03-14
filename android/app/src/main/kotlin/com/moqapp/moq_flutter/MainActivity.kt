package com.moqapp.moq_flutter

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.Image
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val methodChannelName = "com.moq_flutter/native_capture"
    private val audioEventChannelName = "com.moq_flutter/audio_samples"
    private val videoEventChannelName = "com.moq_flutter/video_frames"

    private val requestCameraPermissionCode = 1001
    private val requestMicrophonePermissionCode = 1002

    private var videoSink: EventChannel.EventSink? = null
    private var audioSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var pendingCameraPermissionResult: MethodChannel.Result? = null
    private var pendingMicrophonePermissionResult: MethodChannel.Result? = null

    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null

    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var captureRequestBuilder: CaptureRequest.Builder? = null

    private var videoEncoder: MediaCodec? = null
    private var encoderInputSurface: Surface? = null
    private var previewImageReader: ImageReader? = null
    private var previewWidth = 640
    private var previewHeight = 360
    private var lastPreviewSentAtMs = 0L

    private var selectedCameraId: String? = null
    private var videoWidth = 1280
    private var videoHeight = 720
    private var videoFrameRate = 30
    private var videoBitrate = 2_000_000

    private var spsData: ByteArray? = null
    private var ppsData: ByteArray? = null
    private val isVideoCapturing = AtomicBoolean(false)

    private var audioSampleRate = 48_000
    private var audioChannels = 2
    private var audioBitsPerSample = 16
    private var audioRecord: AudioRecord? = null
    private var audioThread: Thread? = null
    private val isAudioCapturing = AtomicBoolean(false)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            methodChannelName,
        ).setMethodCallHandler(::handleMethodCall)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            audioEventChannelName,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                audioSink = events
            }

            override fun onCancel(arguments: Any?) {
                audioSink = null
            }
        })

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            videoEventChannelName,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                videoSink = events
            }

            override fun onCancel(arguments: Any?) {
                videoSink = null
            }
        })
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initializeAudio" -> {
                audioSampleRate = call.argument<Int>("sampleRate") ?: 48_000
                audioChannels = call.argument<Int>("channels") ?: 2
                audioBitsPerSample = call.argument<Int>("bitsPerSample") ?: 16
                result.success(null)
            }
            "startAudioCapture" -> startAudioCapture(result)
            "stopAudioCapture" -> {
                stopAudioCapture()
                result.success(null)
            }
            "getAvailableCameras" -> result.success(getAvailableCameras())
            "initializeVideo" -> {
                videoWidth = call.argument<Int>("width") ?: 1280
                videoHeight = call.argument<Int>("height") ?: 720
                videoFrameRate = call.argument<Int>("frameRate") ?: 30
                selectedCameraId = call.argument<String>("cameraId")
                videoBitrate = estimateBitrate(videoWidth, videoHeight, videoFrameRate)
                result.success(null)
            }
            "selectCamera" -> {
                selectedCameraId = call.argument<String>("cameraId")
                result.success(null)
            }
            "startVideoCapture" -> startVideoCapture(result)
            "stopVideoCapture" -> {
                stopVideoCapture()
                result.success(null)
            }
            "hasCameraPermission" -> result.success(hasPermission(Manifest.permission.CAMERA))
            "hasMicrophonePermission" -> result.success(hasPermission(Manifest.permission.RECORD_AUDIO))
            "requestCameraPermission" -> requestPermission(
                Manifest.permission.CAMERA,
                requestCameraPermissionCode,
                result,
            )
            "requestMicrophonePermission" -> requestPermission(
                Manifest.permission.RECORD_AUDIO,
                requestMicrophonePermissionCode,
                result,
            )
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            permission,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestPermission(
        permission: String,
        requestCode: Int,
        result: MethodChannel.Result,
    ) {
        if (hasPermission(permission)) {
            result.success(true)
            return
        }

        when (requestCode) {
            requestCameraPermissionCode -> pendingCameraPermissionResult = result
            requestMicrophonePermissionCode -> pendingMicrophonePermissionResult = result
        }
        ActivityCompat.requestPermissions(this, arrayOf(permission), requestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED

        when (requestCode) {
            requestCameraPermissionCode -> {
                pendingCameraPermissionResult?.success(granted)
                pendingCameraPermissionResult = null
            }
            requestMicrophonePermissionCode -> {
                pendingMicrophonePermissionResult?.success(granted)
                pendingMicrophonePermissionResult = null
            }
        }
    }

    private fun getAvailableCameras(): List<Map<String, String>> {
        val cameraManager = getSystemService(CAMERA_SERVICE) as CameraManager
        return cameraManager.cameraIdList.map { cameraId ->
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            val lensFacing = characteristics.get(CameraCharacteristics.LENS_FACING)
            val position = when (lensFacing) {
                CameraCharacteristics.LENS_FACING_FRONT -> "front"
                CameraCharacteristics.LENS_FACING_BACK -> "back"
                CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
                else -> "unknown"
            }
            mapOf(
                "id" to cameraId,
                "name" to "Camera $cameraId",
                "position" to position,
            )
        }
    }

    private fun startAudioCapture(result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.RECORD_AUDIO)) {
            result.error("microphone_permission", "Microphone permission not granted", null)
            return
        }

        if (isAudioCapturing.get()) {
            result.success(null)
            return
        }

        try {
            val channelMask = if (audioChannels > 1) {
                AudioFormat.CHANNEL_IN_STEREO
            } else {
                AudioFormat.CHANNEL_IN_MONO
            }
            val encoding = AudioFormat.ENCODING_PCM_16BIT
            val minBufferSize = AudioRecord.getMinBufferSize(
                audioSampleRate,
                channelMask,
                encoding,
            ).coerceAtLeast(audioSampleRate / 10)

            val record = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                audioSampleRate,
                channelMask,
                encoding,
                minBufferSize,
            )

            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                result.error("audio_init_failed", "Failed to initialize AudioRecord", null)
                return
            }

            audioRecord = record
            isAudioCapturing.set(true)
            record.startRecording()

            val bytesPerSample = audioBitsPerSample / 8
            val frameSamples = (audioSampleRate / 50).coerceAtLeast(1)
            val frameBytes = frameSamples * audioChannels * bytesPerSample

            audioThread = Thread {
                val pcmBuffer = ByteArray(frameBytes)
                val startTimeMs = System.currentTimeMillis()

                while (isAudioCapturing.get()) {
                    val bytesRead = record.read(pcmBuffer, 0, pcmBuffer.size)
                    if (bytesRead <= 0) {
                        continue
                    }

                    val payload = if (bytesRead == pcmBuffer.size) {
                        pcmBuffer.copyOf()
                    } else {
                        pcmBuffer.copyOf(bytesRead)
                    }

                    val event = hashMapOf<String, Any>(
                        "data" to payload,
                        "sampleRate" to audioSampleRate,
                        "channels" to audioChannels,
                        "bitsPerSample" to audioBitsPerSample,
                        "timestampMs" to (System.currentTimeMillis() - startTimeMs).toInt(),
                    )
                    mainHandler.post {
                        audioSink?.success(event)
                    }
                }
            }.apply {
                name = "NativeCaptureAudio"
                start()
            }

            result.success(null)
        } catch (e: Exception) {
            stopAudioCapture()
            result.error("audio_start_failed", e.message, null)
        }
    }

    private fun startVideoCapture(result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.CAMERA)) {
            result.error("camera_permission", "Camera permission not granted", null)
            return
        }

        if (isVideoCapturing.get()) {
            result.success(null)
            return
        }

        try {
            startCameraThread()
            startVideoEncoder()
            openCamera(result)
        } catch (e: Exception) {
            stopVideoCapture()
            result.error("video_start_failed", e.message, null)
        }
    }

    private fun startCameraThread() {
        if (cameraThread != null) {
            return
        }

        val thread = HandlerThread("NativeCaptureCamera")
        thread.start()
        cameraThread = thread
        cameraHandler = Handler(thread.looper)
    }

    private fun stopCameraThread() {
        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null
    }

    private fun startVideoEncoder() {
        val format = MediaFormat.createVideoFormat("video/avc", videoWidth, videoHeight).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, videoBitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, videoFrameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
        }

        spsData = null
        ppsData = null

        val codec = MediaCodec.createEncoderByType("video/avc")
        codec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {}

            override fun onOutputBufferAvailable(
                codec: MediaCodec,
                index: Int,
                info: MediaCodec.BufferInfo,
            ) {
                if (info.size <= 0) {
                    codec.releaseOutputBuffer(index, false)
                    return
                }

                val outputBuffer = codec.getOutputBuffer(index)
                if (outputBuffer == null) {
                    codec.releaseOutputBuffer(index, false)
                    return
                }

                val packet = ByteArray(info.size)
                outputBuffer.position(info.offset)
                outputBuffer.limit(info.offset + info.size)
                outputBuffer.get(packet)
                codec.releaseOutputBuffer(index, false)

                val isCodecConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                if (isCodecConfig) {
                    cacheCodecConfig(packet)
                    return
                }

                val isKeyframe = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                val annexB = toAnnexB(packet)
                val payload = if (isKeyframe) prependParameterSetsIfNeeded(annexB) else annexB

                val event = hashMapOf<String, Any>(
                    "data" to payload,
                    "width" to videoWidth,
                    "height" to videoHeight,
                    "format" to "h264_annexb",
                    "timestampMs" to (info.presentationTimeUs / 1000L).toInt(),
                )

                mainHandler.post {
                    videoSink?.success(event)
                }
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                format.getByteBuffer("csd-0")?.let { spsData = byteBufferToArray(it) }
                format.getByteBuffer("csd-1")?.let { ppsData = byteBufferToArray(it) }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                mainHandler.post {
                    videoSink?.error("video_encoder", e.message, null)
                }
                stopVideoCapture()
            }
        }, cameraHandler)

        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoderInputSurface = codec.createInputSurface()
        previewWidth = minOf(videoWidth, 640)
        previewHeight = minOf(videoHeight, 360)
        previewImageReader = ImageReader.newInstance(
            previewWidth,
            previewHeight,
            ImageFormat.YUV_420_888,
            2,
        ).apply {
            setOnImageAvailableListener({ reader ->
                val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                handlePreviewImage(image)
            }, cameraHandler)
        }
        codec.start()
        videoEncoder = codec
    }

    private fun openCamera(result: MethodChannel.Result) {
        val manager = getSystemService(CAMERA_SERVICE) as CameraManager
        val cameraId = resolveCameraId(manager)
        selectedCameraId = cameraId

        manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                cameraDevice = device
                createCaptureSession(device, result)
            }

            override fun onDisconnected(device: CameraDevice) {
                device.close()
                cameraDevice = null
                stopVideoCapture()
            }

            override fun onError(device: CameraDevice, error: Int) {
                device.close()
                cameraDevice = null
                stopVideoCapture()
                result.error("camera_open_failed", "Camera error: $error", null)
            }
        }, cameraHandler)
    }

    private fun createCaptureSession(
        device: CameraDevice,
        result: MethodChannel.Result,
    ) {
        val inputSurface = encoderInputSurface
        if (inputSurface == null) {
            result.error("video_surface", "Encoder surface not ready", null)
            return
        }
        val previewSurface = previewImageReader?.surface

        captureRequestBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
            addTarget(inputSurface)
            if (previewSurface != null) {
                addTarget(previewSurface)
            }
            set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            set(
                CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                android.util.Range(videoFrameRate, videoFrameRate),
            )
        }

        device.createCaptureSession(
            listOfNotNull(inputSurface, previewSurface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    session.setRepeatingRequest(
                        captureRequestBuilder!!.build(),
                        null,
                        cameraHandler,
                    )
                    isVideoCapturing.set(true)
                    result.success(null)
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    result.error("camera_session_failed", "Failed to configure capture session", null)
                    stopVideoCapture()
                }
            },
            cameraHandler,
        )
    }

    private fun stopVideoCapture() {
        isVideoCapturing.set(false)

        try {
            captureSession?.stopRepeating()
        } catch (_: Exception) {
        }

        try {
            captureSession?.abortCaptures()
        } catch (_: Exception) {
        }

        captureSession?.close()
        captureSession = null

        cameraDevice?.close()
        cameraDevice = null

        try {
            videoEncoder?.stop()
        } catch (_: Exception) {
        }
        videoEncoder?.release()
        videoEncoder = null

        encoderInputSurface?.release()
        encoderInputSurface = null
        previewImageReader?.close()
        previewImageReader = null

        stopCameraThread()
    }

    override fun onDestroy() {
        stopAudioCapture()
        stopVideoCapture()
        super.onDestroy()
    }

    private fun stopAudioCapture() {
        isAudioCapturing.set(false)
        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        audioThread?.join(250)
        audioThread = null
        audioRecord?.release()
        audioRecord = null
    }

    private fun resolveCameraId(cameraManager: CameraManager): String {
        selectedCameraId?.let { requestedId ->
            if (cameraManager.cameraIdList.contains(requestedId)) {
                return requestedId
            }
        }

        cameraManager.cameraIdList.forEach { cameraId ->
            val lensFacing = cameraManager.getCameraCharacteristics(cameraId)
                .get(CameraCharacteristics.LENS_FACING)
            if (lensFacing == CameraCharacteristics.LENS_FACING_BACK) {
                return cameraId
            }
        }

        return cameraManager.cameraIdList.first()
    }

    private fun estimateBitrate(width: Int, height: Int, frameRate: Int): Int {
        val pixelsPerSecond = width.toLong() * height.toLong() * frameRate.toLong()
        return pixelsPerSecond.coerceIn(2_000_000L, 8_000_000L).toInt()
    }

    private fun cacheCodecConfig(packet: ByteArray) {
        val nalUnits = extractNalUnits(toAnnexB(packet))
        for (nalUnit in nalUnits) {
            val nalType = nalUnit.firstOrNull()?.toInt()?.and(0x1F) ?: continue
            when (nalType) {
                7 -> spsData = prependStartCode(nalUnit)
                8 -> ppsData = prependStartCode(nalUnit)
            }
        }
    }

    private fun prependParameterSetsIfNeeded(packet: ByteArray): ByteArray {
        val hasSps = containsNalType(packet, 7)
        val hasPps = containsNalType(packet, 8)

        if ((hasSps || spsData == null) && (hasPps || ppsData == null)) {
            return packet
        }

        val totalSize = (spsData?.size ?: 0) + (ppsData?.size ?: 0) + packet.size
        val result = ByteArray(totalSize)
        var offset = 0

        spsData?.let {
            System.arraycopy(it, 0, result, offset, it.size)
            offset += it.size
        }
        ppsData?.let {
            System.arraycopy(it, 0, result, offset, it.size)
            offset += it.size
        }
        System.arraycopy(packet, 0, result, offset, packet.size)
        return result
    }

    private fun containsNalType(packet: ByteArray, targetType: Int): Boolean {
        return extractNalUnits(packet).any { nal ->
            nal.isNotEmpty() && (nal[0].toInt() and 0x1F) == targetType
        }
    }

    private fun toAnnexB(packet: ByteArray): ByteArray {
        if (packet.size >= 4 &&
            packet[0] == 0.toByte() &&
            packet[1] == 0.toByte() &&
            (
                packet[2] == 1.toByte() ||
                    (packet[2] == 0.toByte() && packet[3] == 1.toByte())
                )
        ) {
            return packet
        }

        val output = ArrayList<Byte>()
        var offset = 0
        while (offset + 4 <= packet.size) {
            val nalLength = (
                ((packet[offset].toInt() and 0xFF) shl 24) or
                    ((packet[offset + 1].toInt() and 0xFF) shl 16) or
                    ((packet[offset + 2].toInt() and 0xFF) shl 8) or
                    (packet[offset + 3].toInt() and 0xFF)
                )
            offset += 4
            if (nalLength <= 0 || offset + nalLength > packet.size) {
                return packet
            }

            output.add(0)
            output.add(0)
            output.add(0)
            output.add(1)
            for (i in 0 until nalLength) {
                output.add(packet[offset + i])
            }
            offset += nalLength
        }

        return output.toByteArray()
    }

    private fun extractNalUnits(packet: ByteArray): List<ByteArray> {
        val nalUnits = mutableListOf<ByteArray>()
        var start = -1
        var index = 0

        while (index < packet.size - 3) {
            val isFourByteStartCode = packet[index] == 0.toByte() &&
                packet[index + 1] == 0.toByte() &&
                packet[index + 2] == 0.toByte() &&
                packet[index + 3] == 1.toByte()
            val isThreeByteStartCode = packet[index] == 0.toByte() &&
                packet[index + 1] == 0.toByte() &&
                packet[index + 2] == 1.toByte()

            if (isFourByteStartCode || isThreeByteStartCode) {
                if (start >= 0) {
                    nalUnits.add(packet.copyOfRange(start, index))
                }
                start = index + if (isFourByteStartCode) 4 else 3
                index = start
                continue
            }
            index += 1
        }

        if (start >= 0 && start < packet.size) {
            nalUnits.add(packet.copyOfRange(start, packet.size))
        }
        return nalUnits
    }

    private fun prependStartCode(nalUnit: ByteArray): ByteArray {
        val prefixed = ByteArray(nalUnit.size + 4)
        prefixed[0] = 0
        prefixed[1] = 0
        prefixed[2] = 0
        prefixed[3] = 1
        System.arraycopy(nalUnit, 0, prefixed, 4, nalUnit.size)
        return prefixed
    }

    private fun byteBufferToArray(buffer: ByteBuffer): ByteArray {
        val duplicate = buffer.duplicate()
        val bytes = ByteArray(duplicate.remaining())
        duplicate.get(bytes)
        return bytes
    }

    private fun handlePreviewImage(image: Image) {
        image.use { frame ->
            val nowMs = System.currentTimeMillis()
            if (nowMs - lastPreviewSentAtMs < 200) {
                return
            }
            lastPreviewSentAtMs = nowMs

            val jpegBytes = yuv420ToJpeg(frame) ?: return
            val event = hashMapOf<String, Any>(
                "data" to jpegBytes,
                "width" to frame.width,
                "height" to frame.height,
                "format" to "jpeg",
                "timestampMs" to nowMs.toInt(),
            )
            mainHandler.post {
                videoSink?.success(event)
            }
        }
    }

    private fun yuv420ToJpeg(image: Image): ByteArray? {
        val nv21 = imageToNv21(image) ?: return null
        val output = ByteArrayOutputStream()
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, image.width, image.height, null)
        if (!yuvImage.compressToJpeg(Rect(0, 0, image.width, image.height), 70, output)) {
            return null
        }
        return output.toByteArray()
    }

    private fun imageToNv21(image: Image): ByteArray? {
        if (image.format != ImageFormat.YUV_420_888 || image.planes.size < 3) {
            return null
        }

        val width = image.width
        val height = image.height
        val ySize = width * height
        val uvSize = width * height / 2
        val nv21 = ByteArray(ySize + uvSize)

        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]

        copyPlane(
            yPlane.buffer,
            yPlane.rowStride,
            yPlane.pixelStride,
            width,
            height,
            nv21,
            0,
            1,
        )

        val chromaHeight = height / 2
        val chromaWidth = width / 2
        val vBuffer = vPlane.buffer
        val uBuffer = uPlane.buffer
        val vRowStride = vPlane.rowStride
        val uRowStride = uPlane.rowStride
        val vPixelStride = vPlane.pixelStride
        val uPixelStride = uPlane.pixelStride

        var outputOffset = ySize
        for (row in 0 until chromaHeight) {
            var vRowOffset = row * vRowStride
            var uRowOffset = row * uRowStride
            for (col in 0 until chromaWidth) {
                nv21[outputOffset++] = vBuffer.get(vRowOffset)
                nv21[outputOffset++] = uBuffer.get(uRowOffset)
                vRowOffset += vPixelStride
                uRowOffset += uPixelStride
            }
        }

        return nv21
    }

    private fun copyPlane(
        buffer: ByteBuffer,
        rowStride: Int,
        pixelStride: Int,
        width: Int,
        height: Int,
        output: ByteArray,
        offset: Int,
        outputPixelStride: Int,
    ) {
        var outputOffset = offset
        for (row in 0 until height) {
            var inputOffset = row * rowStride
            for (col in 0 until width) {
                output[outputOffset] = buffer.get(inputOffset)
                outputOffset += outputPixelStride
                inputOffset += pixelStride
            }
        }
    }
}
