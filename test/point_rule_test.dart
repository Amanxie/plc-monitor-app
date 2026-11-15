/// 两条硬规则的单元测试（纯 Dart，不碰 Flutter 界面）
///
/// 1. 案例与模板解耦：点位的克隆必须互不影响，旧配置里的地址覆盖表要能读出来做迁移
/// 2. I / Q 区只读：无论点位被标成什么控件，落在 I/Q 区就只能当状态显示
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:plc_app/models.dart';

void main() {
  group('地址区判定', () {
    test('I 区各种写法都判为只读', () {
      for (final a in ['I0.0', 'i0.0', '%I0.0', ' I0.0 ', 'IB2', 'IW10', 'ID4']) {
        expect(isForcedReadOnlyAddress(a), isTrue, reason: a);
      }
    });

    test('Q 区也判为只读', () {
      for (final a in ['Q0.0', '%Q0.1', 'q0.3', 'QB2', 'QD0']) {
        expect(isForcedReadOnlyAddress(a), isTrue, reason: a);
      }
    });

    test('M 区 / DB 区可写', () {
      for (final a in ['M0.0', 'MW10', 'MD0', 'DB1.DBX0.0', 'DB1.DBW2']) {
        expect(isForcedReadOnlyAddress(a), isFalse, reason: a);
      }
    });

    test('区域归属', () {
      expect(addrAreaOf('I0.0'), 'I');
      expect(addrAreaOf('%Q1.2'), 'Q');
      expect(addrAreaOf('MW10'), 'M');
      expect(addrAreaOf('DB1.DBW0'), 'DB');
    });
  });

  group('控件性质', () {
    test('Q 区即使标成点动按钮，也只算状态显示', () {
      final p = PointItem(
          id: 'p1', name: '上升按钮', address: 'Q0.0', type: PointType.output);
      expect(p.ioLocked, isTrue);
      expect(p.isJogButton, isFalse);
      expect(p.isStatusOnly, isTrue);
      expect(p.canWrite, isFalse);
      expect(p.roleLabel, '状态显示');
    });

    test('enforceReadOnlyRule 把 I/Q 点降级成只读输入，且幂等', () {
      final p = PointItem(
          id: 'p', name: 'x', address: 'Q0.1', type: PointType.output);
      expect(p.enforceReadOnlyRule(), isTrue);
      expect(p.type, PointType.input);
      expect(p.writable, isFalse);
      expect(p.enforceReadOnlyRule(), isFalse);
    });

    test('M 区点动按钮正常可用', () {
      final p = PointItem(
          id: 'p', name: '上升', address: 'M0.0', type: PointType.output);
      expect(p.isJogButton, isTrue);
      expect(p.canWrite, isTrue);
      expect(p.roleLabel, '点动按钮');
    });

    test('M 区输入域可写，DB 区数值点可写', () {
      final b = PointItem(
          id: 'b', name: '使能', address: 'M10.0', type: PointType.input);
      expect(b.isInputField, isTrue);
      final n = PointItem(
          id: 'n',
          name: '速度',
          address: 'DB1.DBW2',
          type: PointType.input,
          dataType: VarType.int16);
      expect(n.canWrite, isTrue);
    });

    test('出厂模板里的点位全部只读（没有 Q 区按钮）', () {
      for (final t in builtinTemplates) {
        for (final p in t.points) {
          expect(p.canWrite, isFalse, reason: '${t.name} / ${p.address}');
          expect(p.isJogButton, isFalse, reason: '${t.name} / ${p.address}');
        }
      }
    });
  });

  group('案例点位副本', () {
    test('clone 出来的点位改动不影响原件', () {
      final src = PointItem(
          id: 'p1',
          name: '一层到位',
          address: 'I0.0',
          type: PointType.input,
          writable: false);
      final copy = src.clone()..address = 'I1.0';
      copy.name = '改过的';
      expect(src.address, 'I0.0');
      expect(src.name, '一层到位');
    });

    test('Device 序列化带上自己的点位', () {
      final d = Device(
        id: 'dev1',
        name: '一号梯',
        templateId: 'tpl_lift',
        sourceTemplate: '升降机',
        points: [
          PointItem(
              id: 'p1',
              name: '一层到位',
              address: 'I0.0',
              type: PointType.input,
              writable: false),
          PointItem(
              id: 'p2',
              name: '上升输出',
              address: 'Q0.0',
              type: PointType.input,
              writable: false),
        ],
      );
      final back = Device.fromJson(d.toJson());
      expect(back.points.length, 2);
      expect(back.points.first.address, 'I0.0');
      expect(back.sourceTemplate, '升降机');
    });

    test('旧版配置（只有 addresses，没有 points）留给迁移处理', () {
      final old = Device.fromJson({
        'id': 'dev_old',
        'name': '旧案例',
        'templateId': 'tpl_lift',
        'addresses': {'p1': 'I1.1', 'p5': 'Q1.0'},
      });
      expect(old.points, isEmpty);
      expect(old.legacyAddresses['p1'], 'I1.1');
      expect(old.legacyAddresses['p5'], 'Q1.0');
    });
  });
}
