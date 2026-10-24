import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import 'data/models.dart';
import 'data/store.dart';

/// Brand colours, matched to the web version.
class AppColors {
  static const accent = Color(0xFF0B5F6B);
  static const ink = Color(0xFF13212C);
  static const bg = Color(0xFFE9EDF1);
  static const line = Color(0xFFD3DAE1);
  static const muted = Color(0xFF5B6B78);
  static const inGreen = Color(0xFF1E7A45);
  static const inBg = Color(0xFFE2F2E8);
  static const outAmber = Color(0xFFA4530B);
  static const outBg = Color(0xFFFBEBDD);
  static const err = Color(0xFFB42318);
  static const errBg = Color(0xFFFDECEA);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.accent, primary: AppColors.accent, surface: Colors.white);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.bg,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppColors.line)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        foregroundColor: AppColors.ink,
        side: const BorderSide(color: AppColors.line),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
  );
}

const sectionLabel = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: AppColors.muted);
const mono = TextStyle(fontFamily: 'monospace', fontFeatures: [FontFeature.tabularFigures()]);

/// White rounded panel used for every card on screen.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: child,
      );
}

enum ChipKind { onShift, off, out, setup }

class StatusChip extends StatelessWidget {
  const StatusChip(this.text, this.kind, {super.key});
  final String text;
  final ChipKind kind;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      ChipKind.onShift => (AppColors.inBg, AppColors.inGreen),
      ChipKind.out => (AppColors.outBg, AppColors.outAmber),
      ChipKind.setup => (AppColors.errBg, AppColors.err),
      ChipKind.off => (AppColors.bg, AppColors.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(text.toUpperCase(), style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: .6)),
      ]),
    );
  }
}

/// Round photo of a worker, or their initial when there's no photo yet.
class WorkerAvatar extends StatelessWidget {
  const WorkerAvatar(this.worker, {super.key, this.size = 44, this.onTap});
  final Worker worker;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final photo = worker.idPhoto;
    final child = photo != null
        ? Image.file(Store.instance.photoFile(photo), width: size, height: size, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _initial())
        : _initial();
    return GestureDetector(
      onTap: photo != null ? onTap : null,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppColors.line, width: 2)),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }

  Widget _initial() => Container(
        color: AppColors.bg,
        alignment: Alignment.center,
        child: Text(worker.name.isEmpty ? '?' : worker.name.trim()[0].toUpperCase(),
            style: TextStyle(fontSize: size * .4, fontWeight: FontWeight.w600, color: AppColors.muted)),
      );
}

/// Dashed-looking box the worker taps to open the camera; shows the photo once taken.
class PhotoBox extends StatelessWidget {
  const PhotoBox({super.key, required this.photo, required this.title, required this.hint, required this.icon, required this.onTap});
  final Uint8List? photo;
  final String title;
  final String hint;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: Material(
        color: AppColors.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: photo == null ? AppColors.line : AppColors.accent, width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: photo != null
              ? Stack(fit: StackFit.expand, children: [
                  Image.memory(photo!, fit: BoxFit.cover),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                      child: const Text('Tap to retake', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ),
                  ),
                ])
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(icon, size: 48, color: AppColors.muted),
                    const SizedBox(height: 8),
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text(hint, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                  ]),
                ),
        ),
      ),
    );
  }
}

class ErrorText extends StatelessWidget {
  const ErrorText(this.message, {super.key});
  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.errBg, borderRadius: BorderRadius.circular(8)),
      child: Text(message!, style: const TextStyle(color: AppColors.err, fontSize: 14)),
    );
  }
}

/// Full-screen view of a stored photo.
void showPhoto(BuildContext context, String fileName) {
  showDialog<void>(
    context: context,
    builder: (ctx) => GestureDetector(
      onTap: () => Navigator.pop(ctx),
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(Store.instance.photoFile(fileName), fit: BoxFit.contain),
        ),
      ),
    ),
  );
}

/// Shows a yes/no dialog. Returns true when the user confirms.
Future<bool> confirm(BuildContext context, {required String title, required String body, required String yes}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
      ],
    ),
  );
  return r ?? false;
}
