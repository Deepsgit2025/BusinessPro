/// On-device parsing of raw OCR text from a supplier bill into structured
/// fields that pre-fill the Purchase form. This is intentionally best-effort:
/// it extracts what it can with reasonable confidence and leaves the rest for
/// the user to fill in on the review screen. It never throws on messy input.
///
/// Real-world bills are table layouts, and ML Kit reads them column-by-column —
/// so a label ("Invoice No.") and its value ("Invoice314") usually arrive on
/// SEPARATE lines, and OCR mangles characters (₹→7, I↔1, O↔0, "." → ","). The
/// parser is built around those two facts: it matches labels and then looks at
/// following lines for the value, and it aggressively cleans numeric noise.
library;

/// Structured result of parsing a bill's raw OCR text. Any field may be null
/// when it couldn't be found; [rawText] is always the full extracted text so
/// the review screen can show it for manual lookup.
class BillParseResult {
  final String? supplierName;
  final String? supplierGstin;
  final String? billNumber;
  final DateTime? billDate;
  final double? totalAmount;
  final double? taxAmount;
  final double? subtotal;
  final List<ParsedLineItem> lineItems;
  final String rawText;

  const BillParseResult({
    this.supplierName,
    this.supplierGstin,
    this.billNumber,
    this.billDate,
    this.totalAmount,
    this.taxAmount,
    this.subtotal,
    this.lineItems = const [],
    required this.rawText,
  });

  /// True when nothing structured was found — the review screen uses this to
  /// nudge the user toward the raw-text view / manual entry.
  bool get isEmpty =>
      supplierName == null &&
      supplierGstin == null &&
      billNumber == null &&
      billDate == null &&
      totalAmount == null &&
      taxAmount == null &&
      subtotal == null &&
      lineItems.isEmpty;
}

/// One detected line item. Only [itemName] is guaranteed; the numeric fields are
/// filled when the line clearly looked like "name qty price total".
class ParsedLineItem {
  final String itemName;
  final double? quantity;
  final String? unit;
  final double? unitPrice;
  final double? totalPrice;

  const ParsedLineItem({
    required this.itemName,
    this.quantity,
    this.unit,
    this.unitPrice,
    this.totalPrice,
  });
}

/// Stateless parser. Construct once (it's cheap) and call [parse].
class BillParser {
  const BillParser();

  BillParseResult parse(String rawText) {
    final lines = rawText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final lineItems = _extractLineItems(lines);
    // Largest line-item amount, used to sanity-check the grand total (the total
    // can never be smaller than the biggest single line).
    final maxLineAmount = lineItems
        .map((i) => i.totalPrice ?? 0)
        .fold<double>(0, (a, b) => b > a ? b : a);

    return BillParseResult(
      supplierName: _extractSupplierName(lines),
      supplierGstin: _extractGstin(rawText),
      billNumber: _extractBillNumber(lines),
      billDate: _extractDate(lines, rawText),
      totalAmount: _extractTotalAmount(lines, minPlausible: maxLineAmount),
      taxAmount: _extractTaxAmount(lines),
      subtotal: _extractSubtotal(lines),
      lineItems: lineItems,
      rawText: rawText,
    );
  }

  // ── Junk filtering ──────────────────────────────────────────────────────────
  // Status-bar / app-chrome text that leaks in when the bill is a SCREENSHOT of
  // a PDF (clock, battery, viewer name, nav glyphs), plus pure punctuation rows.
  static final _junkLine = RegExp(
    r'^(?:\d{1,2}:\d{2}.*'          // clock e.g. "5:28 &"
    r'|pdf\s*reader'
    r'|sale|original for recipient'
    r'|\.+ll.*'                      // signal/battery glyph rows ".ll l 39"
    r'|[#<>|।\\/\-।.,\s]+'          // pure punctuation / nav glyph rows
    r'|\d+\s*/?\s*\d*'              // bare page numbers "1 /"
    r')$',
    caseSensitive: false,
  );

  bool _isJunk(String line) => _junkLine.hasMatch(line.trim());

  // ── Numeric cleanup ─────────────────────────────────────────────────────────

  /// Parses the first money-looking value out of [text], tolerating common OCR
  /// noise: a leading ₹ misread as 7/t/{/(, thousands grouping commas, and a
  /// decimal point misread as a comma ("49,000,00" → 49000.00). Returns null
  /// when no plausible amount is present.
  double? _amount(String text) {
    // OCR often reads a 0 inside/after a number as the letter o/O ("1,000.0o").
    // Repair those before extracting the numeric token.
    final cleaned = text.replaceAllMapped(
        RegExp(r'(?<=[0-9.,])[oO]|[oO](?=[0-9.,])'), (_) => '0');

    // Grab the longest digit/comma/dot run (the number), ignoring currency junk.
    final m = RegExp(r'[0-9][0-9.,]*[0-9]|[0-9]').firstMatch(cleaned);
    if (m == null) return null;
    var s = m.group(0)!;

    // If the last group after a separator is exactly 2 digits, that separator is
    // the decimal point — normalise it and strip the rest as grouping. Handles
    // both "49,000.00" and the OCR'd "49,000,00".
    final lastSep = s.lastIndexOf(RegExp(r'[.,]'));
    if (lastSep != -1 && s.length - lastSep - 1 == 2) {
      final intPart = s.substring(0, lastSep).replaceAll(RegExp(r'[.,]'), '');
      final frac = s.substring(lastSep + 1);
      s = '$intPart.$frac';
    } else {
      s = s.replaceAll(RegExp(r'[.,]'), '');
    }
    return double.tryParse(s);
  }

  /// All amounts on a line, in order. When [moneyOnly] is set, only values that
  /// carry a 2-digit decimal (e.g. "49,000.00") are returned — this excludes
  /// long IDs like account / phone numbers that have no paise.
  List<double> _amountsIn(String line, {bool moneyOnly = false}) {
    final pattern = moneyOnly
        ? RegExp(r'(?:₹|rs\.?|inr|[7t{(])?\s*([0-9][0-9., ]*[.,][0-9]{2})\b',
            caseSensitive: false)
        : RegExp(r'(?:₹|rs\.?|inr|[7t{(])?\s*([0-9][0-9.,]*[0-9]|[0-9])',
            caseSensitive: false);
    return pattern
        .allMatches(line)
        .map((m) => _amount(m.group(1)!))
        .whereType<double>()
        .toList();
  }

  /// Walks forward from a matched label line to find the next line that carries
  /// the value. [test] decides whether a candidate line qualifies. Looks at up
  /// to [window] following non-junk lines (table values often sit 1-2 rows down).
  String? _valueAfter(List<String> lines, int labelIndex,
      bool Function(String) test,
      {int window = 3}) {
    var seen = 0;
    for (var i = labelIndex + 1; i < lines.length && seen < window; i++) {
      final line = lines[i];
      if (_isJunk(line)) continue;
      seen++;
      if (test(line)) return line;
    }
    return null;
  }

  // ── GSTIN ──────────────────────────────────────────────────────────────────
  // A GSTIN is 15 chars: 2 state digits + 5 PAN letters + 4 digits + 1 letter +
  // entity char + 'Z' + checksum. OCR commonly inserts a space and confuses
  // 1↔I and 0↔O. We find the label, take the candidate token, strip spaces, and
  // repair the digit/letter positions before validating.
  String? _extractGstin(String text) {
    // Pull the token right after "GSTIN", across spaces it may have introduced.
    final labelled = RegExp(r'gst\s*in[:\s]*([0-9A-Za-z ]{15,22})',
            caseSensitive: false)
        .firstMatch(text);
    final candidates = <String>[
      if (labelled != null) labelled.group(1)!,
      text, // fall back to scanning the whole text
    ];
    for (final raw in candidates) {
      final compact = raw.toUpperCase().replaceAll(RegExp(r'[^0-9A-Z]'), '');
      // Slide a 15-char window and try to repair each into a valid GSTIN.
      for (var i = 0; i + 15 <= compact.length; i++) {
        final fixed = _repairGstin(compact.substring(i, i + 15));
        if (fixed != null) return fixed;
      }
    }
    return null;
  }

  /// Repairs OCR confusions in a 15-char window by position, then validates.
  /// Returns the cleaned GSTIN or null if it can't be made valid.
  String? _repairGstin(String s) {
    if (s.length != 15) return null;
    final c = s.split('');
    // Positions 0-1: state code digits.   2-6: PAN letters.  7-10: digits.
    // 11: letter.  12: entity (1-9/A-Z).  13: 'Z'.  14: checksum (0-9/A-Z).
    String digit(String ch) =>
        const {'I': '1', 'O': '0', 'L': '1', 'S': '5', 'B': '8', 'Z': '2', 'G': '6'}[ch] ?? ch;
    String letter(String ch) =>
        const {'1': 'I', '0': 'O', '5': 'S', '8': 'B', '6': 'G'}[ch] ?? ch;

    // Use the mandatory 'Z' at position 13 as an alignment anchor: only accept
    // windows that already have it there, rather than fabricating one (which
    // would silently produce a wrong GSTIN from a misaligned window).
    if (c[13] != 'Z') return null;

    for (var i = 0; i < 15; i++) {
      final ch = c[i];
      if (i <= 1 || (i >= 7 && i <= 10)) {
        c[i] = digit(ch);
      } else if ((i >= 2 && i <= 6) || i == 11) {
        c[i] = letter(ch);
      }
    }
    final fixed = c.join();
    final valid = RegExp(
        r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');
    return valid.hasMatch(fixed) ? fixed : null;
  }

  // ── Bill / invoice number ───────────────────────────────────────────────────
  // The value usually sits on the line AFTER an "Invoice No." label (table
  // layout), e.g. "Invoice314". An inline "Invoice No: X" form is also handled.
  String? _extractBillNumber(List<String> lines) {
    final label = RegExp(r'(?:invoice|bill)\s*(?:no|num|number|#)', caseSensitive: false);

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!label.hasMatch(line)) continue;

      // Inline value on the same line, e.g. "Invoice No: INV-441".
      final inline = RegExp(r'(?:no|num|number|#)[:.\s]+([A-Za-z0-9][A-Za-z0-9\-\/]+)',
              caseSensitive: false)
          .firstMatch(line);
      final inlineVal = inline?.group(1)?.trim();
      if (_looksLikeBillNumber(inlineVal)) return inlineVal;

      // Otherwise the value is on a following line.
      final next = _valueAfter(lines, i, _looksLikeBillNumber);
      if (next != null) return _cleanBillNumber(next);
    }

    // Bare "No: INV-0009" lines (common when the title is just "TAX INVOICE"),
    // excluding account / phone contexts which also use "No".
    for (final line in lines) {
      if (RegExp(r'(?:a/?c|account|phone|ph|mob|contact|gst)',
              caseSensitive: false)
          .hasMatch(line)) {
        continue;
      }
      final m = RegExp(r'^(?:inv(?:oice)?\s*)?no[:.#\s]+([A-Za-z0-9][A-Za-z0-9\-\/]+)',
              caseSensitive: false)
          .firstMatch(line);
      final v = m?.group(1)?.trim();
      // Require a letter or hyphen so we don't grab a long bare ID number.
      if (v != null && _looksLikeBillNumber(v) && RegExp(r'[A-Za-z\-]').hasMatch(v)) {
        return _cleanBillNumber(v);
      }
    }
    return null;
  }

  bool _looksLikeBillNumber(String? s) {
    if (s == null) return false;
    final v = _cleanBillNumber(s);
    if (v.length < 3) return false;
    // Must contain at least one digit, and not be a date or a known label.
    if (!RegExp(r'\d').hasMatch(v)) return false;
    if (RegExp(r'^\d{1,2}[\/\-.]\d').hasMatch(v)) return false; // a date
    if (RegExp(r'(?:place|supply|vehicle|delivery|field|date|total|amount)',
            caseSensitive: false)
        .hasMatch(v)) {
      return false;
    }
    return true;
  }

  String _cleanBillNumber(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

  // ── Date ────────────────────────────────────────────────────────────────────
  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  DateTime? _extractDate(List<String> lines, String rawText) {
    // Prefer the value following a "Date" label, then fall back to scanning all
    // text — this avoids picking up phone numbers / account numbers as a date.
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'^date\b', caseSensitive: false).hasMatch(lines[i])) {
        final inline = _parseDate(lines[i]);
        if (inline != null) return inline;
        final next = _valueAfter(lines, i, (l) => _parseDate(l) != null);
        if (next != null) return _parseDate(next);
      }
    }
    return _parseDate(rawText);
  }

  DateTime? _parseDate(String text) {
    final numeric =
        RegExp(r'\b(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2,4})\b').firstMatch(text);
    if (numeric != null) {
      try {
        final day = int.parse(numeric.group(1)!);
        final month = int.parse(numeric.group(2)!);
        var year = int.parse(numeric.group(3)!);
        if (year < 100) year += 2000;
        if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
          return DateTime(year, month, day);
        }
      } catch (_) {}
    }
    final named = RegExp(r'\b(\d{1,2})\s+([A-Za-z]{3,})\s+(\d{4})\b',
            caseSensitive: false)
        .firstMatch(text);
    if (named != null) {
      final month = _months[named.group(2)!.toLowerCase().substring(0, 3)];
      if (month != null) {
        try {
          return DateTime(
              int.parse(named.group(3)!), month, int.parse(named.group(1)!));
        } catch (_) {}
      }
    }
    return null;
  }

  // ── Total amount ────────────────────────────────────────────────────────────
  // The grand total typically appears after a "Total"/"Amount Payable" label,
  // either inline or on a following line. We collect all label-adjacent amounts
  // and take the largest, since the printed total is the biggest figure.
  double? _extractTotalAmount(List<String> lines, {double minPlausible = 0}) {
    final keywords = RegExp(
      r'(?:grand\s*total|amount\s*payable|total\s*due|net\s*amount|total\s*amount|^total$|\btotal\b)',
      caseSensitive: false,
    );
    double? best;
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'sub\s*total', caseSensitive: false).hasMatch(lines[i])) {
        continue; // not the grand total
      }
      if (!keywords.hasMatch(lines[i])) continue;
      final candidates = <double>[
        ..._amountsIn(lines[i], moneyOnly: true),
        for (final v in _followingAmounts(lines, i, 3, moneyOnly: true)) v,
      ];
      for (final v in candidates) {
        if (best == null || v > best) best = v;
      }
    }

    // In column-block layouts the "Total" label sits far from its value and the
    // adjacency search can latch onto a small unrelated figure (e.g. a rate).
    // The grand total can't be smaller than the largest single line item, so if
    // the label result is implausible, fall back to the largest money figure.
    if (best != null && best >= minPlausible) return best;

    // Collect every money figure on the bill. The grand total is typically the
    // largest value that ALSO repeats (subtotal = total = paid all equal it),
    // which lets us reject one-off OCR-inflated outliers like "75,320.00" when
    // the true "5,320.00" appears multiple times.
    final counts = <double, int>{};
    for (final line in lines) {
      if (_isJunk(line)) continue;
      for (final v in _amountsIn(line, moneyOnly: true)) {
        counts[v] = (counts[v] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return best;

    final repeated = counts.entries.where((e) => e.value >= 2).map((e) => e.key);
    if (repeated.isNotEmpty) {
      return repeated.reduce((a, b) => a > b ? a : b);
    }
    return counts.keys.reduce((a, b) => a > b ? a : b);
  }

  /// Amounts found on the next [count] non-junk lines after [index].
  List<double> _followingAmounts(List<String> lines, int index, int count,
      {bool moneyOnly = false}) {
    final out = <double>[];
    var seen = 0;
    for (var i = index + 1; i < lines.length && seen < count; i++) {
      if (_isJunk(lines[i])) continue;
      seen++;
      out.addAll(_amountsIn(lines[i], moneyOnly: moneyOnly));
    }
    return out;
  }

  // ── Tax amount ──────────────────────────────────────────────────────────────
  // Looks for a "Total Tax Amount" value first; otherwise sums per-line GST.
  double? _extractTaxAmount(List<String> lines) {
    // 1. "Total Tax Amount" — value inline or on a following line.
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'total\s*tax', caseSensitive: false).hasMatch(lines[i])) {
        final inline = _amountsIn(lines[i], moneyOnly: true);
        if (inline.isNotEmpty) return inline.last;
        final next = _followingAmounts(lines, i, 3, moneyOnly: true);
        if (next.isNotEmpty) return next.first;
      }
    }

    // 2. Per-line GST. The amount may be inline ("CGST 9% 108.00") or, in table
    // layouts, on the line following a bare "GST"/"IGST" header.
    final keywords =
        RegExp(r'(?:c\s*gst|s\s*gst|i\s*gst|\bgst\b)', caseSensitive: false);
    double total = 0;
    bool found = false;
    for (var i = 0; i < lines.length; i++) {
      if (!keywords.hasMatch(lines[i])) continue;
      // Tax value: inline money, else the next money-bearing line. Prefer the
      // larger value on a "2,333.33 (5.0%)" style line (smaller is the rate).
      var amounts = _amountsIn(lines[i], moneyOnly: true);
      if (amounts.isEmpty) {
        amounts = _followingAmounts(lines, i, 2, moneyOnly: true);
      }
      if (amounts.isNotEmpty) {
        total += amounts.reduce((a, b) => a > b ? a : b);
        found = true;
      }
    }
    return found ? total : null;
  }

  // ── Subtotal ────────────────────────────────────────────────────────────────
  double? _extractSubtotal(List<String> lines) {
    final keywords = RegExp(
      r'(?:sub\s*total|taxable\s*amount|taxable\s*value)',
      caseSensitive: false,
    );
    for (var i = 0; i < lines.length; i++) {
      if (!keywords.hasMatch(lines[i])) continue;
      final inline = _amountsIn(lines[i]);
      if (inline.isNotEmpty) return inline.last;
      final next = _followingAmounts(lines, i, 2);
      if (next.isNotEmpty) return next.first;
    }
    return null;
  }

  // ── Supplier name ───────────────────────────────────────────────────────────
  // The business name is the first early line that's real text — not status-bar
  // junk, not a label, not an address/contact line, not an amount. We also
  // prefer an ALL-CAPS line (business names are usually printed capitalised).
  String? _extractSupplierName(List<String> lines) {
    final skip = RegExp(
      r'(?:gstin|gst|address|phone|mob|email|invoice|\bbill\b|tax|date|state|'
      r'contact|item|hsn|sac|total|amount|bank|account|ifsc|terms|signatory|'
      r'place|supply|vehicle|delivery|quantity|price|rate|received|balance|'
      r'\bto\b|\d{6,})',
      caseSensitive: false,
    );

    final candidates = <String>[];
    for (final line in lines.take(12)) {
      if (_isJunk(line)) continue;
      if (line.length < 4 || skip.hasMatch(line) || _isAmount(line)) continue;
      // Reject lines that are mostly digits/punctuation (addresses, IDs).
      final letters = line.replaceAll(RegExp(r'[^A-Za-z]'), '').length;
      if (letters < 3) continue;
      candidates.add(line);
    }
    if (candidates.isEmpty) return null;
    // Prefer an all-uppercase candidate (typical for the printed business name).
    final caps = candidates.where(
        (c) => c == c.toUpperCase() && RegExp(r'[A-Z]').hasMatch(c));
    return (caps.isNotEmpty ? caps.first : candidates.first).trim();
  }

  bool _isAmount(String text) => RegExp(r'^[₹\d\s,.]+$').hasMatch(text);

  // ── Line items ──────────────────────────────────────────────────────────────
  // Two strategies, tried in order:
  //  1. Column-block reassembly — table-layout bills are read column-by-column,
  //     so item names, rates and amounts each arrive as a vertical block under
  //     their header ("Item", "Rate", "Amount"). We collect each block and zip
  //     them by row index. This is the common case for printed GST bills.
  //  2. Single-line rows — a fallback for bills where a whole row lands on one
  //     line ("name qty rate amount").
  List<ParsedLineItem> _extractLineItems(List<String> lines) {
    final columns = _extractLineItemsByColumns(lines);
    if (columns.isNotEmpty) return columns;
    return _extractLineItemsByRows(lines);
  }

  /// Header keywords that mark the start of each item-table column.
  static final _itemHeader =
      RegExp(r'^(?:item|particular|product|description|goods)', caseSensitive: false);
  static final _qtyHeader =
      RegExp(r'^(?:qty|quantity)\b', caseSensitive: false);
  static final _rateHeader =
      RegExp(r'^(?:rate|price|mrp|unit\s*price|price\s*/?\s*unit)\b',
          caseSensitive: false);
  // "Amount" as a column header, but NOT "Amount in words" (a footer phrase).
  static final _amountHeader =
      RegExp(r'^(?:amount|value)\b(?!\s*in\s*words)', caseSensitive: false);

  /// Lines that end a column block (a different header, a footer/total, a junk
  /// row, or an address/contact line). Used to bound each vertical block.
  static final _blockStopper = RegExp(
    r'(?:^qty|quantity|^rate|^price|^amount|^value|sub\s*total|^total|paid|'
    r'tax\s*invoice|amount\s*in\s*words|bank\s*details|hsn|sac|scan\s*to\s*pay|'
    r'authoris|signatory|terms|^no[:.]|^date[:.]|gstin|^ph[:.]|^upi|ifsc|a/?c)',
    caseSensitive: false,
  );

  List<ParsedLineItem> _extractLineItemsByColumns(List<String> lines) {
    final names = _columnBlock(lines, _itemHeader, _isItemName);
    final rates = _columnAmounts(lines, _rateHeader);
    final amounts = _columnAmounts(lines, _amountHeader);
    final qtys = _columnNumbers(lines, _qtyHeader);

    if (names.isEmpty) return <ParsedLineItem>[];
    // Need at least one numeric column to be confident this is a real table.
    if (rates.isEmpty && amounts.isEmpty) return <ParsedLineItem>[];

    final items = <ParsedLineItem>[];
    for (var i = 0; i < names.length; i++) {
      final rate = i < rates.length ? rates[i] : null;
      final amount = i < amounts.length ? amounts[i] : null;
      var qty = i < qtys.length ? qtys[i] : null;
      // Recover a missing/garbled qty from amount ÷ rate when both are present.
      if (qty == null && rate != null && rate > 0 && amount != null) {
        final derived = amount / rate;
        final rounded = derived.roundToDouble();
        if ((derived - rounded).abs() < 0.02 && rounded >= 1) qty = rounded;
      }
      items.add(ParsedLineItem(
        itemName: names[i],
        quantity: qty,
        unitPrice: rate,
        totalPrice: amount,
      ));
    }
    return items;
  }

  /// Collects the vertical block of text values directly under the first header
  /// matching [header], stopping at the next header/footer. [accept] filters out
  /// stray non-value lines (e.g. row-index digits between names).
  List<String> _columnBlock(
      List<String> lines, RegExp header, bool Function(String) accept) {
    final start = lines.indexWhere(header.hasMatch);
    if (start == -1) return <String>[];
    final out = <String>[];
    for (var i = start + 1; i < lines.length; i++) {
      final line = lines[i];
      if (_isJunk(line)) continue;
      if (_blockStopper.hasMatch(line)) break;
      if (accept(line)) out.add(line.trim());
    }
    return out;
  }

  /// A column block parsed as money amounts (one per row).
  List<double> _columnAmounts(List<String> lines, RegExp header) {
    return _columnBlock(lines, header, _looksLikeAmount)
        .map(_amount)
        .whereType<double>()
        .toList();
  }

  /// A column block parsed as bare integer/decimal quantities.
  List<double> _columnNumbers(List<String> lines, RegExp header) {
    return _columnBlock(lines, header, (l) => RegExp(r'^\d+(?:\.\d+)?$').hasMatch(l.trim()))
        .map((l) => double.tryParse(l.trim()))
        .whereType<double>()
        .toList();
  }

  /// True for a plausible item-name line: has letters, isn't a pure number, a
  /// bare row index, or an amount.
  bool _isItemName(String line) {
    final l = line.trim();
    if (l.length < 2) return false;
    if (RegExp(r'^\d+$').hasMatch(l)) return false; // row index
    if (_looksLikeAmount(l)) return false;
    return RegExp(r'[A-Za-zऀ-ॿ]{2,}').hasMatch(l); // Latin or Devanagari
  }

  /// True when a line is dominated by a money amount (optionally with an OCR'd
  /// currency prefix like F/T/₹, and a trailing 0 misread as o/O), e.g.
  /// "F500.00", "1,200.00", "1,000.0o".
  bool _looksLikeAmount(String line) {
    return RegExp(r'^[₹fFtT{(]?\s*\d[\d., ]*[\doO]$').hasMatch(line.trim());
  }

  /// Fallback: single-line rows shaped like "name qty [unit] rate amount".
  List<ParsedLineItem> _extractLineItemsByRows(List<String> lines) {
    final items = <ParsedLineItem>[];
    final rowRegex = RegExp(
      r'^(.+?)\s+(\d+(?:\.\d+)?)\s+(?:[A-Za-z]+\s+)?(\d+(?:,\d+)*(?:\.\d+)?)\s+(\d+(?:,\d+)*(?:\.\d+)?)$',
    );
    final skip = RegExp(
      r'(?:total|cgst|sgst|igst|\bgst\b|\btax\b|discount|amount|grand|date|invoice|\bbill\b|hsn|sac|bank|account)',
      caseSensitive: false,
    );

    for (final line in lines) {
      if (_isJunk(line) || skip.hasMatch(line)) continue;
      final m = rowRegex.firstMatch(line);
      if (m == null) continue;
      final name = m.group(1)!.trim();
      if (name.length < 2) continue;
      items.add(ParsedLineItem(
        itemName: name,
        quantity: double.tryParse(m.group(2)!),
        unitPrice: _amount(m.group(3)!),
        totalPrice: _amount(m.group(4)!),
      ));
    }
    return items;
  }
}
