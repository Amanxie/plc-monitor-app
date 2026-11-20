// 报警采集的真实协议验证：直连本机假 S7 PLC（127.0.0.1:11102）
//
// 这个测试验证「按字节块批量读 DB 区 → 解位 → 判定报警」整条链路：
//   1. S7Client.readBytes 读 DB91 连续字节
//   2. 用 UDP 控制口（11103）把 DB91.DBX3.0 置 1
//   3. 再读，位变 1 → 报警触发判定成立
//
// 假服务器没开时自动跳过，不影响常规 flutter test。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plc_app/comm_manager.dart';
import 'package:plc_app/models.dart';
import 'package:plc_app/s7_client.dart' as s7;

Future<void> poke(String area, int word, int bit, int val) async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.send('SET $area $word $bit $val'.codeUnits, InternetAddress.loopbackIPv4, 11103);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  s.close();
}

void main() {
  test('读字节块 + 解位：DB91.DBX3.0 置 1 后报警触发', () async {
    // 先探活
    try {
      final probe = await Socket.connect('127.0.0.1', 11102,
          timeout: const Duration(seconds: 2));
      probe.destroy();
    } catch (_) {
      // ignore: avoid_print
      print('假 PLC 未运行，跳过该测试');
      return;
    }

    final c = s7.S7Client('127.0.0.1', rack: 0, slot: 1, port: 11102);
    await c.connect();

    // 报警表 1 号：DB91Bit 地址 30 → DB91.DBX3.0，触发值 1
    final (alarms, errors) = parseAlarmTable(
        '1\t0\tDB91Bit\t30\t1\t地面PLC未收到机载PLC心跳\n'
        '2\t1\tDB90Bit\t3150\t1\t机载柜急停按钮触发\n'
        '3\t7\tMW\t1866\t0\t货叉编码器掉线');
    expect(errors, isEmpty);
    expect(alarms[0].address, 'DB91.DBX3.0');

    // 清零 → 读块 → 解位
    await poke('DB91', 3, 0, 0);
    var p0 = s7.parseS7Address(alarms[0].address)!;
    var bytes = await c.readBytes(s7.S7Point(p0.area, p0.db, p0.byteIndex, 0), 1);
    expect(decodeBit(bytes, p0.bitIndex), isFalse);

    // 置 1 → 再读
    await poke('DB91', 3, 0, 1);
    bytes = await c.readBytes(s7.S7Point(p0.area, p0.db, p0.byteIndex, 0), 1);
    expect(decodeBit(bytes, p0.bitIndex), isTrue);

    // 第二段：DB90 连续 111 字节块（模拟合并读取 315~425 字）
    final p1 = s7.parseS7Address(alarms[1].address)!;
    await poke('DB90', 315, 0, 1);
    final block = await c.readBytes(s7.S7Point(p1.area, p1.db, 315, 0), 111);
    expect(block.length, 111);
    expect(decodeBit([block[315 - 315]], 0), isTrue);

    // 第三段：M 区（MW → M186.6）
    final p2 = s7.parseS7Address(alarms[2].address)!;
    expect(p2.byteIndex, 186);
    expect(p2.bitIndex, 6);
    await poke('M', 186, 6, 0);
    var mBytes = await c.readBytes(s7.S7Point(p2.area, 0, 186, 0), 1);
    expect(decodeBit(mBytes, 6), isFalse); // 位=0，触发值 0 → 报警成立
    await poke('M', 186, 6, 1);
    mBytes = await c.readBytes(s7.S7Point(p2.area, 0, 186, 0), 1);
    expect(decodeBit(mBytes, 6), isTrue); // 位=1，触发值 0 → 不报警

    await c.disconnect();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('CommManager 整链路：合并字节块采集报警 + 报警灯', () async {
    try {
      final probe = await Socket.connect('127.0.0.1', 11102,
          timeout: const Duration(seconds: 2));
      probe.destroy();
    } catch (_) {
      // ignore: avoid_print
      print('假 PLC 未运行，跳过该测试');
      return;
    }

    // 报警地址故意分散在三段：DB91 的 3.0，DB90 的 315.0 与 420.0，M 区 186.6
    final d = Device(
      id: 'dev_live',
      name: 'live',
      templateId: 'x',
      ip: '127.0.0.1',
      port: 11102,
      points: [
        PointItem(id: 'p1', name: '一层到位', address: 'I0.0',
            type: PointType.input, writable: false),
      ],
      alarms: [
        AlarmItem(id: 1, priority: 0, address: 'DB91.DBX3.0',
            triggerHigh: true, text: '心跳超时'),
        AlarmItem(id: 2, priority: 1, address: 'DB90.DBX315.0',
            triggerHigh: true, text: '急停拍下'),
        AlarmItem(id: 3, priority: 2, address: 'DB90.DBX420.0',
            triggerHigh: true, text: '尾部报警'),
        AlarmItem(id: 4, priority: 3, address: 'M186.6',
            triggerHigh: false, text: '编码器掉线（低有效）'),
      ],
      alarmLamp: 'M10.0',
    );

    final cm = CommManager.instance;
    final ok = await cm.connect(d);
    expect(ok, isTrue);

    // 先全部清零
    await poke('DB91', 3, 0, 0);
    await poke('DB90', 315, 0, 0);
    await poke('DB90', 420, 0, 0);
    await poke('M', 186, 6, 1); // 触发值 0 → 位 1 不报警
    await poke('M', 10, 0, 0);
    await Future<void>.delayed(const Duration(seconds: 3));
    final s = cm.st(d.id);
    expect(s.alarmRaw[1], isFalse);
    expect(s.alarmRaw[2], isFalse);
    expect(s.alarmRaw[3], isFalse);
    expect(s.alarmRaw[4], isTrue); // 位=1，触发值 0 → 不报警
    expect(s.lampColor, isNot('red'));

    // 触发 1 号和 3 号（跨两个字节块），并点亮报警灯
    await poke('DB91', 3, 0, 1);
    await poke('DB90', 420, 0, 1);
    await poke('M', 10, 0, 1);
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(s.alarmRaw[1], isTrue);
    expect(s.alarmRaw[2], isFalse, reason: '同一 DB90 块里未点的位不应被带起来');
    expect(s.alarmRaw[3], isTrue);
    expect(s.lampColor, 'red');

    await cm.disconnect(d);

    // 收尾：把灯关掉，免得影响后续手工测试
    await poke('DB91', 3, 0, 0);
    await poke('DB90', 420, 0, 0);
    await poke('M', 10, 0, 0);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
