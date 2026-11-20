// 报警表解析与触发判定测试（需求 19）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plc_app/models.dart';

void main() {
  group('parseAlarmTable', () {
    test('标准 Excel 粘贴格式（制表符分隔 + 表头）', () {
      final raw = 'ID\t类别\t设备类型\t地址\t触发数值\t内容\n'
          '1\t0\tDB91Bit\t30\t1\t地面PLC未收到机载PLC心跳\n'
          '2\t1\tDB90Bit\t3150\t1\t机载柜急停按钮触发\n'
          '3\t7\tMW\t1866\t0\t货叉编码器掉线';
      final (alarms, errors) = parseAlarmTable(raw);
      expect(errors, isEmpty);
      expect(alarms.length, 3);
      // D 列绝对地址：末位是位、前面是字 —— 30 → 3.0，3150 → 315.0
      expect(alarms[0].address, 'DB91.DBX3.0');
      expect(alarms[1].address, 'DB90.DBX315.0');
      // MW → M 区
      expect(alarms[2].address, 'M186.6');
      expect(alarms[2].priority, 7);
      // E 列：1 → 值为 1 报警；0 → 值为 0 报警
      expect(alarms[0].triggerHigh, isTrue);
      expect(alarms[2].triggerHigh, isFalse);
    });

    test('内容超过 50 字截断', () {
      final long = '很长的报警' * 20;
      final (alarms, errors) = parseAlarmTable('1\t0\tMW\t100\t1\t$long');
      expect(errors, isEmpty);
      expect(alarms.first.text.length, 50);
    });

    test('Excel 另存的逗号 CSV 也能导入，内容里的逗号不丢', () {
      final raw = 'ID,优先级,区域,地址,触发值,内容\n'
          '1,0,DB91Bit,30,1,通信超时,请检查网线\n'
          '2,2,MW,1866,0,安全门打开';
      final (alarms, errors) = parseAlarmTable(raw);
      expect(errors, isEmpty);
      expect(alarms.length, 2);
      expect(alarms[0].address, 'DB91.DBX3.0');
      // 第 6 段之后整段并入内容，逗号保留
      expect(alarms[0].text, '通信超时,请检查网线');
      expect(alarms[1].address, 'M186.6');
    });

    test('位号超 7 / 触发值非 01 / 区域不认识 / 内容为空 → 报错跳过', () {
      final (alarms, errors) = parseAlarmTable(
          '1\t0\tDB90Bit\t3159\t1\t位号超界\n'
          '2\t0\tDB90Bit\t3150\t2\t触发值非法\n'
          '3\t0\tXXBit\t3150\t1\t区域不认识\n'
          '4\t0\tDB90Bit\t3151\t1\t');
      expect(alarms, isEmpty);
      expect(errors.length, 4);
    });

    test('空行与表头行被跳过', () {
      final raw = '\nID\t类别\t设备\t地址\t触发\t内容\n1\t0\tMW\t100\t1\t测试\n\n';
      final (alarms, errors) = parseAlarmTable(raw);
      expect(errors, isEmpty);
      expect(alarms.length, 1);
      expect(alarms.first.address, 'M10.0');
    });
  });

  group('AlarmItem 序列化', () {
    test('toJson / fromJson 往返', () {
      final a = AlarmItem(
          id: 42, priority: 3, address: 'DB90.DBX315.0',
          triggerHigh: false, text: '行走测距仪掉线');
      final b = AlarmItem.fromJson(a.toJson());
      expect(b.id, 42);
      expect(b.priority, 3);
      expect(b.address, 'DB90.DBX315.0');
      expect(b.triggerHigh, isFalse);
      expect(b.text, '行走测距仪掉线');
    });
  });

  group('Device 报警字段序列化', () {
    test('toJson / fromJson 往返保留状态灯与报警表', () {
      final d = Device(id: 'dev1', name: '堆垛机', templateId: 'tpl_x')
        ..lampRed = 'M10.0'
        ..lampYellow = 'M10.1'
        ..lampGreen = 'M10.2'
        ..alarms = [
          AlarmItem(id: 1, priority: 0, address: 'DB91.DBX3.0',
              triggerHigh: true, text: '通信超时'),
        ];
      final b = Device.fromJson(d.toJson());
      expect(b.lampRed, 'M10.0');
      expect(b.lampYellow, 'M10.1');
      expect(b.lampGreen, 'M10.2');
      expect(b.alarms.length, 1);
      expect(b.alarms.first.text, '通信超时');
    });

    test('旧存档的 alarmLamp 迁移为状态灯红灯地址', () {
      final b = Device.fromJson({
        'id': 'x', 'name': 'n', 'protocol': 's7', 'alarmLamp': 'M20.0',
      });
      expect(b.lampRed, 'M20.0');
      expect(b.alarms, isEmpty);
    });

    test('旧存档没有报警字段也能读', () {
      final d = Device.fromJson({'id': 'x', 'name': 'n', 'protocol': 's7'});
      expect(d.alarms, isEmpty);
      expect(d.lampRed, '');
    });
  });

  group('报警触发判定', () {
    test('triggerHigh / triggerLow 的组合', () {
      bool active(AlarmItem a, bool raw) => raw == a.triggerHigh;
      final high = AlarmItem(id: 1, priority: 0, address: 'M0.0',
          triggerHigh: true, text: 'a');
      final low = AlarmItem(id: 2, priority: 0, address: 'M0.1',
          triggerHigh: false, text: 'b');
      expect(active(high, true), isTrue);   // 位=1，触发值 1 → 报警
      expect(active(high, false), isFalse); // 位=0，触发值 1 → 不报
      expect(active(low, false), isTrue);   // 位=0，触发值 0 → 报警
      expect(active(low, true), isFalse);
    });
  });
  realDataTests();
}

// ---------------------------------------------------------------- 真实数据
// 用谢工现场的「报警记录」表（267 条）验一遍解析：这条用例保证格式兼容不回退

void realDataTests() {
  test('真实报警记录 267 条全部解析成功', () {
    final f = File('test/fixtures/alarm_sample.txt');
    if (!f.existsSync()) return; // 夹具缺失时不阻塞
    final raw = f.readAsStringSync();
    final (alarms, errors) = parseAlarmTable(raw);
    expect(errors, isEmpty, reason: errors.join('\n'));
    expect(alarms.length, 267);
    // 抽查：1 号在 DB91 字 3 位 0；30 号在 DB90 字 315 位 0
    final a1 = alarms.firstWhere((a) => a.id == 1);
    expect(a1.address, 'DB91.DBX3.0');
    expect(a1.priority, 0);
    expect(a1.text, '地面PLC未收到机载PLC心跳，通信超时');
    final a30 = alarms.firstWhere((a) => a.id == 30);
    expect(a30.address, 'DB90.DBX315.0');
    // 末条是 MW 1866 触发值 0
    final last = alarms.last;
    expect(last.address, 'M186.6');
    expect(last.triggerHigh, isFalse);
    // 报警内容都不超过 50 字
    expect(alarms.every((a) => a.text.length <= 50), isTrue);
  });
}
