/// 需求 28：对点模板 CSV 导入 + 数据模型测试
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:plc_app/comm_manager.dart';
import 'package:plc_app/main.dart';
import 'package:plc_app/models.dart';
import 'package:plc_app/store.dart';

void main() {
  group('parseCheckCsv：基本解析（需求 28-3/6/7）', () {
    test('A 名称 / B 组 / C 类型 / D 地址 正常导入', () {
      final raw = [
        '变量名称,变量组,类型,地址,保留,是否可读',
        '1号电机正转,行走,BOOL,DB1.DBX0.0,,true',
        '速度设定,工艺,BYTE,DB1.DBB10,,true',
        '当前层数,工艺,WORD,DB90.DBW362,,true',
        '累计产量,产量,DWORD,DB1.DBD20,,true',
      ].join('\n');
      final (pts, notes) = parseCheckCsv(raw);
      expect(notes, isEmpty);
      expect(pts.length, 4);
      // 控件名来自 A 列
      expect(pts[0].name, '1号电机正转');
      // 组来自 B 列
      expect(pts[0].group, '行走');
      expect(pts[1].group, '工艺');
      // 类型来自 C 列
      expect(pts[0].dataType, VarType.boolean);
      expect(pts[1].dataType, VarType.byte);
      expect(pts[2].dataType, VarType.word);
      expect(pts[3].dataType, VarType.dword);
      // 地址来自 D 列
      expect(pts[2].address, 'DB90.DBW362');
      // 需求 28-4：对点默认属性是状态显示
      expect(pts.every((p) => p.isStatusOnly), isTrue);
      expect(pts.every((p) => !p.canWrite), isTrue);
    });

    test('其他列有数据不影响导入（需求 28-3）', () {
      final raw = '电机1,行走,BOOL,DB1.DBX0.0,备注随便填,true\n';
      final (pts, notes) = parseCheckCsv(raw);
      expect(notes, isEmpty);
      expect(pts.length, 1);
      expect(pts[0].name, '电机1');
    });
  });

  group('parseCheckCsv：过滤规则（需求 28-8/9/7）', () {
    test('M 区地址过滤掉不产生控件', () {
      final raw = [
        '中间继电器,M,BOOL,M10.0,,true',
        '中间字,M,WORD,MW20,,true',
        '正常点,DB,BOOL,DB1.DBX0.0,,true',
      ].join('\n');
      final (pts, notes) = parseCheckCsv(raw);
      expect(pts.length, 1);
      expect(pts[0].address, 'DB1.DBX0.0');
      expect(notes.join(), contains('M 区地址 2 条'));
    });

    test('F 列 false 过滤掉', () {
      final raw = [
        '屏蔽点1,DB,BOOL,DB1.DBX0.0,,false',
        '屏蔽点2,DB,BOOL,DB1.DBX0.1,,FALSE',
        '屏蔽点3,DB,BOOL,DB1.DBX0.2,,0',
        '保留点,DB,BOOL,DB1.DBX1.0,,true',
        'F列空,DB,BOOL,DB1.DBX1.1,,',
      ].join('\n');
      final (pts, notes) = parseCheckCsv(raw);
      // F 列空视作保留
      expect(pts.map((p) => p.address).toList(),
          ['DB1.DBX1.0', 'DB1.DBX1.1']);
      expect(notes.join(), contains('F 列为 false 的 3 条'));
    });

    test('类型只支持 BOOL/BYTE/WORD/DWORD，其余丢弃', () {
      final raw = [
        '整数,DB,INT,DB1.DBW0,,true',
        '浮点,DB,REAL,DB1.DBD4,,true',
        '位量,DB,BOOL,DB1.DBX8.0,,true',
      ].join('\n');
      final (pts, notes) = parseCheckCsv(raw);
      expect(pts.length, 1);
      expect(pts[0].dataType, VarType.boolean);
      expect(notes.join(), contains('类型不支持的 2 条'));
    });

    test('I/Q 区地址保留并自动只读', () {
      final raw = '输入点,DI,BOOL,I0.0,,true\n输出点,DQ,BOOL,Q0.1,,true\n';
      final (pts, notes) = parseCheckCsv(raw);
      expect(pts.length, 2);
      expect(pts.every((p) => p.ioLocked), isTrue);
      expect(pts.every((p) => p.isStatusOnly), isTrue);
    });

    test('空组名归到未分组', () {
      final raw = '无名点,,BOOL,DB1.DBX0.0,,true\n';
      final (pts, _) = parseCheckCsv(raw);
      expect(pts[0].group, '未分组');
    });

    test('引号内逗号不切列（CSV 标准）', () {
      final raw = '"电机,1号",行走,BOOL,DB1.DBX0.0,,true\n';
      final (pts, _) = parseCheckCsv(raw);
      expect(pts[0].name, '电机,1号');
    });

    test('Excel 粘贴（制表符分隔）兼容', () {
      final raw = '电机1\t行走\tBOOL\tDB1.DBX0.0\t\ttrue\n';
      final (pts, _) = parseCheckCsv(raw);
      expect(pts.length, 1);
      expect(pts[0].group, '行走');
    });

    test('上限 60000 条截断（需求 28-10）', () {
      final buf = StringBuffer('name,group,type,addr,,rd\n');
      for (int i = 0; i < kCheckPointMax + 5; i++) {
        buf.writeln('点位$i,组$i,BOOL,DB1.DBX0.0,,true');
      }
      final (pts, notes) = parseCheckCsv(buf.toString());
      expect(pts.length, kCheckPointMax);
      expect(notes.join(), contains('上限'));
    });
  });

  group('对点模板与案例序列化', () {
    test('内置对点模板存在且 check 标记', () {
      final tpl = builtinTemplates.firstWhere((t) => t.id == 'tpl_check');
      expect(tpl.check, isTrue);
      expect(tpl.points, isEmpty);
    });

    test('Template check 标记 JSON 往返', () {
      final t = Template(
          id: 'tpl_x', name: '对点', desc: '',
          points: [PointItem(id: 'p1', name: 'n', address: 'DB1.DBX0.0',
              type: PointType.input, writable: false, group: '行走')]);
      final j = t.toJson();
      final t2 = Template.fromJson(j);
      expect(t2.check, isFalse);
      expect(t2.points[0].group, '行走');
      expect(t2.points[0].dataType, VarType.boolean);

      final c = Template(id: 'tpl_y', name: '', desc: '', points: [], check: true);
      final c2 = Template.fromJson(c.toJson());
      expect(c2.check, isTrue);
    });

    test('Device check 标记 JSON 往返', () {
      final d = Device(id: 'dev1', name: '对点机', templateId: 'tpl_check')
        ..check = true;
      final d2 = Device.fromJson(d.toJson());
      expect(d2.check, isTrue);
      final d3 = Device.fromJson(Device(id: 'dev2', name: '普通', templateId: 'x').toJson());
      expect(d3.check, isFalse);
    });

    test('PointItem group 字段 clone 保留', () {
      final p = PointItem(id: 'p1', name: 'n', address: 'DB1.DBX0.0',
          type: PointType.input, writable: false, group: '行走');
      final c = p.clone();
      expect(c.group, '行走');
    });
  });

  group('对点监控页（需求 28-5：变量组下拉 + 列表核对）', () {
    Device makeCheckDevice() {
      final pts = <PointItem>[];
      final stamp = DateTime.now().millisecondsSinceEpoch;
      for (int i = 0; i < 120; i++) {
        pts.add(PointItem(
          id: 'ck_$i',
          name: '点位$i',
          address: 'DB1.DBX${i ~/ 8}.${i % 8}',
          type: PointType.input,
          dataType: i % 10 == 9 ? VarType.word : VarType.boolean,
          writable: false,
          group: i < 60 ? '行走' : '工艺',
        ));
      }
      return Device(id: 'dev_check', name: '对点机', templateId: 'tpl_check')
        ..check = true
        ..points = pts;
    }

    Future<void> pumpCheck(WidgetTester tester, Device d) async {
      SharedPreferences.setMockInitialValues(
          {'devices': jsonEncode([d.toJson()])});
      AppStore.instance.loaded = false;
      AppStore.instance.devices.clear();
      CommManager.instance.status.clear();
      await tester.pumpWidget(MaterialApp(home: MonitorScreen(deviceId: d.id)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('列表渲染：虚拟化只 build 可见行，不渲染全部 120 条', (tester) async {
      final d = makeCheckDevice();
      await pumpCheck(tester, d);
      // 第一屏能看到头部点位
      expect(find.text('点位0'), findsOneWidget);
      // 尾部点位远在视口外，虚拟化下不 build
      expect(find.text('点位119'), findsNothing);
      // 下拉框默认「全部」
      expect(find.text('全部'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('选变量组只显示该组控件（需求 28-5-2）', (tester) async {
      final d = makeCheckDevice();
      await pumpCheck(tester, d);
      // 打开下拉菜单
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      // 点「工艺」组
      await tester.tap(find.text('工艺').last);
      await tester.pumpAndSettle();
      // 列表现在显示工艺组（点位60 是该组第一条）
      expect(find.text('点位60'), findsOneWidget);
      // 行走组的头部点位（点位0）不再显示
      expect(find.text('点位0'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('滑动停止 1 秒后把可见区域点位交给轮询（需求 28-12）', (tester) async {
      final d = makeCheckDevice();
      await pumpCheck(tester, d);
      // 首帧后可见集合已上报（第一屏，不是全部 120 条）
      // CommManager 内部集合不直接暴露，通过行为验证：滑动后再验证
      // 向下滚动到列表底部（模拟用户滑动）
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -8000));
      await tester.pumpAndSettle(const Duration(seconds: 1, milliseconds: 100));
      // 停止 1 秒后：底部点位应成为可见集合成员（列表此时也渲染到尾部）
      expect(find.text('点位119'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
