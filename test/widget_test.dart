// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:emergenciaconecta/main.dart';

void main() {
  // Comprueba que la pantalla principal presenta los controles del reporte.
  testWidgets('Muestra el formulario para reportar una emergencia', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const EmergenciaConectaApp());
    await tester.pump();

    expect(find.text('Emergencia Conecta'), findsOneWidget);
    expect(find.text('Nombre del usuario'), findsOneWidget);
    expect(find.text('Reportar emergencia'), findsOneWidget);
  });
}
