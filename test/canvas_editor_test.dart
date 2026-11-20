// 需求 22~27：画布渲染、布局编辑器、十字按钮、状态灯
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plc_app/comm_manager.dart';
import 'package:plc_app/main.dart';
import 'package:plc_app/models.dart';

void main() {
  Device makeDevice() => Device(
        id: 'dev_canvas', name: '画布测试', templateId: 'x',
        points: [
          PointItem(id: 'p1', name: '一层到位', address: 'I0.0',
              type: PointType.input, writable: false),
          PointItem(id: 'p2', name: '复位按钮', address: 'M20.0',
              type: PointType.output, writable: true),
          PointItem(id: 'p3', name: '行走十字', address: 'M0.0',
              type: PointType.output, writable: false, ctrl: 'cross',
              dirs: {'fwd': 'M30.0', 'back': 'M30.1',
                  'left': 'M30.2', 'right': 'M30.3'}),
        ],
      );

  // 画布布局需要真实约束：挂进固定尺寸容器
  Future<void> pumpCanvas(WidgetTester tester, List<PointItem> pts,
      {DeviceStatus? status, bool connected = false}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360, height: 600,
            child: MonitorCanvas(points: pts, status: status, connected: connected),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  test('需求22：字节地址支持 4 位（I6666.6 解析与显示）', () {
    final p = PointItem(id: 'x', name: '大地址', address: 'I6666.6',
        type: PointType.input, writable: false);
    expect(p.ioLocked, isTrue);
    expect(p.roleLabel, '状态显示');
  });

  testWidgets('监控画布渲染状态/按钮/十字控件；需求9无手型图标、需求11无提示词、'
      '需求12无ON/OFF文字、需求13无地址行', (tester) async {
    final d = makeDevice();
    normalizeLayout(d.points);
    final s = CommManager.instance.st(d.id);
    s.state = ConnState.connected;
    s.values['p1'] = true;
    await pumpCanvas(tester, d.points, status: s, connected: true);

    // 状态显示控件：名称渲染；BOOL 不再显示 ON/OFF 文字（需求 12）
    expect(find.text('一层到位'), findsOneWidget);
    expect(find.text('ON'), findsNothing);
    expect(find.text('OFF'), findsNothing);
    // 需求 13：监控页画布不显示地址行
    expect(find.textContaining('I0.0'), findsNothing);
    // 需求 9：按钮无手型图标
    expect(find.byIcon(Icons.touch_app), findsNothing);
    // 需求 11：输入域无「点按写 0 / 1 / 点按输入数值」提示
    expect(find.textContaining('点按'), findsNothing);
    // 点动按钮（需求 24-1 按钮观感）：名称渲染
    expect(find.text('复位按钮'), findsOneWidget);
    // 十字按钮（需求 24-2）：四个脚 前/后/左/右
    expect(find.text('前'), findsOneWidget);
    expect(find.text('后'), findsOneWidget);
    expect(find.text('左'), findsOneWidget);
    expect(find.text('右'), findsOneWidget);
    expect(find.text('行走十字'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('编辑器画布显示地址行；预览/监控页不显示（需求 13）', (tester) async {
    final d = makeDevice();
    normalizeLayout(d.points);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 380,
            child: MonitorCanvas(points: d.points, showAddr: true),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('I0.0'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('选中控件拖四边改宽高（需求 8）', (tester) async {
    final d = makeDevice();
    normalizeLayout(d.points);
    final p = d.points.first;
    var changed = 0;
    String? selId;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (ctx, setS) => Scaffold(
        body: SingleChildScrollView(
          child: LayoutEditor(
            points: d.points,
            selectedId: selId,
            onSelect: (id) => setS(() => selId = id),
            onChanged: () => changed++,
            onEditDetail: (_) async {},
            onAddButton: () {},
            onAddStatus: () {},
            onAddCross: () {},
          ),
        ),
      )),
    ));
    await tester.pump();
    await tester.pump();
    // 先选中第一个控件（双击选中）
    await tester.tap(find.text(p.name));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text(p.name));
    await tester.pump();
    final w0 = p.w;
    // 按住右边拖拽条向右拖 → 宽度增大
    final edge = find.byKey(ValueKey('edge_right_${p.id}'));
    expect(edge, findsOneWidget);
    await tester.dragFrom(tester.getCenter(edge), const Offset(80, 0));
    await tester.pump();
    expect(p.w, greaterThan(w0), reason: '拖右边缘条改宽度');
    final h0 = p.h;
    final bottom = find.byKey(ValueKey('edge_bottom_${p.id}'));
    await tester.dragFrom(tester.getCenter(bottom), const Offset(0, 60));
    await tester.pump();
    expect(p.h, greaterThan(h0), reason: '拖下边缘条改高度');
    expect(changed, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 350)); // 双击后挂起计时器
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('布局编辑器：未选中提示 → 点画布选中 → 属性面板显示（需求23-3/4）',
      (tester) async {
    final d = makeDevice();
    normalizeLayout(d.points);
    var changed = 0;
    String? selId;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (ctx, setS) => Scaffold(
        body: SingleChildScrollView(
          child: LayoutEditor(
            points: d.points,
            selectedId: selId,
            onSelect: (id) => setS(() => selId = id),
            onChanged: () => changed++,
            onEditDetail: (_) async {},
            onAddButton: () {},
            onAddStatus: () {},
            onAddCross: () {},
          ),
        ),
      )),
    ));
    await tester.pump();
    await tester.pump();

    // 未选中：提示文案
    expect(find.textContaining('未选中控件'), findsOneWidget);
    // 双击画布里的状态控件（名称）→ 属性面板出现
    await tester.tap(find.text('一层到位'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('一层到位'));
    await tester.pump();
    expect(find.text('控件属性'), findsOneWidget);
    expect(find.textContaining('未选中控件'), findsNothing);

    // 改宽高（需求 23-5）：数值输入改变控件框体，文字大小不变
    final p = d.points.first;
    final wCtrl = tester.widgetList<TextField>(find.byType(TextField))
        .firstWhere((f) => f.controller!.text == '${p.w.round()}');
    wCtrl.controller!.text = '300';
    wCtrl.onChanged!('300');
    await tester.pump();
    expect(p.w, 300, reason: '宽度数值实时生效');
    expect(changed, greaterThan(0));

    // 名称实时编辑
    final nameCtrl = tester.widgetList<TextField>(find.byType(TextField))
        .firstWhere((f) => f.controller!.text == p.name);
    nameCtrl.controller!.text = '一层到位改';
    nameCtrl.onChanged!('一层到位改');
    await tester.pump();
    expect(p.name, '一层到位改');

    // 点画布空白处 = 取消选中（提示文案回归，属性面板消失）
    await tester.tapAt(tester.getTopLeft(find.byType(MonitorCanvas)) +
        const Offset(10, 10));
    await tester.pump();
    expect(find.text('控件属性'), findsNothing);
    expect(find.textContaining('未选中控件'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 350)); // 双击后挂起计时器
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('布局编辑器：十字按钮选中后显示四脚地址输入（需求24-2）', (tester) async {
    final d = makeDevice();
    normalizeLayout(d.points);
    String? selId;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (ctx, setS) => Scaffold(
        body: SingleChildScrollView(
          child: LayoutEditor(
            points: d.points,
            selectedId: selId,
            onSelect: (id) => setS(() => selId = id),
            onChanged: () {},
            onEditDetail: (_) async {},
            onAddButton: () {},
            onAddStatus: () {},
            onAddCross: () {},
          ),
        ),
      )),
    ));
    await tester.pump();
    await tester.pump();

    // 选十字按钮（模拟点画布 → onSelect 更新页面级选中）
    final cross = d.points.where((p) => p.isCross).first;
    final MonitorCanvas canvas =
        tester.widget(find.byType(MonitorCanvas));
    canvas.onTapCtrl!.call(cross);
    await tester.pump();

    expect(find.text('控件属性'), findsOneWidget);
    expect(find.text('前'), findsWidgets); // 画布脚 + 属性面板行
    expect(find.text('后'), findsWidgets);
    expect(find.text('左'), findsWidgets);
    expect(find.text('右'), findsWidgets);
    // 详细编辑入口
    expect(find.text('详细编辑（地址/类型）'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('新增十字按钮默认带前/后/左/右四脚（需求24-2）', (tester) async {
    final d = Device(id: 'x', name: 'n', templateId: 't', points: []);
    final added = <PointItem>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LayoutEditor(
          points: d.points,
          selectedId: null,
          onSelect: (_) {},
          onChanged: () {},
          onEditDetail: (_) async {},
          onAddButton: () {},
          onAddStatus: () {},
          onAddCross: () {
            d.points.add(PointItem(
                id: 'cx1', name: '十字按钮', address: 'M0.0',
                type: PointType.output, writable: false, ctrl: 'cross'));
            added.addAll(d.points);
          },
        ),
      ),
    ));
    await tester.pump();
    // 点工具栏 + 十字
    await tester.tap(find.text('+ 十字'));
    await tester.pump();
    expect(added, isNotEmpty);
    expect(added.first.isCross, isTrue);
    // 模拟父级 setState：重新挂载让画布渲染新控件
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LayoutEditor(
          points: d.points,
          selectedId: null,
          onSelect: (_) {},
          onChanged: () {},
          onEditDetail: (_) async {},
          onAddButton: () {},
          onAddStatus: () {},
          onAddCross: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('前'), findsOneWidget);
    expect(find.text('后'), findsOneWidget);
    expect(find.text('左'), findsOneWidget);
    expect(find.text('右'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('老存档迁移：点位自动补尺寸与位置', () {
    final pts = [
      PointItem(id: 'a', name: 'A', address: 'I0.0',
          type: PointType.input, writable: false),
      PointItem(id: 'b', name: 'B', address: 'M0.0',
          type: PointType.output, writable: true),
    ];
    normalizeLayout(pts);
    expect(pts[0].w, greaterThan(0));
    expect(pts[0].x, greaterThanOrEqualTo(0));
    // 纵向排布不重叠
    expect(pts[1].y, pts[0].y + pts[0].h + 8);
    // 画布高度覆盖全部
    expect(canvasHeight(pts), greaterThanOrEqualTo(pts[1].y + pts[1].h));
  });

  testWidgets('预览页可打开并渲染画布（需求23-6/7）', (tester) async {
    final d = makeDevice();
    normalizeLayout(d.points);
    var changed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) => Center(child: ElevatedButton(
          onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
            builder: (_) => LayoutPreviewPage(points: d.points, onChanged: () => changed++),
          )),
          child: const Text('open'),
        ))),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('预览'), findsWidgets);
    expect(find.text('一层到位'), findsOneWidget);
    expect(find.text('前'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
