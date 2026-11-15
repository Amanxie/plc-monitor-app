// 抓真实 PLC 的读应答原始帧（dart run tool/live_frame_dump.dart <ip>）
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

String hexs(List<int> b) {
  final s = <String>[];
  for (final x in b) {
    s.add(x.toRadixString(16).padLeft(2, '0').toUpperCase());
  }
  return s.join(' ');
}

/// 持久订阅 socket，按帧读取（socket 流只能 listen 一次）
class FrameReader {
  final Socket s;
  final buf = <int>[];
  Completer<void>? waiting;

  FrameReader(this.s) {
    s.listen((d) {
      buf.addAll(d);
      final w = waiting;
      if (w != null && !w.isCompleted) {
        waiting = null;
        w.complete();
      }
    }, onDone: () {
      final w = waiting;
      if (w != null && !w.isCompleted) {
        waiting = null;
        w.complete();
      }
    }, onError: (_) {});
  }

  Future<Uint8List> read({int timeoutMs = 3000}) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (buf.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('recv');
      }
      waiting = Completer<void>();
      try {
        await waiting!.future.timeout(Duration(milliseconds: timeoutMs));
      } catch (_) {}
      waiting = null;
    }
    final out = Uint8List.fromList(buf);
    buf.clear();
    return out;
  }
}

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '192.168.0.1';
  final s = await Socket.connect(host, 102, timeout: const Duration(seconds: 3));
  final fr = FrameReader(s);
  print('TCP OK');

  s.add([0x03, 0x00, 0x00, 0x16, 0x11, 0xE0, 0x00, 0x00, 0x00, 0x01, 0x00,
         0xC1, 0x02, 0x01, 0x00, 0xC2, 0x02, 0x03, 0x01, 0xC0, 0x01, 0x0A]);
  var r = await fr.read();
  print('COTP CC [' + r.length.toString() + 'B]: ' + hexs(r));

  s.add([0x03, 0x00, 0x00, 0x19, 0x02, 0xF0, 0x80,
         0x32, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00,
         0xF0, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0xF0]);
  r = await fr.read();
  print('SETUP [' + r.length.toString() + 'B]: ' + hexs(r));

  final items = <List<int>>[
    [0x81, 0], [0x81, 1], [0x81, 2], [0x81, 3], [0x82, 0], [0x82, 1],
  ];
  final cnt = items.length;
  final paramLen = 2 + cnt * 12;
  final b = BytesBuilder();
  b.add([0x03, 0x00, 0x00, 0x00]);
  b.add([0x02, 0xF0, 0x80]);
  b.add([0x32, 0x01, 0x00, 0x00, 0x00, 0x02]);
  b.add([(paramLen >> 8) & 0xFF, paramLen & 0xFF]);
  b.add([0x00, 0x00]);
  b.add([0x04, cnt]);
  for (final it in items) {
    final addr = it[1];
    // readValues 的请求样式：transport 0x02（BYTE/WORD 系），长度按字节
    b.add([0x12, 0x0A, 0x10, 0x02, 0x00, 0x01, 0x00, 0x00, it[0],
           (addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF]);
  }
  final req = b.toBytes();
  req[2] = (req.length >> 8) & 0xFF;
  req[3] = req.length & 0xFF;
  print('REQ [' + req.length.toString() + 'B]: ' + hexs(req));
  s.add(req);
  r = await fr.read();
  print('RESP [' + r.length.toString() + 'B]: ' + hexs(r));

  if (r.length > 19) {
    final plen = (r[13] << 8) | r[14];
    final dlen = (r[15] << 8) | r[16];
    print('paramLen=' + plen.toString() + ' dataLen=' + dlen.toString() +
        ' dataStart=' + (19 + plen).toString());
    var pos = 19 + plen;
    var i = 0;
    while (pos + 4 <= r.length) {
      final rc = r[pos];
      final ts = r[pos + 1];
      final lf = (r[pos + 2] << 8) | r[pos + 3];
      final dl = (lf + 7) >> 3;
      final end2 = (pos + 4 + dl) <= r.length ? pos + 4 + dl : r.length;
      print('item#' + i.toString() +
          ' rc=0x' + rc.toRadixString(16) +
          ' ts=0x' + ts.toRadixString(16) +
          ' len=' + lf.toString() +
          ' data=' + hexs(r.sublist(pos + 4, end2)));
      pos += 4 + dl + (dl & 1);
      i++;
    }
  }
  s.destroy();
}
