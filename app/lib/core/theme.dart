import 'package:flutter/material.dart';

ThemeData appTheme(Brightness mode) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff31695c),
    brightness: mode,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: mode == Brightness.light
        ? const Color(0xfff7f6ef)
        : scheme.surface,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.secondaryContainer,
    ),
  );
}

class StatusPanel extends StatelessWidget {
  final String message;
  final VoidCallback? retry;
  const StatusPanel(this.message, {super.key, this.retry});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (retry == null) const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
          if (retry != null)
            TextButton(onPressed: retry, child: const Text('重试')),
        ],
      ),
    ),
  );
}
