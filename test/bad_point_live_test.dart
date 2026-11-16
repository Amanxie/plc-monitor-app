// 坏点容错的真实协议验证：直连本机假 S7 PLC（127.0.0.1:11102）
//
// 场景：设备点位里混着「PLC 上不存在的地址」（假服务器对 BAD DB 一律应答 rc=0x05）。
// 验证：
//   1. readValues：坏点位返回 null、好点位正常值，badAddresses 记录坏地址
//   2. CommManager：连接保持正常、message 提示「N 个点位读不到」、坏点位显示 --
//   3. 坏点位拉黑：下一轮起不再对它发通讯请求（假服务器日志不再出现 DB777 读）
//   4. 报警字节段：连续 3 次失败后拉黑，M 区段照常采集（报警灯有值）
//
// 假服务器没开时自动跳过，不影响常规 flutter test。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plc_app/comm_manager.dart';
import 'package:plc_app/models.dart';
import 'package:plc_app/s7_client.dart' as s7;

Future<void> poke(String cmd) async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.send(cmd.codeUnits, InternetAddress.loopbackIPv4, 11103);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  s.close();
}

Future<bool> serverUp() async {
  try {
    final probe = await Socket.connect('127.0.0.1', 11102,
        timeout: const Duration(seconds: 2));
    probe.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Device makeDevice() => Device(
      id: 'dev_bad',
      name: 'badpoint',
      templateId: 'x',
      ip: '127.0.0.1',
      port: 11102,
      points: [
        PointItem(id: 'p_ok1', name: '好点位1', address: 'M0.0',
            type: PointType.input, writable: false),
        PointItem(id: 'p_bad', name: '坏点位', address: 'DB777.DBX0.0',
            type: PointType.input, writable: false),
        PointItem(id: 'p_ok2', name: '好点位2', address: 'M0.1',
            type: PointType.input, writable: false),
      ],
      alarms: [
        AlarmItem(id: 1, priority: 0, address: 'DB777.DBX5.0',
            triggerHigh: true, text: '坏报警段'),
        // 注意：M 地址与 alarm_s7_live_test 的 M10.0 / M186.6 错开，
        // 两个文件并发跑时共享同一台假 PLC，不能互相打架
        AlarmItem(id: 2, priority: 1, address: 'M190.6',
            triggerHigh: true, text: '好报警位'),
      ],
      alarmLamp: 'M20.0',
    );

void main() {
  setUpAll(() async {
    if (await serverUp()) {
      await poke('BAD DB777'); // DB777 整个块「不存在」
      await poke('SET M 0 0 0');
      await poke('SET M 0 1 1');
    }
  });

  tearDownAll(() async {
    if (await serverUp()) await poke('GOOD DB777');
  });

  test('S7Client：readValues 坏点位回 null，好点位正常，地址被记录', () async {
    if (!await serverUp()) {
      // ignore: avoid_print
      print('假 PLC 未运行，跳过该测试');
      return;
    }
    final c = s7.S7Client('127.0.0.1', rack: 0, slot: 1, port: 11102);
    await c.connect();

    final ok = s7.parseS7Address('M0.0')!;
    final bad = s7.parseS7Address('DB777.DBX0.0')!;
    final r = await c.readValues([
      s7.S7ReadItem(ok, VarType.boolean),
      s7.S7ReadItem(bad, VarType.boolean),
    ]);
    expect(r[0], isFalse); // M0.0 正常读到
    expect(r[1], isNull); // DB777 地址不存在 → null
    expect(c.badAddresses, contains('DB777.DBX0.0'));

    // 字/双字混读也容错
    final w = s7.parseS7Address('MW2')!;
    final r2 = await c.readValues([
      s7.S7ReadItem(bad, VarType.boolean),
      s7.S7ReadItem(w, VarType.int16),
    ]);
    expect(r2[0], isNull);
    expect(r2[1], isNotNull);

    await c.disconnect();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('CommManager：连接不挂、提示坏点、好点位照常刷新', () async {
    if (!await serverUp()) {
      // ignore: avoid_print
      print('假 PLC 未运行，跳过该测试');
      return;
    }
    final d = makeDevice();
    final cm = CommManager.instance;
    final ok = await cm.connect(d);
    expect(ok, isTrue);

    await Future<void>.delayed(const Duration(seconds: 3));
    final s = cm.st(d.id);
    expect(s.state, ConnState.connected, reason: '坏点位不能把连接打成异常');
    expect(s.values['p_ok1'], isFalse); // M0.0 清零过
    expect(s.values['p_ok2'], isTrue); // M0.1 置 1
    expect(s.values['p_bad'], isNull); // 坏点位显示 --
    expect(s.message, contains('读不到'));
    expect(s.message, contains('DB777.DBX0.0'));

    await cm.disconnect(d);
    cm.forget(d.id);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('报警段：坏 DB 段连续失败拉黑，M 区段照常采集', () async {
    if (!await serverUp()) {
      // ignore: avoid_print
      print('假 PLC 未运行，跳过该测试');
      return;
    }
    final d = makeDevice();
    final cm = CommManager.instance;
    expect(await cm.connect(d), isTrue);

    await poke('SET M 20 0 1'); // 报警灯亮
    await poke('SET M 190 6 1'); // 好报警位触发
    // 报警每 4 轮采一次、每轮约 0.5s、段拉黑需 3 次失败 → 等 20 秒足够
    await Future<void>.delayed(const Duration(seconds: 20));
    final s = cm.st(d.id);
    expect(s.state, ConnState.connected);
    expect(s.lampOn, isTrue, reason: 'M 区报警灯段照常采集');
    expect(s.alarmRaw[2], isTrue, reason: 'M190.6 好报警位照常采集');
    expect(s.alarmRaw.containsKey(1), isFalse,
        reason: 'DB777 段拉黑后 1 号报警不再有读数');

    await cm.disconnect(d);
    cm.forget(d.id);
    await poke('SET M 20 0 0');
    await poke('SET M 190 6 0');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('报警诊断：全部段读不到时给出明确原因，不再停留在「读取报警中…」', () async {
    if (!await serverUp()) {
      // ignore: avoid_print
      print('假 PLC 未运行，跳过该测试');
      return;
    }
    final d = Device(
      id: 'dev_allbad',
      name: 'allbad',
      templateId: 'x',
      ip: '127.0.0.1',
      port: 11102,
      points: [
        PointItem(id: 'p1', name: '点位', address: 'M0.0',
            type: PointType.input, writable: false),
      ],
      alarms: [
        AlarmItem(id: 1, priority: 0, address: 'DB777.DBX5.0',
            triggerHigh: true, text: '坏报警'),
      ],
      alarmLamp: 'DB777.DBX6.0',
    );
    final cm = CommManager.instance;
    expect(await cm.connect(d), isTrue);

    // 等拉黑生效（3 次失败，每 4 轮采一次、每轮约 0.5s）
    await Future<void>.delayed(const Duration(seconds: 12));
    final s = cm.st(d.id);
    expect(s.state, ConnState.connected);
    expect(s.alarmSegTotal, greaterThan(0));
    expect(s.alarmSegFailed, greaterThanOrEqualTo(s.alarmSegTotal),
        reason: '所有报警段都读不到 → 界面应显示诊断而不是「读取报警中…」');
    expect(s.alarmFailDesc, contains('DB777'));

    await cm.disconnect(d);
    cm.forget(d.id);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
