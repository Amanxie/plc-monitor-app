// 监控页报警行 / 报警灯 / 标题 的界面验证（需求 19、20、21）
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plc_app/comm_manager.dart';
import 'package:plc_app/main.dart';
import 'package:plc_app/models.dart';
import 'package:plc_app/store.dart';

Device makeDevice() => Device(
      id: 'dev_widget',
      name: '堆垛机测试',
      templateId: 'x',
      points: [
        PointItem(
            id: 'p1', name: '一层到位', address: 'I0.0',
            type: PointType.input, writable: false),
      ],
      alarms: [
        // 优先级 5 排在后面，优先级 0 排最前
        AlarmItem(id: 11, priority: 5, address: 'DB90.DBX315.0',
            triggerHigh: true, text: '行走测距仪掉线'),
        AlarmItem(id: 3, priority: 0, address: 'DB91.DBX3.0',
            triggerHigh: true, text: '地面PLC未收到机载PLC心跳，通信超时'),
        AlarmItem(id: 7, priority: 2, address: 'M186.6',
            triggerHigh: false, text: '货叉编码器掉线'),
      ],
      alarmLamp: 'M10.0',
    );

/// 挂载监控页（外部状态没有 setState，改动后要重新 pumpWidget 才会重建）
Future<void> pumpMonitor(WidgetTester tester, Device d) async {
  SharedPreferences.setMockInitialValues({'devices': jsonEncode([d.toJson()])});
  AppStore.instance.loaded = false;
  AppStore.instance.devices.clear();
  await tester.pumpWidget(MaterialApp(home: MonitorScreen(deviceId: d.id)));
  await tester.pump();
  await tester.pump();
}

/// 强制重建（模拟通讯回调触发界面刷新）
Future<void> repaint(WidgetTester tester, Device d) async {
  await tester.pumpWidget(MaterialApp(home: MonitorScreen(deviceId: d.id)));
  await tester.pump();
}

Finder marqueeWith(String part) =>
    find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains(part));

void main() {
  setUp(() {
    AppStore.instance.devices.clear();
    CommManager.instance.status.clear();
  });

  testWidgets('监控页画布标题「监控操作区域」+ 状态灯常驻', (tester) async {
    final d = makeDevice();
    final s = CommManager.instance.st(d.id);
    s.state = ConnState.connected;
    s.alarmRaw = {11: false, 3: false, 7: true};
    s.lampColor = 'gray';
    await pumpMonitor(tester, d);
    await repaint(tester, d);

    expect(find.text('监控操作区域'), findsOneWidget);
    expect(find.text('状态灯'), findsOneWidget);
    expect(find.textContaining('实时刷新'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('无报警时显示「无报警」', (tester) async {
    final d = makeDevice();
    final s = CommManager.instance.st(d.id);
    s.state = ConnState.connected;
    // 三条都不满足触发条件：11/3 需要 1 但为 0；7 需要 0 但为 1
    s.alarmRaw = {11: false, 3: false, 7: true};
    s.lampColor = 'gray';
    await pumpMonitor(tester, d);
    await repaint(tester, d);

    expect(find.text('无报警'), findsOneWidget);
    expect(find.text('0/3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('触发后按优先级排序显示「ID 内容」，并统计条数', (tester) async {
    final d = makeDevice();
    final s = CommManager.instance.st(d.id);
    s.state = ConnState.connected;
    // 11 触发、3 触发、7 不触发（位=1，触发值 0）
    s.alarmRaw = {11: true, 3: true, 7: true};
    s.lampColor = 'red';
    await pumpMonitor(tester, d);
    await repaint(tester, d);

    expect(find.text('2/3'), findsOneWidget);
    // 内容里同时出现 ID 和报警内容
    expect(marqueeWith('3　地面PLC未收到机载PLC心跳，通信超时'), findsOneWidget);
    expect(marqueeWith('11　行走测距仪掉线'), findsOneWidget);
    // 优先级 0 的 3 号排在 11 号前面
    final text = tester
        .widget<Text>(marqueeWith('地面PLC未收到机载PLC心跳'))
        .data!;
    expect(text.indexOf('3　地面PLC'), lessThan(text.indexOf('11　行走测距仪')));
    // 状态灯标签存在
    expect(find.text('状态灯'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('状态灯：红/黄/绿 地址亮对应颜色，未读到为灰', (tester) async {
    final d = makeDevice();
    final s = CommManager.instance.st(d.id);
    s.state = ConnState.connected;
    s.alarmRaw = {11: false, 3: false, 7: true};
    s.lampColor = 'red';
    await pumpMonitor(tester, d);
    await repaint(tester, d);

    Color? dotColor() {
      final c = tester.widget<Container>(
          find.byKey(const ValueKey('alarm_lamp_dot')));
      final deco = c.decoration;
      return deco is BoxDecoration ? deco.color : null;
    }

    expect(dotColor(), cRed);
    s.lampColor = 'yellow';
    await repaint(tester, d);
    expect(dotColor(), cAmber);
    s.lampColor = 'green';
    await repaint(tester, d);
    expect(dotColor(), cGreen);
    s.lampColor = 'gray';
    await repaint(tester, d);
    expect(dotColor(), const Color(0xFF3D464C));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('未连接时报警行提示不可用、状态灯不亮', (tester) async {
    final d = makeDevice();
    final s = CommManager.instance.st(d.id);
    s.state = ConnState.disconnected;
    s.lampColor = 'red'; // 即使上次读到 1，未连接也不能亮
    await pumpMonitor(tester, d);
    await repaint(tester, d);

    expect(find.text('未连接，报警状态不可用'), findsOneWidget);
    // 状态灯在未连接时是灰的，不能亮红灯
    final deco = tester
        .widget<Container>(find.byKey(const ValueKey('alarm_lamp_dot')))
        .decoration as BoxDecoration;
    expect(deco.color, isNot(cRed));
    expect(deco.color, isNot(cGreen));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('未导入报警表：报警行常驻显示占位提示', (tester) async {
    final d = makeDevice();
    d.alarms.clear();
    d.lampRed = '';
    d.alarmLamp = '';
    final s = CommManager.instance.st(d.id);
    s.state = ConnState.disconnected;
    await pumpMonitor(tester, d);
    await repaint(tester, d);

    expect(find.textContaining('未配置报警表'), findsOneWidget);
    expect(find.text('无报警'), findsNothing);
    // 状态灯常驻：未配置时也是灰点
    final deco = tester
        .widget<Container>(find.byKey(const ValueKey('alarm_lamp_dot')))
        .decoration as BoxDecoration;
    expect(deco.color, isNot(cRed));
    expect(deco.color, isNot(cGreen));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('需求10/12：报警列表只列触发的，不触发不显示、实时刷新',
      (tester) async {
    final d = makeDevice();
    final s = CommManager.instance.st(d.id);
    s.state = ConnState.connected;
    // 只有 11 号触发（7 号需要 0，给 1；3 号需要 1，给 0）
    s.alarmRaw = {11: true, 3: false, 7: true};
    s.lampColor = 'gray';
    await pumpMonitor(tester, d);
    await repaint(tester, d);

    // 点报警行行尾箭头进报警列表页（跑马灯文本重复两份、宽度超屏，中心点不可点）
    // 注意：跑马灯有循环动画，不能 pumpAndSettle（永不停止会超时）
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('报警列表'), findsOneWidget);
    expect(find.textContaining('触发 1 / 共 3 条'), findsOneWidget);
    // 需求12：只显示触发的 11 号，未触发的 3 号 / 7 号不出现
    expect(find.text('行走测距仪掉线'), findsOneWidget);
    expect(find.text('地面PLC未收到机载PLC心跳，通信超时'), findsNothing);
    expect(find.text('货叉编码器掉线'), findsNothing);
    expect(find.textContaining('ID 11 · 优先级 5 · DB90.DBX315.0'),
        findsOneWidget);
    expect(find.text('触发中'), findsOneWidget);
    expect(find.text('正常'), findsNothing);

    // 列表实时刷新：位值变化后全部不触发 → 列表清空并给出无报警提示
    s.alarmRaw = {11: false, 3: false, 7: true};
    CommManager.instance.notify(d.id);
    await tester.pump();
    expect(find.text('触发中'), findsNothing);
    expect(find.textContaining('当前无报警'), findsOneWidget);

    // 返回监控页
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('监控操作区域'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('需求10：报警列表页超过15条时滑动可见其余报警', (tester) async {
    final d = makeDevice();
    // 造 40 条报警
    d.alarms = List.generate(
        40,
        (i) => AlarmItem(
            id: i + 1,
            priority: 0,
            address: 'DB91.DBX${i}.0',
            triggerHigh: true,
            text: '报警内容第${i + 1}条'));
    final s = CommManager.instance.st(d.id);
    s.state = ConnState.connected;
    // 40 条全部触发（需求12：只有触发的才进列表）
    s.alarmRaw = {for (int i = 1; i <= 40; i++) i: true};
    await pumpMonitor(tester, d);
    await repaint(tester, d);
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.textContaining('触发 40 / 共 40 条'), findsOneWidget);
    // 首屏只渲染可见的十几条，第 1 条可见、第 40 条暂时不在树上
    expect(find.text('报警内容第1条'), findsOneWidget);
    expect(find.text('报警内容第40条'), findsNothing);
    // 滑到底部，第 40 条出现
    await tester.scrollUntilVisible(
        find.text('报警内容第40条'), 400,
        scrollable: find
            .descendant(
                of: find.byType(AlarmListPage),
                matching: find.byType(Scrollable))
            .first);
    expect(find.text('报警内容第40条'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
