import 'package:flutter_test/flutter_test.dart';
import 'package:plc_app/main.dart';

void main() {
  testWidgets('首页渲染冒烟测试', (tester) async {
    await tester.pumpWidget(const PlcApp());
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('设备'), findsOneWidget);
  });
}
