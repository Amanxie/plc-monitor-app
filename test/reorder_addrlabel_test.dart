// 需求 32/33：案例长按拖动排序（模型侧顺序持久化）+ 状态显示点击 名称⇄地址 切换
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plc_app/main.dart';
import 'package:plc_app/models.dart';

void main() {
  test('需求33：addrLabels 随案例保存与恢复', () {
    final d = Device(id: 'd1', name: '测试', templateId: 'x');
    d.addrLabels = ['p1', 'p2'];
    final j = d.toJson();
    expect(j['addrLabels'], ['p1', 'p2']);
    final d2 = Device.fromJson(j);
    expect(d2.addrLabels, ['p1', 'p2']);
    // 老存档没有该字段：默认空，不报错
    final d3 = Device.fromJson({'id': 'd', 'name': 'n', 'templateId': 'x'});
    expect(d3.addrLabels, isEmpty);
    // 空集合不写进 JSON，保持存档干净
    final d4 = Device(id: 'd2', name: 't2', templateId: 'x');
    expect(d4.toJson().containsKey('addrLabels'), isFalse);
  });

  testWidgets('需求33：状态显示控件点击 名称⇄地址 切换，再点还原', (tester) async {
    final pts = [
      PointItem(id: 'p1', name: '一层到位', address: 'I0.0',
          type: PointType.input, writable: false),
    ];
    normalizeLayout(pts);
    final ids = <String>{};

    Future<void> pump() async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360, height: 600,
              child: MonitorCanvas(
                points: pts,
                addrLabelIds: ids.toSet(),
                onToggleAddrLabel: (p) =>
                    ids.contains(p.id) ? ids.remove(p.id) : ids.add(p.id),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    await pump();
    // 默认显示名称
    expect(find.text('一层到位'), findsOneWidget);

    // 点击状态块 → 名称变地址
    await tester.tap(find.text('一层到位'));
    await pump();
    expect(find.text('I0.0'), findsOneWidget);
    expect(find.text('一层到位'), findsNothing);

    // 再点 → 还原名称
    await tester.tap(find.text('I0.0'));
    await pump();
    expect(find.text('一层到位'), findsOneWidget);
    expect(find.text('I0.0'), findsNothing);
  });

  testWidgets('需求33：不传回调（预览/编辑器）时状态块点击无手势、不切换', (tester) async {
    final pts = [
      PointItem(id: 'p1', name: '一层到位', address: 'I0.0',
          type: PointType.input, writable: false),
    ];
    normalizeLayout(pts);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360, height: 600,
            child: MonitorCanvas(points: pts),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('一层到位'), warnIfMissed: false);
    await tester.pump();
    // 没有回调：仍然显示名称
    expect(find.text('一层到位'), findsOneWidget);
  });
}
