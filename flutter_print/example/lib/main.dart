import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'print_page.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_print example',
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [
        Locale('en'),
        Locale('fr'),
        Locale('de'),
        Locale('es'),
        Locale('pt'),
        Locale('it'),
        Locale('nl'),
        Locale('ru'),
        Locale('pl'),
        Locale('tr'),
        Locale('ja'),
        Locale('zh'),
        Locale('ko'),
        Locale('ar'),
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const PrintPage(),
    );
  }
}
