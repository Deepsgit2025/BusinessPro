import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_strings.dart';
import '../../core/providers/business_provider.dart';
import '../../features/dashboard/screens/dashboard_screen.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../../features/transactions/screens/sale_list_screen.dart';
import '../../features/transactions/screens/purchase_list_screen.dart';
import '../../features/parties/screens/parties_screen.dart';
import 'app_drawer.dart';

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _selectedIndex = 0;
  bool _searching = false;
  final _searchController = TextEditingController();

  static const _screens = <Widget>[
    DashboardScreen(),
    SaleListScreen(),
    PurchaseListScreen(),
    PartiesScreen(),
  ];

  static const _titles = <String>[
    AppStrings.navSale,
    AppStrings.navPurchase,
    AppStrings.navParties,
  ];

  // Dashboard (0) has no FAB; Parties (3) provides its own FAB + search.
  // Sale (1) and Purchase (2) each show a + FAB to create a new bill/invoice.
  // Search is Sale-only — Purchase (2) is an action-grid landing page.
  bool get _showFab => _selectedIndex == 1 || _selectedIndex == 2;
  bool get _showSearch => _selectedIndex == 1;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _titleFor(int index) {
    if (index == 0) {
      final name = ref.watch(businessProvider).valueOrNull?['name'] as String?;
      return (name != null && name.trim().isNotEmpty) ? name : AppStrings.appName;
    }
    return _titles[index - 1];
  }

  void _applySearch(String value) {
    if (_selectedIndex == 1) {
      final f = ref.read(saleFilterProvider);
      ref.read(saleFilterProvider.notifier).state = f.copyWith(search: value);
    } else if (_selectedIndex == 2) {
      final f = ref.read(purchaseFilterProvider);
      ref.read(purchaseFilterProvider.notifier).state =
          f.copyWith(search: value);
    }
  }

  void _stopSearching() {
    _searchController.clear();
    _applySearch('');
    setState(() => _searching = false);
  }

  void _onTabChange(int i) {
    if (_searching) _stopSearching();
    setState(() => _selectedIndex = i);
  }

  Future<void> _onFab() async {
    if (_selectedIndex == 1) {
      await SaleListScreen.openCreateSheet(context, ref);
    } else if (_selectedIndex == 2) {
      await PurchaseListScreen.openCreate(context, ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.white,
                decoration: const InputDecoration(
                  hintText: 'Search…',
                  hintStyle: TextStyle(color: Colors.white70),
                  border: InputBorder.none,
                ),
                onChanged: _applySearch,
              )
            : Text(_titleFor(_selectedIndex)),
        actions: _showSearch
            ? [
                IconButton(
                  icon: Icon(_searching ? Icons.close : Icons.search),
                  onPressed: () {
                    if (_searching) {
                      _stopSearching();
                    } else {
                      setState(() => _searching = true);
                    }
                  },
                ),
              ]
            : null,
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      floatingActionButton: _showFab
          ? FloatingActionButton(
              backgroundColor: AppColors.primary,
              onPressed: _onFab,
              child: const Icon(Icons.add, color: Colors.white),
            )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onTabChange,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_outlined),
            activeIcon: Icon(Icons.dashboard),
            label: AppStrings.navDashboard,
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long_outlined),
            activeIcon: Icon(Icons.receipt_long),
            label: AppStrings.navSale,
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.shopping_cart_outlined),
            activeIcon: Icon(Icons.shopping_cart),
            label: AppStrings.navPurchase,
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.people_outline),
            activeIcon: Icon(Icons.people),
            label: AppStrings.navParties,
          ),
        ],
      ),
    );
  }
}
