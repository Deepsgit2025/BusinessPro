# "Show on Card" Toggle Implementation - Complete Analysis

## Overview
The "Show on card" toggle feature is **fully implemented and working correctly**. This document provides a comprehensive overview of how the feature works across the application layers.

## Feature Flow

### 1. User Interface Layer
**File:** `lib/features/company/screens/company_setup_screen.dart`

#### Toggle States (Lines 59-61)
```dart
bool _showGstin = false;
bool _showBusinessType = false;
bool _showBusinessCategory = false;
```

#### Toggle Widgets (Lines 477-480, 534-546)
The `_ShowOnCardToggle` widget displays the switch UI and connects it to state:
```dart
_ShowOnCardToggle(
  value: _showGstin,
  onChanged: (v) => setState(() => _showGstin = v),
)
```

When the user toggles a switch, `setState()` is called, triggering a rebuild.

### 2. Dynamic Card Rebuilding
**File:** `lib/features/company/screens/company_setup_screen.dart` (Lines 183-192)

The `_cardData` getter conditionally includes/excludes fields based on toggle states:
```dart
CardData get _cardData => CardData(
  name: _nameCtrl.text.trim(),
  phone: _phoneCtrl.text.trim(),
  email: _emailCtrl.text.trim(),
  address: _addr1Ctrl.text.trim(),
  logoPath: _logoPath,
  gstin: _showGstin ? _gstinCtrl.text.trim() : null,      // Respects toggle
  businessType: _showBusinessType ? _businessType : null,  // Respects toggle
  businessCategory: _showBusinessCategory ? _businessCategory : null,  // Respects toggle
);
```

**Key:** When toggles change, this getter produces different `CardData` instances.

### 3. Fingerprinting for Automatic Rebuilds
**File:** `lib/features/company/widgets/visiting_card.dart` (Lines 45-49)

The `CardData` class includes a fingerprint that changes when visibility toggles affect the displayed content:
```dart
String get fingerprint =>
  [name, phone, email, address, logoPath, gstin, businessType, businessCategory]
      .map((e) => e ?? '')
      .join('|');
```

This fingerprint is used as a `ValueKey` in the card widget (Line 374):
```dart
final card = VisitingCard(
  key: ValueKey('$style-${_cardData.fingerprint}'),  // Changes on any toggle
  data: _cardData,
  style: style,
);
```

**Effect:** When any toggle changes, the fingerprint changes, triggering an automatic rebuild of the card with new data.

### 4. Conditional Card Rendering
**File:** `lib/features/company/widgets/visiting_card.dart` (Lines 134-144)

The card templates conditionally display fields only if they have values:
```dart
List<Widget> _contactLines(CardData d, Color color) => [
  _ContactRow(Icons.phone, (d.phone?.isNotEmpty ?? false) ? d.phone! : 'Phone Number', color),
  _ContactRow(Icons.email_outlined, (d.email?.isNotEmpty ?? false) ? d.email! : 'Email ID', color),
  _ContactRow(Icons.location_on_outlined, (d.address?.isNotEmpty ?? false) ? d.address! : 'Business Address', color),
  if (d.gstin?.isNotEmpty ?? false) _ContactRow(Icons.receipt_long, 'GSTIN: ${d.gstin}', color),
  if (d.businessType?.isNotEmpty ?? false)
    _ContactRow(Icons.business_center_outlined, d.businessType!, color),
  if (d.businessCategory?.isNotEmpty ?? false)
    _ContactRow(Icons.category_outlined, d.businessCategory!, color),
];
```

**Key:** The `if` statements (lines 139-143) prevent rendering rows when fields are `null`, achieving instant visibility toggling.

### 5. Database Persistence
**File:** `lib/core/database/database_helper.dart` (Lines 109-111, 48-50)

The database schema includes columns for toggle states:
```sql
CREATE TABLE businesses (
  ...
  show_gstin_on_card             INTEGER DEFAULT 0,
  show_business_type_on_card     INTEGER DEFAULT 0,
  show_business_category_on_card INTEGER DEFAULT 0,
  ...
)
```

The migration (v1 → v2) adds these columns to existing databases.

### 6. Save & Load Cycle
**File:** `lib/features/company/screens/company_setup_screen.dart`

#### Load (Lines 135-137)
```dart
_showGstin = (biz['show_gstin_on_card'] as int? ?? 0) == 1;
_showBusinessType = (biz['show_business_type_on_card'] as int? ?? 0) == 1;
_showBusinessCategory = (biz['show_business_category_on_card'] as int? ?? 0) == 1;
```

#### Save (Lines 296-298)
```dart
'show_gstin_on_card': _showGstin ? 1 : 0,
'show_business_type_on_card': _showBusinessType ? 1 : 0,
'show_business_category_on_card': _showBusinessCategory ? 1 : 0,
```

### 7. Share Card Integration
**File:** `lib/features/company/screens/company_setup_screen.dart` (Lines 237-261)

When the user clicks "Share Card", the currently-selected card is captured as an image:
```dart
Future<void> _shareCard() async {
  try {
    final boundary = _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 3.0);
    // ... render to PNG and share
  }
}
```

**Key:** The card rendered in the `RepaintBoundary` (lines 383-384) respects all current toggle states, so the shared image includes only the fields marked "Show on card".

## Verification

### Unit Tests
Created `test/show_on_card_toggle_test.dart` with 6 tests that verify:
- ✅ All fields are included when all toggles are on
- ✅ GSTIN is excluded when its toggle is off
- ✅ Business Type is excluded when its toggle is off
- ✅ Business Category is excluded when its toggle is off
- ✅ Fingerprint changes when visibility toggles change
- ✅ Fingerprint remains identical for identical data

**Result:** All tests pass.

### Manual Testing Flow

1. **Navigate to Business Profile**
   - Tap/Click "Business Profile" in the app
   
2. **Fill in Business Details Tab**
   - Enter Business Type (e.g., "Retailer")
   - Enter Business Category (e.g., "Electronics & Electrical")
   - Enter GSTIN (e.g., "22AAAAA0000A1Z5")
   
3. **Toggle "Show on card" switches**
   - **OFF → ON:** Watch the field appear on the card preview above
   - **ON → OFF:** Watch the field disappear from the card preview
   - **Instant:** Changes appear immediately (no save needed)

4. **Save the Profile**
   - Click the "Save" button
   - Toggles are persisted to the database
   
5. **Verify Persistence**
   - Restart the app or navigate away and back
   - Toggle states are restored from the database
   
6. **Test Share Card**
   - Click "Share Card" button
   - The shared image includes only fields marked "Show on card"

## Implementation Summary

| Layer | Component | Status |
|-------|-----------|--------|
| UI | Toggle switches | ✅ Connected to state |
| State | Toggle variables | ✅ Properly managed |
| Data | CardData conditional fields | ✅ Respects toggles |
| Rendering | Card rebuilding on toggle | ✅ Uses fingerprint key |
| Database | Schema & persistence | ✅ Columns exist, save/load working |
| Sharing | Card export | ✅ Includes only shown fields |

## Key Design Decisions

1. **Fingerprint-based Rebuilding:** Using a fingerprint as the widget key ensures the card rebuilds instantly when any toggle changes, without needing explicit state management.

2. **Conditional Null vs. Empty Strings:** The code sets fields to `null` when toggles are off (not empty strings), allowing conditional rendering with `if (field?.isNotEmpty ?? false)`.

3. **Instant Visual Feedback:** No database save is required to see changes in the preview. The card updates immediately on toggle, with persistence happening only when the user clicks "Save".

4. **Backward Compatibility:** The database migration adds toggle columns with `DEFAULT 0`, so existing installations automatically treat all fields as hidden until the user explicitly enables them.

## Conclusion

The "Show on card" toggle feature is **fully functional and production-ready**. Users can:
- ✅ Toggle visibility of GSTIN, Business Type, and Business Category
- ✅ See instant preview updates in the card
- ✅ Save and reload their preferences
- ✅ Share cards with only the fields they've marked as visible

No additional implementation is required.
