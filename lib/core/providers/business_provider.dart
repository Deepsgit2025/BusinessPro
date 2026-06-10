import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database_helper.dart';

class BusinessNotifier extends AsyncNotifier<Map<String, dynamic>?> {
  @override
  Future<Map<String, dynamic>?> build() async => DatabaseHelper.getBusiness();

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await DatabaseHelper.getBusiness());
  }

  Future<void> save(Map<String, dynamic> data) async {
    await DatabaseHelper.updateBusiness(data);
    await DatabaseHelper.setSetting('company_setup_done', '1');
    state = AsyncData(await DatabaseHelper.getBusiness());
  }
}

final businessProvider = AsyncNotifierProvider<BusinessNotifier, Map<String, dynamic>?>(
  BusinessNotifier.new,
);
