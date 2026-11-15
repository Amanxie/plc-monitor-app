/// 局域网 S7 设备扫描（纯 Dart，不依赖 Flutter）
///
/// 解决「填了 IP 连不上，不知道 PLC 到底在哪」的问题：
///   1. 对网段内每个地址做 TCP:102 连接探测；
///   2. 连上的再做一次 COTP 握手，只有回 CC（连接确认）的才算真 PLC；
///   3. 顺手记下它能接受的 TSAP，省得后面再猜机架槽位。
library;

import 'dart:async';
import 'dart:io';

/// 扫描命中的一个 S7 端点
class ScanHit {
  final String ip;
  final int tsap; // 0x0301 / 0x0101 / 0x0100
  final int rttMs;

  const ScanHit({required this.ip, required this.tsap, required this.rttMs});

  /// 由 TSAP 反推机架/槽位（TSAP 高字节 = rack*0x20 + slot）
  String get rackSlot {
    final rack = (tsap >> 8) & 0xFF;
    final slot = tsap & 0xFF;
    return '$rack / $slot';
  }

  @override
  String toString() => '$ip  TSAP=0x${tsap.toRadixString(16).padLeft(4, '0')}';
}

/// 从完整 IP 取出网段前缀，如 192.168.0.241 → 192.168.0
String subnetPrefix(String ip) {
  final parts = ip.trim().split('.');
  if (parts.length != 4) return '';
  return parts.take(3).join('.');
}

/// 扫描 [prefix].1 ~ [prefix].254 的 102 端口，返回真正能握手的 S7 设备。
///
/// [onProgress] 回调 (已完成, 总数)，用来驱动进度条。
Future<List<ScanHit>> scanS7Subnet(
  String prefix, {
  int port = 102,
  int timeoutMs = 420,
  int concurrency = 48,
  void Function(int done, int total)? onProgress,
}) async {
  final hosts = <String>[];
  for (int i = 1; i <= 254; i++) {
    hosts.add('$prefix.$i');
  }

  final hits = <ScanHit>[];
  int done = 0;

  int next = 0;
  Future<void> worker() async {
    while (true) {
      final idx = next;
      if (idx >= hosts.length) return;
      next = idx + 1;
      final hit = await probeS7(hosts[idx], port: port, timeoutMs: timeoutMs);
      if (hit != null && !hits.any((h) => h.ip == hit.ip)) hits.add(hit);
      done++;
      onProgress?.call(done, hosts.length);
    }
  }

  final n = concurrency.clamp(1, hosts.length);
  await Future.wait(List.generate(n, (_) => worker()));
  hits.sort((a, b) => a.ip.compareTo(b.ip));
  return hits;
}

/// 探测单个地址：TCP 通 + COTP 回 CC 才算命中。
Future<ScanHit?> probeS7(String ip,
    {int port = 102, int timeoutMs = 420}) async {
  for (final tsap in const [0x0301, 0x0101, 0x0100]) {
    final sw = Stopwatch()..start();
    Socket? s;
    try {
      s = await Socket.connect(ip, port, timeout: Duration(milliseconds: timeoutMs));
      final cr = _cotpCr(tsap);
      s.add(cr);
      await s.flush();

      final buf = <int>[];
      final done = Completer<bool>();
      late StreamSubscription sub;
      Timer? timer;

      sub = s.listen((d) {
        buf.addAll(d);
        if (buf.length >= 6) {
          if (!done.isCompleted) done.complete(buf[5] == 0xD0);
        }
      }, onDone: () {
        if (!done.isCompleted) done.complete(false);
      }, onError: (_) {
        if (!done.isCompleted) done.complete(false);
      });

      timer = Timer(Duration(milliseconds: timeoutMs + 300), () {
        if (!done.isCompleted) done.complete(false);
      });

      final ok = await done.future;
      timer.cancel();
      await sub.cancel();
      if (ok) {
        return ScanHit(ip: ip, tsap: tsap, rttMs: sw.elapsedMilliseconds);
      }
    } catch (_) {
      // 该 TSAP 不通，继续试下一个
    } finally {
      try {
        await s?.close();
      } catch (_) {}
    }
  }
  return null;
}

/// 构造 COTP 连接请求（22 字节，带 TPDU size 参数）
List<int> _cotpCr(int tsap) => <int>[
      0x03, 0x00, 0x00, 0x16, // TPKT：长度 22
      0x11, 0xE0, 0x00, 0x00, 0x00, 0x01, 0x00, // COTP CR
      0xC1, 0x02, 0x01, 0x00, // 源 TSAP
      0xC2, 0x02, (tsap >> 8) & 0xFF, tsap & 0xFF, // 目的 TSAP
      0xC0, 0x01, 0x0A, // TPDU size = 1024
    ];
