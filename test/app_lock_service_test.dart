import 'package:flutter_test/flutter_test.dart';
import 'package:business_pro/services/security/app_lock_service.dart';
import 'package:business_pro/services/security/pin_hash_util.dart';

void main() {
  group('PinHashUtil', () {
    test('hash is stable and not the plain PIN', () {
      final h = PinHashUtil.hash('1234');
      expect(h, isNot('1234'));
      expect(h, PinHashUtil.hash('1234'));
      expect(h.length, 64); // SHA-256 hex
    });

    test('verify matches only the correct PIN', () {
      final h = PinHashUtil.hash('1234');
      expect(PinHashUtil.verify('1234', h), isTrue);
      expect(PinHashUtil.verify('0000', h), isFalse);
      expect(PinHashUtil.verify('1234', ''), isFalse);
    });
  });

  group('AppLockService', () {
    final service = AppLockService.instance;

    setUp(() {
      // Reset to a known enabled state with PIN 1234.
      final hash = PinHashUtil.hash('1234');
      service.init(pinEnabled: true, pinHash: hash);
    });

    test('init with PIN starts locked', () {
      expect(service.pinEnabled, isTrue);
      expect(service.isLocked, isTrue);
    });

    test('init without PIN is unlocked', () {
      service.init(pinEnabled: false, pinHash: null);
      expect(service.pinEnabled, isFalse);
      expect(service.isLocked, isFalse);
    });

    test('correct PIN unlocks', () {
      expect(service.tryUnlock('1234'), isTrue);
      expect(service.isLocked, isFalse);
    });

    test('wrong PIN throws and counts attempts', () {
      expect(() => service.tryUnlock('0000'), throwsA(isA<WrongPinException>()));
      expect(service.failedAttempts, 1);
    });

    test('5 wrong attempts trigger a 30s lockout', () {
      for (var i = 0; i < 4; i++) {
        expect(
            () => service.tryUnlock('0000'), throwsA(isA<WrongPinException>()));
      }
      // 5th wrong attempt → lockout
      expect(
        () => service.tryUnlock('0000'),
        throwsA(isA<LockoutException>()
            .having((e) => e.secondsRemaining, 'secondsRemaining', 30)),
      );
      expect(service.isInLockout, isTrue);
      // Further attempts during lockout throw LockoutException.
      expect(() => service.tryUnlock('1234'), throwsA(isA<LockoutException>()));
    });

    test('changePin requires correct current PIN', () {
      expect(
        () => service.changePin(currentPin: 'wrong', newPin: '5678'),
        throwsA(isA<WrongPinException>()),
      );
      final hash = service.changePin(currentPin: '1234', newPin: '5678');
      expect(hash, PinHashUtil.hash('5678'));
      expect(service.verifyPin('5678'), isTrue);
    });

    test('disablePin requires correct current PIN', () {
      expect(
        () => service.disablePin('wrong'),
        throwsA(isA<WrongPinException>()),
      );
      service.disablePin('1234');
      expect(service.pinEnabled, isFalse);
      expect(service.isLocked, isFalse);
    });

    test('verifyPin does not mutate attempt state', () {
      service.verifyPin('0000');
      service.verifyPin('1234');
      expect(service.failedAttempts, 0);
    });
  });
}
