/// S7 协议自测：内置一个按规范实现的 S7 服务端（模拟 1200），
/// 让 S7Client 真实跑一遍「连接 → 协商 PDU → 读位 → 写位」，
/// 并校验报文长度/偏移等关键字段。
///
/// 用法：dart run tool/s7_selftest.dart
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lib/s7_client.dart';

/// 极简 S7 服务端：只实现本 App 用到的 COTP 连接 + Setup + Read/Write 位
class MockS7Server {
  final Map<int, Map<int, int>> bitArea = {
    0x81: {}, // I
    0x82: {}, // Q
    0x83: {}, // M
  };
  ServerSocket? _srv;
  final List<String> log = [];

  int get port => _srv!.port;

  Future<void> start() async {
    _srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _srv!.listen(_handle);
  }

  Future<void> stop() async => _srv?.close();

  void _handle(Socket s) {
    final buf = <int>[];
    s.listen((d) {
      buf.addAll(d);
      while (true) {
        if (buf.length < 4) return;
        final total = (buf[2] << 8) | buf[3];
        if (total < 7 || buf.length < total) return;
        final frame = Uint8List.fromList(buf.sublist(0, total));
        buf.removeRange(0, total);
        final resp = _onFrame(frame);
        if (resp != null) s.add(resp);
      }
    }, onError: (_) {}, onDone: () => s.destroy());
  }

  Uint8List _tpkt(List<int> body) {
    final total = body.length + 4;
    return Uint8List.fromList(
        [0x03, 0x00, (total >> 8) & 0xFF, total & 0xFF, ...body]);
  }

  Uint8List? _onFrame(Uint8List f) {
    final cotp = f[5];
    // 1) COTP 连接请求
    if ((cotp & 0xF0) == 0xE0) {
      log.add('COTP CR  总长=${f.length} LI=${f[4]}');
      // 校验: LI 必须等于 总长-5
      if (f[4] != f.length - 5) {
        log.add('  ✗ LI 与总长不符');
      }
      // 找到 C2 (dst TSAP)
      String? dstTsap;
      for (int i = 7; i < f.length - 2; i++) {
        if (f[i] == 0xC2 && f[i + 1] == 0x02) {
          dstTsap = '${f[i + 2].toRadixString(16)}${f[i + 3].toRadixString(16)}';
        }
      }
      log.add('  dstTSAP=$dstTsap');
      return _tpkt([
        0x11, 0xD0, // LI, CC
        0x00, 0x01, // dst-ref
        0x00, 0x01, // src-ref
        0x00,
        0xC0, 0x01, 0x0A,
        0xC1, 0x02, 0x01, 0x00,
        0xC2, 0x02, 0x01, 0x01,
      ]);
    }
    if (cotp != 0xF0) {
      log.add('未知 COTP 0x${cotp.toRadixString(16)}');
      return null;
    }

    // 2) S7 PDU
    final s7 = f.sublist(7);
    final rosctr = s7[1];
    final ref = [s7[4], s7[5]];
    final plen = (s7[6] << 8) | s7[7];
    final dlen = (s7[8] << 8) | s7[9];
    final param = s7.sublist(10, 10 + plen);
    final data = s7.sublist(10 + plen, 10 + plen + dlen);
    final func = param[0];
    log.add('S7  job rosctr=0x${rosctr.toRadixString(16)} func=0x${func.toRadixString(16)} '
        'plen=$plen dlen=$dlen');

    Uint8List header(int pLen, int dLen) => Uint8List.fromList([
          0x32, 0x03, 0x00, 0x00,
          ref[0], ref[1],
          (pLen >> 8) & 0xFF, pLen & 0xFF,
          (dLen >> 8) & 0xFF, dLen & 0xFF,
          0x00, 0x00, // error class / code
        ]);

    // Setup communication
    if (func == 0xF0) {
      // 校验 paramLen 应为 8
      if (plen != 8) log.add('  ✗ setup paramLen=$plen（应为 8）');
      final p = [0xF0, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 240];
      if (dlen != 0) log.add('  ✗ setup dataLen=$dlen（应为 0）');
      return _tpkt([0x02, 0xF0, 0x80, ...header(8, 0), ...p]);
    }

    // Read var
    if (func == 0x04) {
      final cnt = param[1];
      final dataOut = <int>[];
      for (int i = 0; i < cnt; i++) {
        final it = param.sublist(2 + i * 12, 2 + i * 12 + 12);
        if (it[0] != 0x12 || it[1] != 0x0A || it[2] != 0x10) {
          log.add('  ✗ 读项结构异常');
        }
        final ts = it[3];
        final len = (it[4] << 8) | it[5];
        final area = it[8];
        final bitAddr = (it[9] << 16) | (it[10] << 8) | it[11];
        if (ts != 0x01 || len != 1) log.add('  ✗ 读项应为 BIT/1，实际 ts=$ts len=$len');
        final v = bitArea[area]?[bitAddr] ?? 0;
        dataOut.addAll([0xFF, 0x03, 0x00, 0x01, v, 0x00]);
      }
      final p = [0x04, cnt];
      return _tpkt([0x02, 0xF0, 0x80, ...header(p.length, dataOut.length), ...p, ...dataOut]);
    }

    // Write var
    if (func == 0x05) {
      if (plen != 14) log.add('  ✗ 写 paramLen=$plen（应为 14）');
      if (dlen != 6) log.add('  ✗ 写 dataLen=$dlen（应为 6）');
      final it = param.sublist(2, 14);
      final area = it[8];
      final bitAddr = (it[9] << 16) | (it[10] << 8) | it[11];
      final value = data[4];
      bitArea.putIfAbsent(area, () => {})[bitAddr] = value & 0x01;
      log.add('  write area=0x${area.toRadixString(16)} bit=$bitAddr val=$value');
      final p = [0x05, 0x01];
      return _tpkt([0x02, 0xF0, 0x80, ...header(2, 1), ...p, 0xFF]);
    }

    log.add('未实现功能 0x${func.toRadixString(16)}');
    return null;
  }
}

Future<void> main() async {
  var failed = 0;
  void check(String name, bool ok, [String extra = '']) {
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name${extra.isEmpty ? '' : '  →  $extra'}');
    if (!ok) failed++;
  }

  final srv = MockS7Server();
  await srv.start();

  // 预置：I0.0=1, I0.2=1, Q0.1=0
  srv.bitArea[0x81]![0] = 1;
  srv.bitArea[0x81]![2] = 1;

  final c = S7Client('127.0.0.1', port: srv.port);
  await c.connect();
  check('COTP + Setup 握手', c.isConnected, 'PDU=${c.pduSize}');
  check('PDU 协商值合理', c.pduSize >= 240 && c.pduSize <= 960, '${c.pduSize}');

  final pts = [
    const S7Point(0x81, 0, 0, 0), // I0.0
    const S7Point(0x81, 0, 0, 1), // I0.1
    const S7Point(0x81, 0, 0, 2), // I0.2
    const S7Point(0x82, 0, 0, 1), // Q0.1
  ];
  final v = await c.readBits(pts);
  check('读 4 个位数值正确', v[0] && !v[1] && v[2] && !v[3], '$v');

  await c.writeBit(const S7Point(0x82, 0, 0, 1), true);
  final v2 = await c.readBits([const S7Point(0x82, 0, 0, 1)]);
  check('写 Q0.1=ON 后回读为 ON', v2[0], '$v2');

  await c.writeBit(const S7Point(0x82, 0, 0, 1), false);
  final v3 = await c.readBits([const S7Point(0x82, 0, 0, 1)]);
  check('写 Q0.1=OFF 后回读为 OFF', !v3[0], '$v3');

  // 连续 20 次读写，验证无串包/无缓冲错位
  var ok = true;
  for (int i = 0; i < 20; i++) {
    final a = await c.writeBit(const S7Point(0x82, 0, 0, 2), i.isEven);
    final b = await c.readBits([const S7Point(0x82, 0, 0, 2)]);
    if (!a || b[0] != i.isEven) ok = false;
  }
  check('连续 20 轮写读无错位', ok);

  await c.disconnect();
  await srv.stop();

  stdout.writeln('');
  stdout.writeln('服务端日志：');
  for (final l in srv.log) {
    stdout.writeln('  $l');
  }
  final badLog = srv.log.where((l) => l.contains('✗')).toList();
  check('报文结构无异常标记', badLog.isEmpty, badLog.join('; '));

  stdout.writeln('');
  stdout.writeln(failed == 0 ? '=== 全部通过 ===' : '=== 失败 $failed 项 ===');
  exit(failed == 0 ? 0 : 1);
}
