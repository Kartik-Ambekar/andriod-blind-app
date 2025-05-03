import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'dart:io';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:media_scanner/media_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BlindAssistantApp());
}

class BlindAssistantApp extends StatelessWidget {
  const BlindAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blind Assistant',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

enum AppStatus {
  idle,
  listening,
  cameraActive,
  recording,
  saving,
  uploading,
  playing,
  error,
  done,
}

class _HomePageState extends State<HomePage> {
  final SpeechToText _speechToText = SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();
  bool _isListening = false;
  String _lastWords = '';
  CameraController? _cameraController;
  bool _isCameraActive = false;
  XFile? _capturedImage;
  bool _isProcessing = false;
  bool _isRecording = false;
  XFile? _recordedVideo;
  bool _isVideoSaved = false;
  File? _lastSavedVideoFile;
  bool _isUploading = false;
  AppStatus _status = AppStatus.idle;
  String _statusMessage = '';
  String? _errorMessage;
  AudioPlayer? _audioPlayer;

  @override
  void initState() {
    super.initState();
    _initSpeech();
    _initTTS();
  }

  void _initSpeech() async {
    await _speechToText.initialize();
    setState(() {});
  }

  void _initTTS() async {
    await _flutterTts.setLanguage('en-US');
    await _flutterTts.setSpeechRate(0.5);
  }

  Future<void> _speak(String text) async {
    await _flutterTts.speak(text);
  }

  void _startListening() async {
    if (_status == AppStatus.idle) {
      bool available = await _speechToText.initialize();
      if (available) {
        setState(() {
          _isListening = true;
          _status = AppStatus.listening;
          _statusMessage = 'Listening...';
        });
        _speak('Listening started. Please say look around to activate the camera.');
        _speechToText.listen(
          onResult: (result) {
            setState(() {
              _lastWords = result.recognizedWords;
              if (_lastWords.toLowerCase().contains('look around')) {
                _activateCamera();
              }
            });
          },
        );
      }
    }
  }

  void _stopListening() {
    _speechToText.stop();
    setState(() {
      _isListening = false;
      if (_status == AppStatus.listening) _status = AppStatus.idle;
      _statusMessage = '';
    });
    _speak('Stopped listening.');
  }

  Future<void> _activateCamera() async {
    if (_isCameraActive) return;
    if (await Permission.camera.request().isGranted) {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      _cameraController = CameraController(
        cameras[0],
        ResolutionPreset.high,
        enableAudio: false,
      );
      try {
        await _cameraController!.initialize();
        setState(() {
          _isCameraActive = true;
          _capturedImage = null;
          _status = AppStatus.cameraActive;
          _statusMessage = 'Camera is active.';
        });
        _speak('Camera activated. Tap record to start video.');
      } catch (e) {
        setState(() {
          _status = AppStatus.error;
          _errorMessage = 'Failed to activate camera.';
        });
        _speak('Failed to activate camera.');
      }
    } else {
      setState(() {
        _status = AppStatus.error;
        _errorMessage = 'Camera permission denied.';
      });
      _speak('Camera permission denied.');
    }
  }

  Future<void> _captureImage() async {
    if (_cameraController != null && _cameraController!.value.isInitialized && !_isProcessing) {
      setState(() { _isProcessing = true; });
      try {
        final image = await _cameraController!.takePicture();
        setState(() {
          _capturedImage = image;
        });
        _speak('Photo captured.');
      } catch (e) {
        _speak('Failed to capture photo.');
      } finally {
        setState(() { _isProcessing = false; });
      }
    }
  }

  Future<void> _startRecording() async {
    if (_cameraController != null && _cameraController!.value.isInitialized && !_isRecording) {
      try {
        await _cameraController!.startVideoRecording();
        setState(() {
          _isRecording = true;
          _status = AppStatus.recording;
          _statusMessage = 'Recording video...';
        });
        _speak('Video recording started. Tap stop recording to finish.');
      } catch (e) {
        setState(() {
          _status = AppStatus.error;
          _errorMessage = 'Failed to start video recording.';
        });
        _speak('Failed to start video recording.');
      }
    }
  }

  Future<void> _stopRecording() async {
    if (_cameraController != null && _cameraController!.value.isInitialized && _isRecording) {
      try {
        final video = await _cameraController!.stopVideoRecording();
        setState(() {
          _isRecording = false;
          _recordedVideo = video;
          _status = AppStatus.saving;
          _statusMessage = 'Saving video...';
        });
        _speak('Video recording stopped. Saving and uploading.');
        await _saveAndUploadVideo();
      } catch (e) {
        setState(() {
          _status = AppStatus.error;
          _errorMessage = 'Failed to stop video recording.';
        });
        _speak('Failed to stop video recording.');
      }
    }
  }

  Future<void> _saveAndUploadVideo() async {
    try {
      // Save video
      final directory = await getExternalStorageDirectory();
      final moviesDir = Directory('${directory!.parent.parent.parent.parent.path}/Movies');
      if (!await moviesDir.exists()) {
        await moviesDir.create(recursive: true);
      }
      final newPath = '${moviesDir.path}/${DateTime.now().millisecondsSinceEpoch}.mp4';
      final newFile = await File(_recordedVideo!.path).copy(newPath);
      await MediaScanner.loadMedia(path: newFile.path);
      setState(() {
        _isVideoSaved = true;
        _lastSavedVideoFile = newFile;
        _status = AppStatus.uploading;
        _statusMessage = 'Uploading video...';
      });
      await uploadVideo(newFile);
    } catch (e) {
      setState(() {
        _status = AppStatus.error;
        _errorMessage = 'Failed to save or upload video.';
      });
      _speak('Failed to save or upload video.');
    }
  }

  Future<void> uploadVideo(File videoFile) async {
    setState(() { _isUploading = true; _status = AppStatus.uploading; _statusMessage = 'Uploading video...'; });
    final uri = Uri.parse('http://192.168.122.127:5569/upload');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(await http.MultipartFile.fromPath('file', videoFile.path));
    final response = await request.send();
    setState(() { _isUploading = false; });
    if (response.statusCode == 200) {
      final bytes = await response.stream.toBytes();
      final dir = await getTemporaryDirectory();
      final mp3File = File('${dir.path}/response.mp3');
      await mp3File.writeAsBytes(bytes);
      setState(() {
        _status = AppStatus.playing;
        _statusMessage = 'Playing response...';
      });
      _audioPlayer = AudioPlayer();
      await _audioPlayer!.play(DeviceFileSource(mp3File.path));
      _speak('Video uploaded successfully. Playing response.');
      _audioPlayer!.onPlayerComplete.listen((event) {
        setState(() {
          _status = AppStatus.done;
          _statusMessage = 'Done! Tap Back to Home.';
        });
      });
    } else {
      setState(() {
        _status = AppStatus.error;
        _errorMessage = 'Failed to upload video.';
      });
      _speak('Failed to upload video.');
    }
  }

  void _closeCamera() {
    setState(() {
      _isCameraActive = false;
      _capturedImage = null;
      _isRecording = false;
      _recordedVideo = null;
      _isVideoSaved = false;
      _status = AppStatus.idle;
      _statusMessage = '';
      _errorMessage = null;
      _audioPlayer?.dispose();
      _audioPlayer = null;
    });
    _cameraController?.dispose();
    _cameraController = null;
    _speak('Camera closed.');
  }

  void _backToHome() {
    setState(() {
      _isCameraActive = false;
      _capturedImage = null;
      _isRecording = false;
      _recordedVideo = null;
      _isVideoSaved = false;
      _status = AppStatus.idle;
      _statusMessage = '';
      _errorMessage = null;
      _audioPlayer?.dispose();
      _audioPlayer = null;
    });
    _speak('Ready for next action.');
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: Center(
        child: _isCameraActive ? _buildCameraView() : _buildMainView(),
      ),
    );
  }

  Widget _buildMainView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Blind Assistant',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.blue),
        ),
        const SizedBox(height: 20),
        Text(
          _status == AppStatus.listening ? 'Listening... Say "look around"' : 'Tap and hold the mic, then say "look around"',
          style: const TextStyle(fontSize: 20, color: Colors.black87),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 40),
        GestureDetector(
          onTapDown: (_) => _startListening(),
          onTapUp: (_) => _stopListening(),
          child: Semantics(
            label: 'Microphone button. Tap and hold to speak.',
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                color: _isListening ? Colors.red : Colors.blue,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    spreadRadius: 2,
                    blurRadius: 5,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Icon(
                Icons.mic,
                size: 100,
                color: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 30),
        if (_statusMessage.isNotEmpty)
          Text(
            _statusMessage,
            style: const TextStyle(fontSize: 20, color: Colors.blueAccent),
            textAlign: TextAlign.center,
          ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: Text(
              _errorMessage!,
              style: const TextStyle(fontSize: 18, color: Colors.red),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }

  Widget _buildCameraView() {
    return Stack(
      children: [
        if (_cameraController != null && _cameraController!.value.isInitialized)
          Center(child: CameraPreview(_cameraController!)),
        if (_status == AppStatus.recording)
          _buildStatusOverlay('Recording... Tap stop to finish.'),
        if (_status == AppStatus.saving)
          _buildStatusOverlay('Saving video...'),
        if (_status == AppStatus.uploading)
          _buildStatusOverlay('Uploading video...'),
        if (_status == AppStatus.playing)
          _buildStatusOverlay('Playing response...'),
        if (_status == AppStatus.error && _errorMessage != null)
          _buildStatusOverlay(_errorMessage!, isError: true),
        if (_status == AppStatus.done)
          _buildStatusOverlay('Done! Tap Back to Home.'),
        Positioned(
          bottom: 60,
          left: 10,
          right: 10,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (_status == AppStatus.cameraActive)
                ElevatedButton.icon(
                  onPressed: _startRecording,
                  icon: const Icon(Icons.fiber_manual_record, size: 32),
                  label: const Text('Record', style: TextStyle(fontSize: 22)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(110, 60),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              if (_status == AppStatus.recording)
                ElevatedButton.icon(
                  onPressed: _stopRecording,
                  icon: const Icon(Icons.stop_circle, size: 32),
                  label: const Text('Stop Recording', style: TextStyle(fontSize: 22)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(170, 60),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              if (_status == AppStatus.done)
                ElevatedButton.icon(
                  onPressed: _backToHome,
                  icon: const Icon(Icons.home, size: 32),
                  label: const Text('Back to Home', style: TextStyle(fontSize: 22)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(170, 60),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ElevatedButton.icon(
                onPressed: _closeCamera,
                icon: const Icon(Icons.stop, size: 32),
                label: const Text('Stop', style: TextStyle(fontSize: 22)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(110, 60),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatusOverlay(String message, {bool isError = false}) {
    return Container(
      color: isError ? Colors.red.withOpacity(0.7) : Colors.black.withOpacity(0.7),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!isError) const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 20),
            Text(
              message,
              style: TextStyle(
                fontSize: 24,
                color: Colors.white,
                fontWeight: FontWeight.bold,
                backgroundColor: isError ? Colors.red : Colors.black54,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
