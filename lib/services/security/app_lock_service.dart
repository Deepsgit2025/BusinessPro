import 'package:flutter/foundation.dart';

import 'pin_hash_util.dart';

/// Thrown by [AppLockService.tryUnlock], [AppLockService.changePin] and
/// [AppLockService.disablePin] when the supplied PIN is incorrect.
class WrongPinException implements Exception {
  final String message;
  const WrongPinException([this.message = 'Wrong PIN']);
  @override
  String toString() => 'WrongPinException: $message';
}

/// Thrown by [AppLockService.tryUnlock] while the app is in a cool-down period
/// after too many wrong attempts. [secondsRemaining] is the time left before the
/// next unlock attempt is allowed.
class LockoutException implements Exception {
  final int secondsRemaining;
  const LockoutException(this.secondsRemaining);
  @override
  String toString() =>
      'LockoutException: try again in $secondsRemaining seconds';
}

/// Singleton app-lock controller.
///
/// Owns the "is the app currently locked?" state plus the PIN-enable flag and
/// the failed-attempt / lockout bookkeeping. The widget layer
/// ([AppLockWrapper], [AppLockScreen]) listens to this via [ChangeNotifier].
///
/// The hash itself lives in the DB (`settings.security_pin_hash`); this service
/// holds an in-memory copy injected at [init] and updated whenever the PIN
/// changes. Persisting the hash is the caller's job (via the `onChanged`
/// callback on the settings screen).
class AppLockService extends ChangeNotifier {
  AppLockService._();
  static final AppLockService _instance = AppLockService._();
  static AppLockService get instance => _instance;

  // ── Config ────────────────────────────────────────────────────────────────

  /// Wrong attempts allowed before a lockout kicks in.
  static const int _maxAttempts = 5;

  /// Escalating lockout durations (seconds), indexed by lockout bracket.
  static const List<int> _lockoutLadder = [30, 60, 120, 300, 600];

  /// How long the app may sit in the background before it re-locks itself.
  static const Duration _autoLockAfter = Duration(seconds: 120);

  // ── State ───────────────────────────────────────────────────────────────

  bool _pinEnabled = false;
  String? _pinHash;
  bool _locked = false;

  int _failedAttempts = 0;
  int _lockoutBracket = 0; // how many lockouts have happened this streak
  DateTime? _lockoutUntil;

  DateTime? _backgroundedAt;
  bool _initialized = false;

  // ── Getters ───────────────────────────────────────────────────────────────

  bool get isLocked => _locked;
  bool get pinEnabled => _pinEnabled;
  int get failedAttempts => _failedAttempts;

  bool get isInLockout {
    final until = _lockoutUntil;
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    // Lockout has elapsed — clear it lazily.
    _lockoutUntil = null;
    return false;
  }

  /// Seconds left in the current lockout, or null if not locked out.
  int? get lockoutSecondsRemaining {
    final until = _lockoutUntil;
    if (until == null) return null;
    final remaining = until.difference(DateTime.now()).inSeconds;
    if (remaining <= 0) {
      _lockoutUntil = null;
      return null;
    }
    return remaining;
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  /// Call once at app start, after reading the persisted PIN settings.
  void init({required bool pinEnabled, String? pinHash}) {
    _pinEnabled = pinEnabled && (pinHash != null && pinHash.isNotEmpty);
    _pinHash = (pinHash != null && pinHash.isNotEmpty) ? pinHash : null;
    // Start locked if a PIN is set, so the app demands it on cold start.
    _locked = _pinEnabled;
    _failedAttempts = 0;
    _lockoutBracket = 0;
    _lockoutUntil = null;
    _backgroundedAt = null;
    _initialized = true;
    notifyListeners();
  }

  /// App returned to the foreground. Re-lock if it was backgrounded long enough.
  void onAppResumed() {
    if (!_pinEnabled || _locked) {
      _backgroundedAt = null;
      return;
    }
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (since == null) return;
    if (DateTime.now().difference(since) >= _autoLockAfter) {
      _locked = true;
      notifyListeners();
    }
  }

  /// App went to the background — start the auto-lock countdown.
  void onAppPaused() {
    if (!_pinEnabled || _locked) return;
    _backgroundedAt = DateTime.now();
  }

  /// App is being detached/closed — lock immediately so the next launch asks.
  void onAppDetached() {
    if (!_pinEnabled) return;
    _locked = true;
    _backgroundedAt = null;
  }

  // ── PIN management ──────────────────────────────────────────────────────

  /// Read-only check that [pin] matches the current PIN. Does not mutate any
  /// state (no attempt counting, no lockout) — use it for in-app re-auth such as
  /// the "enter current PIN" step before changing/disabling.
  bool verifyPin(String pin) =>
      _pinHash != null && PinHashUtil.verify(pin, _pinHash!);

  /// Enables the PIN with [pin]. Returns the hash to persist to the DB.
  String enablePin(String pin) {
    final hash = PinHashUtil.hash(pin);
    _pinHash = hash;
    _pinEnabled = true;
    _locked = false; // user just set it up — don't immediately lock them out
    _resetAttempts();
    notifyListeners();
    return hash;
  }

  /// Changes the PIN. Throws [WrongPinException] if [currentPin] is wrong.
  /// Returns the new hash to persist.
  String changePin({required String currentPin, required String newPin}) {
    _assertCurrentPin(currentPin);
    final hash = PinHashUtil.hash(newPin);
    _pinHash = hash;
    _resetAttempts();
    notifyListeners();
    return hash;
  }

  /// Disables the PIN. Throws [WrongPinException] if [currentPin] is wrong.
  void disablePin(String currentPin) {
    _assertCurrentPin(currentPin);
    _pinEnabled = false;
    _pinHash = null;
    _locked = false;
    _resetAttempts();
    notifyListeners();
  }

  /// Attempts to unlock the app.
  ///
  /// Throws [LockoutException] if currently in a cool-down period, or
  /// [WrongPinException] if the PIN is wrong (after recording the attempt).
  /// Returns true and unlocks on success.
  bool tryUnlock(String pin) {
    if (isInLockout) {
      throw LockoutException(lockoutSecondsRemaining ?? 0);
    }

    if (_pinHash != null && PinHashUtil.verify(pin, _pinHash!)) {
      _locked = false;
      _resetAttempts();
      notifyListeners();
      return true;
    }

    // Wrong PIN — record the attempt and maybe trigger a lockout.
    _failedAttempts++;
    if (_failedAttempts >= _maxAttempts) {
      final idx = _lockoutBracket.clamp(0, _lockoutLadder.length - 1);
      final duration = _lockoutLadder[idx];
      _lockoutUntil = DateTime.now().add(Duration(seconds: duration));
      _lockoutBracket++;
      _failedAttempts = 0;
      notifyListeners();
      throw LockoutException(duration);
    }
    notifyListeners();
    throw const WrongPinException();
  }

  // ── Internals ───────────────────────────────────────────────────────────

  void _assertCurrentPin(String pin) {
    if (_pinHash == null || !PinHashUtil.verify(pin, _pinHash!)) {
      throw const WrongPinException();
    }
  }

  void _resetAttempts() {
    _failedAttempts = 0;
    _lockoutBracket = 0;
    _lockoutUntil = null;
  }

  // Exposed for completeness / debugging.
  bool get isInitialized => _initialized;
}
