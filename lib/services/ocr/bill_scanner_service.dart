import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

/// Thin wrapper around ML Kit's on-device text recognition for the "Scan Bill"
/// flow. Runs the Latin (English/numbers) recognizer and, when available, the
/// Devanagari (Hindi) recognizer over the same image and merges their output,
/// since a bill commonly mixes Hindi labels with Latin numerals.
///
/// Android-only: ML Kit ships no Windows/desktop implementation, so callers
/// must gate construction behind a `Platform.isAndroid` check.
///
/// The Devanagari recognizer is a separate native module (added as an explicit
/// dependency in `app/build.gradle.kts`). Its construction/processing is wrapped
/// in try/catch so that, if it is ever absent from a build, OCR degrades to
/// Latin-only instead of crashing the app.
///
/// Always [dispose] when the owning screen closes to free native resources.
class BillScannerService {
  final TextRecognizer _latin =
      TextRecognizer(script: TextRecognitionScript.latin);

  TextRecognizer? _devanagari;
  bool _devanagariDisabled = false;

  /// Lazily builds the Devanagari recognizer, returning null (and disabling
  /// further attempts) if the native module is unavailable.
  TextRecognizer? get _devanagariRecognizer {
    if (_devanagariDisabled) return null;
    try {
      return _devanagari ??=
          TextRecognizer(script: TextRecognitionScript.devanagiri);
    } catch (e) {
      debugPrint('Devanagari recognizer unavailable, Latin-only OCR: $e');
      _devanagariDisabled = true;
      return null;
    }
  }

  /// Extracts text from [imageFile]. Returns the combined recognized text
  /// (Latin first, then Devanagari when available). Empty string when nothing
  /// legible was found.
  Future<String> extractText(XFile imageFile) async {
    final input = InputImage.fromFilePath(imageFile.path);

    final parts = <String>[];

    final latin = await _latin.processImage(input);
    if (latin.text.trim().isNotEmpty) parts.add(latin.text.trim());

    final devanagari = _devanagariRecognizer;
    if (devanagari != null) {
      try {
        final result = await devanagari.processImage(input);
        if (result.text.trim().isNotEmpty) parts.add(result.text.trim());
      } catch (e) {
        debugPrint('Devanagari OCR failed, using Latin only: $e');
        _devanagariDisabled = true;
      }
    }

    return parts.join('\n');
  }

  void dispose() {
    _latin.close();
    _devanagari?.close();
  }
}
