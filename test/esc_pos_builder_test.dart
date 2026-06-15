import 'package:business_pro/services/printer/esc_pos_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EscPosBuilder', () {
    test('init() emits ESC @ reset bytes', () {
      final bytes = EscPosBuilder().init().build();
      expect(bytes.sublist(0, 2), [0x1B, 0x40]);
    });

    test('charsPerLine is 48 for 80mm and 32 for 58mm', () {
      expect(EscPosBuilder(paperSize: PaperSize.mm80).charsPerLine, 48);
      expect(EscPosBuilder(paperSize: PaperSize.mm58).charsPerLine, 32);
    });

    test('divider fills the full paper width plus a newline', () {
      final bytes = EscPosBuilder(paperSize: PaperSize.mm80).divider().build();
      // 48 dashes + newline.
      expect(bytes.length, 49);
      expect(bytes.last, 0x0A);
      expect(bytes.sublist(0, 48), List.filled(48, '-'.codeUnitAt(0)));
    });

    test('row pads left/right to the paper width', () {
      final bytes =
          EscPosBuilder(paperSize: PaperSize.mm58).row('A', 'B').build();
      // 32 chars + newline.
      expect(bytes.length, 33);
      expect(bytes.first, 'A'.codeUnitAt(0));
      expect(bytes[31], 'B'.codeUnitAt(0));
      expect(bytes.last, 0x0A);
    });

    test('non-ASCII characters are mapped to ? to keep the stream byte-clean',
        () {
      final bytes = EscPosBuilder().text('₹100').build();
      // ₹ (U+20B9) → '?'; the ASCII digits pass through.
      expect(bytes, [0x3F, '1'.codeUnitAt(0), '0'.codeUnitAt(0), '0'.codeUnitAt(0)]);
    });

    test('cut() emits the partial-cut command', () {
      final bytes = EscPosBuilder().cut().build();
      expect(bytes, [0x1D, 0x56, 0x41, 0x03]);
    });
  });
}
