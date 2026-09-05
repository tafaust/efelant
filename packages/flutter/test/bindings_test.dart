import 'package:efelant_flutter/efelant.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stencil catalog lists the six public tags', () {
    expect(
      stencilComponentCatalog.map((c) => c.tag),
      containsAll([
        'efelant-conversation',
        'efelant-composer',
        'efelant-context-feed',
        'efelant-conversation-list',
        'efelant-status-event',
        'efelant-unread-badge',
      ]),
    );
  });

  testWidgets('generated conversation facade matches stencil props', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: EfelantConversationElement(
          tenantId: 't1',
          contextType: 'ticket',
          externalId: 'T-1',
        ),
      ),
    );
    expect(find.byType(EfelantConversation), findsOneWidget);
  });

  test('secondary theme is light paper', () {
    final theme = buildEfelantTheme(theme: EfelantThemeId.secondary);
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, EfelantTokensSecondary.colorBg);
    expect(theme.colorScheme.primary, EfelantTokensSecondary.colorAccent);
  });
}
