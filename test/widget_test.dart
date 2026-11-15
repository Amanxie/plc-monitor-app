import 'package:flutter_test/flutter_test.dart';
import 'package:plc_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // 冒烟：App 起得来、首帧不抛异常。
  // 授权页依赖本机设备码（原生通道），测试环境拿不到，所以只验到挂载这一层。
  testWidgets('App 可挂载并渲染首帧', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PlcApp());
    await tester.pump();
    expect(find.byType(PlcApp), findsOneWidget);
  });
}
