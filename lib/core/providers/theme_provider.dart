import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database_helper.dart';
import '../constants/app_strings.dart';

class ThemeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    // Load the saved theme exactly once, when the provider is first created.
    // (Previously this was kicked off from MaterialApp.build via a post-frame
    // callback — but because build() also watched this provider, each load
    // mutated the state, rebuilt the root, scheduled another load, and looped
    // forever: the whole-app "blinking" on every screen.)
    loadFromDb();
    return ThemeMode.light;
  }

  Future<void> loadFromDb() async {
    final val = await DatabaseHelper.getSettingStr(AppStrings.kTheme, defaultVal: 'light');
    final next = val == 'dark' ? ThemeMode.dark : ThemeMode.light;
    // Only emit when it actually changes, so a no-op load can't trigger an
    // unnecessary rebuild.
    if (state != next) state = next;
  }

  Future<void> toggle() async {
    final next = state == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    state = next;
    await DatabaseHelper.setSetting(AppStrings.kTheme, next == ThemeMode.dark ? 'dark' : 'light');
  }
}

final themeProvider = NotifierProvider<ThemeNotifier, ThemeMode>(ThemeNotifier.new);
