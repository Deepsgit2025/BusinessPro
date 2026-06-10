import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';

/// The three shareable visiting-card designs, matching the Vyapar reference.
enum CardStyle { classic, ethnic, gradient }

extension CardStyleX on CardStyle {
  String get id => name;

  String get label => switch (this) {
        CardStyle.classic => 'Classic',
        CardStyle.ethnic => 'Ethnic',
        CardStyle.gradient => 'Gradient',
      };

  static CardStyle fromId(String? id) =>
      CardStyle.values.firstWhere((s) => s.name == id, orElse: () => CardStyle.classic);
}

/// Data the card renders. Built from the business row so the card and the
/// form stay in sync as the user edits.
class CardData {
  final String name;
  final String? phone;
  final String? email;
  final String? address;
  final String? logoPath;
  final String? gstin;
  final String? businessType;
  final String? businessCategory;

  const CardData({
    required this.name,
    this.phone,
    this.email,
    this.address,
    this.logoPath,
    this.gstin,
    this.businessType,
    this.businessCategory,
  });

  /// Cheap value signature used to key the card widget so it rebuilds the
  /// instant any displayed field changes (including show-on-card toggles).
  String get fingerprint =>
      [name, phone, email, address, logoPath, gstin, businessType, businessCategory]
          .map((e) => e ?? '')
          .join('|');
}

/// A single visiting card rendered in the given [style].
///
/// Used both for the in-app preview and (wrapped in a RepaintBoundary) for
/// rendering to an image when sharing.
class VisitingCard extends StatelessWidget {
  final CardData data;
  final CardStyle style;

  const VisitingCard({super.key, required this.data, required this.style});

  @override
  Widget build(BuildContext context) {
    return switch (style) {
      CardStyle.classic => _ClassicCard(data: data),
      CardStyle.ethnic => _EthnicCard(data: data),
      CardStyle.gradient => _GradientCard(data: data),
    };
  }
}

// ── Shared pieces ─────────────────────────────────────────────

class _Logo extends StatelessWidget {
  final String? path;
  final Color borderColor;
  const _Logo({this.path, required this.borderColor});

  @override
  Widget build(BuildContext context) {
    if (path != null && File(path!).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(File(path!), width: 48, height: 48, fit: BoxFit.cover),
      );
    }
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add, size: 14, color: borderColor),
          Text('Logo', style: TextStyle(fontSize: 9, color: borderColor)),
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _ContactRow(this.icon, this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

List<Widget> _contactLines(CardData d, Color color) => [
      _ContactRow(Icons.phone, (d.phone?.isNotEmpty ?? false) ? d.phone! : 'Phone Number', color),
      _ContactRow(Icons.email_outlined, (d.email?.isNotEmpty ?? false) ? d.email! : 'Email ID', color),
      _ContactRow(Icons.location_on_outlined,
          (d.address?.isNotEmpty ?? false) ? d.address! : 'Business Address', color),
      if (d.gstin?.isNotEmpty ?? false) _ContactRow(Icons.receipt_long, 'GSTIN: ${d.gstin}', color),
      if (d.businessType?.isNotEmpty ?? false)
        _ContactRow(Icons.business_center_outlined, d.businessType!, color),
      if (d.businessCategory?.isNotEmpty ?? false)
        _ContactRow(Icons.category_outlined, d.businessCategory!, color),
    ];

// ── Classic (white) ───────────────────────────────────────────

class _ClassicCard extends StatelessWidget {
  final CardData data;
  const _ClassicCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))],
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.name.isEmpty ? 'My Company' : data.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.primary, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.only(left: 8),
                  decoration: const Border(
                    left: BorderSide(color: AppColors.primary, width: 3),
                  ).toBoxDecoration(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _contactLines(data, AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _Logo(path: data.logoPath, borderColor: AppColors.primary),
        ],
      ),
    );
  }
}

// ── Ethnic (dark maroon with mandala feel) ────────────────────

class _EthnicCard extends StatelessWidget {
  final CardData data;
  const _EthnicCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(
          colors: [Color(0xFF7B1E2B), Color(0xFF3D0E16), Color(0xFF7B1E2B)],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Logo(path: data.logoPath, borderColor: Colors.white70),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Text(
                    data.name.isEmpty ? 'My Company' : data.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 10),
                ..._contactLines(data, Colors.white70),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Gradient (sunset) ─────────────────────────────────────────

class _GradientCard extends StatelessWidget {
  final CardData data;
  const _GradientCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFA8C0FF), Color(0xFFFFE7C7), Color(0xFFFFB29A)],
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.name.isEmpty ? 'My Company' : data.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Color(0xFF3A3A3A), fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                ..._contactLines(data, const Color(0xFF4A4A4A)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _Logo(path: data.logoPath, borderColor: const Color(0xFF3A3A3A)),
        ],
      ),
    );
  }
}

extension on Border {
  BoxDecoration toBoxDecoration() => BoxDecoration(border: this);
}
