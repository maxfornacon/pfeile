import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pfeile/main.dart';

void main() {
  testWidgets('Game screen smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MyApp(),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Tap free arrow'), findsOneWidget);
    expect(find.text('New Game'), findsOneWidget);
  });
}
