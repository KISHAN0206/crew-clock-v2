import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Opens the front camera full-screen. Pops with the JPEG bytes, or null if cancelled.
Future<Uint8List?> takePhoto(BuildContext context, String hint) {
  return Navigator.of(context).push<Uint8List>(
    MaterialPageRoute(builder: (_) => CameraScreen(hint: hint), fullscreenDialog: true),
  );
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.hint});
  final String hint;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _error = 'No camera found on this device.');
        return;
      }
      final front = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
      final c = CameraController(front, ResolutionPreset.medium, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } on CameraException catch (e) {
      setState(() => _error = e.code == 'CameraAccessDenied' || e.code == 'CameraAccessDeniedWithoutPrompt'
          ? 'Camera access is off. Turn it on for Crew Clock in the tablet\'s Settings, then try again.'
          : 'The camera could not start (${e.code}). Close this screen and try again.');
    } catch (_) {
      setState(() => _error = 'The camera could not start. Close this screen and try again.');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller = null;
      c.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _start();
    }
  }

  Future<void> _snap() async {
    final c = _controller;
    if (c == null || _busy || !c.value.isInitialized) return;
    setState(() => _busy = true);
    try {
      final file = await c.takePicture();
      final bytes = await file.readAsBytes();
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(widget.hint, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 16)),
          ),
          Expanded(
            child: Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 17)),
                    )
                  : c == null
                      ? const CircularProgressIndicator(color: Colors.white)
                      : ClipRRect(borderRadius: BorderRadius.circular(12), child: CameraPreview(c)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Row(children: [
              SizedBox(
                width: 120,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const Spacer(),
              Semantics(
                button: true,
                label: 'Take photo',
                child: GestureDetector(
                  onTap: _snap,
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _busy || c == null ? Colors.white38 : Colors.white,
                      border: Border.all(color: Colors.white, width: 5),
                    ),
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.black, width: 3)),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              const SizedBox(width: 120),
            ]),
          ),
        ]),
      ),
    );
  }
}
