import 'dart:typed_data';

enum PaperSize { mm58, mm80 }

/// Builds raw ESC/POS byte streams for thermal printers. Pure Dart with no
/// dependencies, so it is fully unit-testable. The thermal formatter composes a
/// document by chaining the fluent methods, then calls [build].
class EscPosBuilder {
  final List<int> _bytes = [];
  final PaperSize paperSize;

  EscPosBuilder({this.paperSize = PaperSize.mm80});

  /// Printable characters per line for the selected paper width (Font A).
  int get charsPerLine => paperSize == PaperSize.mm58 ? 32 : 48;

  /// ESC @ — reset the printer to its power-on defaults.
  EscPosBuilder init() {
    _bytes.addAll([0x1B, 0x40]);
    return this;
  }

  EscPosBuilder alignLeft() {
    _bytes.addAll([0x1B, 0x61, 0x00]);
    return this;
  }

  EscPosBuilder alignCenter() {
    _bytes.addAll([0x1B, 0x61, 0x01]);
    return this;
  }

  EscPosBuilder alignRight() {
    _bytes.addAll([0x1B, 0x61, 0x02]);
    return this;
  }

  EscPosBuilder fontNormal() {
    _bytes.addAll([0x1B, 0x21, 0x00]);
    return this;
  }

  EscPosBuilder fontBold() {
    _bytes.addAll([0x1B, 0x21, 0x08]);
    return this;
  }

  EscPosBuilder fontDouble() {
    _bytes.addAll([0x1B, 0x21, 0x30]);
    return this;
  }

  EscPosBuilder text(String data) {
    _bytes.addAll(_encode(data));
    return this;
  }

  EscPosBuilder textLine(String data) {
    _bytes.addAll(_encode(data));
    _bytes.add(0x0A);
    return this;
  }

  EscPosBuilder divider({String char = '-'}) {
    _bytes.addAll(_encode(char * charsPerLine));
    _bytes.add(0x0A);
    return this;
  }

  EscPosBuilder doubleDivider() => divider(char: '=');

  /// A line with [left] flush-left and [right] flush-right, space-padded to the
  /// paper width. If they don't fit, [left] is truncated.
  EscPosBuilder row(String left, String right) {
    final space = charsPerLine - left.length - right.length;
    if (space > 0) {
      _bytes.addAll(_encode(left + ' ' * space + right));
    } else {
      final keep = charsPerLine - right.length - 1;
      final truncated = keep > 0 ? left.substring(0, keep) : '';
      _bytes.addAll(_encode('$truncated $right'));
    }
    _bytes.add(0x0A);
    return this;
  }

  /// An item line: the name on its own line, then a qty/amount [row] below.
  EscPosBuilder itemRow(String name, String qty, String amount) {
    textLine(name.length > charsPerLine ? name.substring(0, charsPerLine) : name);
    row('  $qty', amount);
    return this;
  }

  EscPosBuilder emptyLine([int count = 1]) {
    for (var i = 0; i < count; i++) {
      _bytes.add(0x0A);
    }
    return this;
  }

  /// GS V 1 — partial cut.
  EscPosBuilder cut() {
    _bytes.addAll([0x1D, 0x56, 0x41, 0x03]);
    return this;
  }

  Uint8List build() => Uint8List.fromList(_bytes);

  /// Encode text to a single-byte code page. Thermal printers default to a
  /// CP437/PC437-style page; mapping non-ASCII to '?' keeps the stream
  /// byte-clean rather than emitting multi-byte UTF-8 the printer can't render.
  List<int> _encode(String data) {
    final out = <int>[];
    for (final unit in data.codeUnits) {
      out.add(unit <= 0x7F ? unit : 0x3F /* ? */);
    }
    return out;
  }
}
