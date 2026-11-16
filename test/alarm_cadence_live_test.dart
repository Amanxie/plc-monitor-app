// 需求11 验证：报警位翻转后 App 在 ~1 秒内检测到（采集周期 1 秒）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plc_app/comm_manager.dart';
import 'package:plc_app/models.dart';
import 'package:plc_app/store.dart';

void main() {
  test('需求11：报警位翻转 1 秒内被检测到', () async {
    final d = Device(
      id: 'dev_cadence', name: '节拍测试', templateId: 'x',
      ip: '127.0.0.1', port: 11102, rack: 0, slot: 1,
      points: [PointItem(id: 'p1', name: 'x', address: 'I0.0',
          type: PointType.input, writable: false)],
      alarms: [
        AlarmItem(id: 1, priority: 0, address: 'M196.3',
            triggerHigh: true, text: '节拍测试报警'),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'devices': jsonEncode([d.toJson()])
    });
    AppStore.instance.loaded = false;
    AppStore.instance.devices.clear();

    Future<void> poke(String cmd) async {
      final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      s.send(utf8.encode(cmd), InternetAddress.loopbackIPv4, 11103);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      s.close();
    }

    final cm = CommManager.instance;
    final ok = await cm.connect(d);
    expect(ok, isTrue, reason: '连接假 PLC');
    final s = cm.st(d.id);

    // 等报警采集跑起来（读到 M190.6=false）
    for (int i = 0; i < 30 && !s.alarmRaw.containsKey(1); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(s.alarmRaw[1], isFalse, reason: '初始未触发');

    // ON：翻转后测「检测到触发」耗时
    final t0 = DateTime.now();
    await poke('SET M 196 3 1');
    for (int i = 0; i < 40 && s.alarmRaw[1] != true; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final onMs = DateTime.now().difference(t0).inMilliseconds;
    expect(s.alarmRaw[1], isTrue, reason: '翻转后检测到触发');
    // ignore: avoid_print
    print('ON 检测耗时 ${onMs}ms（采集周期 1 秒）');
    expect(onMs, lessThan(2000), reason: '1 秒周期内应检测到');

    // OFF
    final t1 = DateTime.now();
    await poke('SET M 196 3 0');
    for (int i = 0; i < 40 && s.alarmRaw[1] != false; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final offMs = DateTime.now().difference(t1).inMilliseconds;
    expect(s.alarmRaw[1], isFalse, reason: '翻转后检测到恢复');
    // ignore: avoid_print
    print('OFF 检测耗时 ${offMs}ms');
    expect(offMs, lessThan(2000));

    await cm.disconnect(d);
    cm.forget(d.id);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
