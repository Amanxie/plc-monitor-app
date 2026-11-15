/// 命令行连通性探针：绕开手机/模拟器，直接从电脑测 PLC 是否可通讯
///
/// 用法（在工程根目录执行）：
///   dart run tool/s7_probe.dart 192.168.0.1
///   dart run tool/s7_probe.dart 192.168.0.1 0 1
///   dart run tool/s7_probe.dart 192.168.0.1 0 1 --write Q0.0
library;

import 'dart:io';
import '../lib/s7_client.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stdout.writeln('用法: dart run tool/s7_probe.dart <PLC_IP> [rack] [slot] [--write Q0.0]');
    exit(2);
  }
  final ip = args[0];
  final rack = args.length > 1 ? int.tryParse(args[1]) ?? 0 : 0;
  final slot = args.length > 2 && !args[2].startsWith('--')
      ? int.tryParse(args[2]) ?? 1
      : 1;
  String? writeAddr;
  final wi = args.indexOf('--write');
  if (wi >= 0 && wi + 1 < args.length) writeAddr = args[wi + 1];

  stdout.writeln('目标: $ip:102  机架=$rack 槽位=$slot');
  stdout.writeln('--- 1. TCP 连接 ---');
  final sw = Stopwatch()..start();
  try {
    final s = await Socket.connect(ip, 102, timeout: const Duration(seconds: 3));
    sw.stop();
    stdout.writeln('OK  TCP 已连接（${sw.elapsedMilliseconds} ms）');
    s.destroy();
  } on SocketException catch (e) {
    sw.stop();
    stdout.writeln('FAIL TCP 连接失败：${e.message} ${e.osError?.message ?? ''}');
    stdout.writeln('     → 端口 102 没人监听，或 IP 不对，或防火墙拦截');
    exit(1);
  }

  stdout.writeln('--- 2. S7 握手（COTP + 建立通讯）---');
  final c = S7Client(ip, rack: rack, slot: slot);
  try {
    await c.connect();
    stdout.writeln('OK  握手成功，PDU 协商 = ${c.pduSize} 字节，实际使用槽位 = ${c.usedSlot}');
  } catch (e) {
    stdout.writeln('FAIL 握手失败：$e');
    exit(1);
  }

  stdout.writeln('--- 3. 读 I/Q/M 前 8 位 ---');
  Future<void> dump(String name, int area) async {
    final pts = List.generate(8, (i) => S7Point(area, 0, 0, i));
    try {
      final v = await c.readBits(pts);
      final s = <String>[];
      for (int i = 0; i < v.length; i++) {
        s.add('${name}0.$i=${v[i] ? 1 : 0}');
      }
      stdout.writeln('OK  ${s.join('  ')}');
    } catch (e) {
      stdout.writeln('FAIL 读 $name 区失败：$e');
    }
  }

  await dump('I', 0x81);
  await dump('Q', 0x82);
  await dump('M', 0x83);

  if (writeAddr != null) {
    stdout.writeln('--- 4. 写测试 $writeAddr ---');
    final p = parseS7Address(writeAddr);
    if (p == null) {
      stdout.writeln('FAIL 地址无法解析');
    } else {
      try {
        await c.writeBit(p, true);
        stdout.writeln('OK  写 ON 成功');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await c.writeBit(p, false);
        stdout.writeln('OK  写 OFF 成功');
      } catch (e) {
        stdout.writeln('FAIL 写失败：$e');
      }
    }
  }

  await c.disconnect();
  stdout.writeln('--- 完成 ---');
}
