/// S7 通讯客户端（纯 Dart 实现 ISO-on-TCP / S7 0x32 协议）
///
/// 支持：连接、批量读位（I/Q/M/DB）、写单个位。
/// 适用：S7-1200 / S7-1500 / S7-300 / S7-400 真实 PLC 与 PLCSIM（102 端口）。
///
/// 报文格式严格按 ISO 8073 (COTP) + S7comm 规范实现：
///   TPKT(4) + COTP(3) + S7 Header(10 请求 / 12 应答) + Param + Data
library s7_client;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'models.dart';

class S7Point {
  final int area; // 0x81=I, 0x82=Q, 0x83=M, 0x84=DB
  final int db;
  final int byteIndex;
  final int bitIndex;
  const S7Point(this.area, this.db, this.byteIndex, this.bitIndex);
}

/// 一次读取的变量：地址 + 数据类型
class S7ReadItem {
  final S7Point point;
  final VarType type;
  const S7ReadItem(this.point, this.type);
}

/// 把解析后的地址还原成人类可读文本（报错提示用）；[isBit] 为真按位格式输出
String formatS7Point(S7Point p, {bool isBit = false}) {
  if (p.area == 0x84) {
    if (isBit) return 'DB${p.db}.DBX${p.byteIndex}.${p.bitIndex}';
    return 'DB${p.db}.DBB${p.byteIndex}';
  }
  const names = {0x81: 'I', 0x82: 'Q', 0x83: 'M'};
  final n = names[p.area] ?? 'A${p.area}';
  return isBit ? '$n${p.byteIndex}.${p.bitIndex}' : '$n${p.byteIndex}';
}

/// 带中文说明的 S7 异常
class S7Exception implements Exception {
  final String message;
  S7Exception(this.message);
  @override
  String toString() => message;
}

/// 解析 S7 数据项的「长度字段」，换算成字节数。
///
/// 规范里数据项的 transport size 决定长度字段的单位：
///   0x03 BIT / 0x04 BYTE_WORD_DWORD / 0x05 INTEGER / 0x06 DINTEGER
///   / 0x07 REAL → 单位都是「位」
///   0x09 OCTET STRING → 单位是「字节」
/// 个别固件/网关会按字节回（REAL 回 4、WORD 回 2），所以再跟 [needBytes]
/// （该点位的类型字节数）比对，哪个解释能对上就用哪个。
int dataLenBytes(int transportSize, int lenField, int needBytes) {
  switch (transportSize) {
    case 0x00: // NULL
      return 0;
    case 0x09: // OCTET STRING：字节
      return lenField;
    case 0x07: // REAL：规范按位（32 位=4 字节），部分网关按字节回 4/8
      final bits = (lenField + 7) >> 3;
      if ((lenField == 4 || lenField == 8) &&
          bits != needBytes && lenField == needBytes) {
        return lenField;
      }
      return bits;
    default: // 0x03 / 0x04 / 0x05 / 0x06 …单位都是「位」
      final bits = (lenField + 7) >> 3;
      if (bits == needBytes) return bits;
      if (lenField == needBytes) return lenField; // 个别固件按字节回
      return bits;
  }
}

/// 解析 S7 地址，支持位/字节/字/双字多种写法：
///   位：  I0.0  Q0.1  M10.2  DB1.DBX0.3
///   字节：MB10  IB0  QB0  DB1.DBB0  （或直接 I0 / M10，按起始字节处理）
///   字：  MW10 IW0  QW0  DB1.DBW0
///   双字：MD10 ID0  QD0  DB1.DBD0
/// 尺寸字母只影响语义，实际读取长度由数据类型决定，起始字节一致。
S7Point? parseS7Address(String addr) {
  final a = addr.trim().toUpperCase().replaceAll(' ', '');
  if (a.isEmpty) return null;

  // DB 区：DB1.DBX0.3 / DB1.DBB0 / DB1.DBW0 / DB1.DBD0
  if (a.startsWith('DB')) {
    final m = RegExp(r'^DB(\d+)\.(DBX|DBB|DBW|DBD)(\d+)(?:\.(\d+))?$').firstMatch(a);
    if (m == null) return null;
    final db = int.tryParse(m.group(1)!);
    if (db == null) return null;
    final kind = m.group(2)!;
    final base = int.tryParse(m.group(3)!);
    if (base == null) return null;
    final bit = m.group(4) != null ? int.tryParse(m.group(4)!) ?? 0 : 0;
    return S7Point(0x84, db, base, kind == 'DBX' ? bit : 0);
  }

  // I/Q/M/V 区：可带尺寸字母 B/W/D，可带 .位
  final m2 = RegExp(r'^([IQMV])([BWD])?(\d+)(?:\.(\d+))?$').firstMatch(a);
  if (m2 == null) return null;
  const areaMap = {'I': 0x81, 'Q': 0x82, 'M': 0x83, 'V': 0x84};
  final base = int.tryParse(m2.group(3)!);
  if (base == null) return null;
  final bit = m2.group(4) != null ? int.tryParse(m2.group(4)!) ?? 0 : 0;
  return S7Point(areaMap[m2.group(1)!]!, 0, base, bit);
}

/// 持续缓冲的定长读取器（同一 socket 不能混用 first / await for）
class _ByteReader {
  final Socket socket;
  final List<int> _buf = <int>[];
  Completer<void>? _waiting;
  bool _woken = false;
  bool _closed = false;

  _ByteReader(this.socket) {
    socket.listen((data) {
      _buf.addAll(data);
      _wake();
    }, onDone: () {
      _closed = true;
      _wake();
    }, onError: (_) {
      _closed = true;
      _wake();
    });
  }

  void _wake() {
    final w = _waiting;
    if (w != null && !_woken) {
      _woken = true;
      w.complete();
    }
  }

  Future<Uint8List> read(int n, {required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (_buf.length >= n) {
        final out = Uint8List.fromList(_buf.sublist(0, n));
        _buf.removeRange(0, n);
        return out;
      }
      if (_closed) throw S7Exception('连接已被 PLC 或网络中断');
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) throw TimeoutException('PLC 响应超时（${timeout.inSeconds}s）');
      _woken = false;
      final c = Completer<void>();
      _waiting = c;
      if (_buf.length >= n || _closed) continue;
      try {
        await c.future.timeout(left);
      } on TimeoutException {
        throw TimeoutException('PLC 响应超时（${timeout.inSeconds}s）');
      }
    }
  }
}

class S7Client {
  Socket? _socket;
  _ByteReader? _reader;
  bool _connected = false;
  int _pduRef = 0;
  int _pduSize = 240;
  final String ip;
  final int rack;
  final int slot;
  final int port;

  /// 实际握手成功的 TSAP 槽位（失败重试时可能与配置不同）
  int usedSlot = 0;

  /// 串行化请求，避免轮询与点动写入的响应互相串包
  Future<void> _chain = Future<void>.value();

  S7Client(this.ip, {this.rack = 0, this.slot = 1, this.port = 102});

  bool get isConnected => _connected;
  int get pduSize => _pduSize;

  Future<T> _serialize<T>(Future<T> Function() fn) {
    final c = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        c.complete(await fn());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  // ---------------------------------------------------------------- 连接

  Future<void> connect({Duration timeout = const Duration(seconds: 4)}) async {
    // 依次尝试配置的槽位，再兜底常见槽位（1200/1500 用 1，300/400 用 2）
    final tries = <List<int>>[];
    void add(int r, int s) {
      if (s < 0 || s > 31) return;
      if (tries.any((t) => t[0] == r && t[1] == s)) return;
      tries.add([r, s]);
    }

    add(rack, slot);
    add(0, 1);
    add(0, 2);
    add(0, 0);

    S7Exception? protoErr;
    for (final t in tries) {
      try {
        await _openTcp(timeout);
        await _cotpConnect(t[0], t[1], timeout);
        final ps = await _setupCommunication(timeout);
        _pduSize = ps.clamp(200, 960);
        usedSlot = t[1];
        _connected = true;
        return;
      } on SocketException catch (e) {
        await disconnect();
        throw _wrapSocket(e);
      } on TimeoutException {
        await disconnect();
        throw S7Exception('连接超时：站号/槽位尝试到 ${t[1]}，PLC 在 ${timeout.inSeconds}s 内没有响应。'
            '常见原因：IP 填错、目标不是 PLC（如填了电脑本机 IP）、防火墙拦截 102 端口。');
      } on S7Exception catch (e) {
        await disconnect();
        protoErr = e;
        // 协议层拒绝（槽位不对）→ 换下一个槽位继续试
        continue;
      } catch (e) {
        await disconnect();
        throw S7Exception('连接异常：$e');
      }
    }
    throw protoErr ?? S7Exception('S7 握手失败：所有槽位均被拒绝');
  }

  Future<void> _openTcp(Duration timeout) async {
    _socket = await Socket.connect(ip, port, timeout: timeout);
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    _reader = _ByteReader(_socket!);
  }

  Future<void> _cotpConnect(int r, int s, Duration timeout) async {
    // 03 00 00 16 | 11 E0 dst-ref src-ref class | C1 srcTSAP | C2 dstTSAP | C0 TPDU size
    final dstLow = ((r << 5) | s) & 0xFF;
    final cr = <int>[
      0x03, 0x00, 0x00, 0x16,
      0x11, 0xE0,
      0x00, 0x00,
      0x00, 0x01,
      0x00,
      0xC1, 0x02, 0x01, 0x00,
      0xC2, 0x02, 0x01, dstLow,
      0xC0, 0x01, 0x0A,
    ];
    _socket!.add(cr);

    final cc = await _readFrame(timeout);
    if (cc.length < 7 || cc[5] != 0xD0) {
      throw S7Exception('PLC 拒绝 COTP 连接（返回码 0x${(cc.length > 5 ? cc[5] : 0).toRadixString(16)}），'
          '通常是机架/槽位不对（1200/1500 槽位填 1，300/400 填 2）');
    }
  }

  Future<int> _setupCommunication(Duration timeout) async {
    // 03 00 00 19 | 02 F0 80 | 32 01 00 00 00 00 00 08 00 00 | F0 00 00 01 00 01 01 E0
    final job = <int>[
      0x03, 0x00, 0x00, 0x19,
      0x02, 0xF0, 0x80,
      0x32, 0x01, 0x00, 0x00,
      0x00, 0x00,
      0x00, 0x08,
      0x00, 0x00,
      0xF0, 0x00,
      0x00, 0x01,
      0x00, 0x01,
      0x01, 0xE0,
    ];
    _socket!.add(job);

    final r = await _readFrame(timeout);
    _assertS7(r);
    if (r[8] != 0x03) {
      throw S7Exception('通讯建立返回异常（ROSCTR=0x${r[8].toRadixString(16)}）');
    }
    final errClass = r[17], errCode = r[18];
    if (errClass != 0) throw _mapError(errClass, errCode);
    final plen = (r[13] << 8) | r[14];
    final paramStart = 19;
    if (plen >= 8 && r.length >= paramStart + 8 && r[paramStart] == 0xF0) {
      final ps = (r[paramStart + 6] << 8) | r[paramStart + 7];
      if (ps > 0) return ps;
    }
    return 240;
  }

  Future<void> disconnect() async {
    _connected = false;
    final s = _socket;
    _socket = null;
    _reader = null;
    try { await s?.close(); } catch (_) {}
    try { s?.destroy(); } catch (_) {}
  }

  // ---------------------------------------------------------------- 收发

  Future<Uint8List> _readFrame(Duration timeout) async {
    final reader = _reader;
    if (reader == null) throw S7Exception('未建立连接');
    final hdr = await reader.read(4, timeout: timeout);
    final total = (hdr[2] << 8) | hdr[3];
    if (total < 7) throw S7Exception('收到非法报文（长度字段 $total）');
    final body = await reader.read(total - 4, timeout: timeout);
    final out = Uint8List(total);
    out.setRange(0, 4, hdr);
    out.setRange(4, total, body);
    return out;
  }

  void _assertS7(Uint8List r) {
    if (r.length < 19) throw S7Exception('报文过短（${r.length} 字节），可能连到了非 S7 服务');
    if (r[7] != 0x32) {
      throw S7Exception('对方不是 S7 协议服务（协议标识 0x${r[7].toRadixString(16)}）。'
          '如果你填的是电脑本机 IP，102 端口可能是西门子 S7DOS 服务而不是 PLC。');
    }
  }

  /// 发送一个 S7 作业并读回完整应答帧
  Future<Uint8List> _exchange(List<int> pduBody, Duration timeout) async {
    _socket!.add(pduBody);
    final r = await _readFrame(timeout);
    _assertS7(r);
    return r;
  }

  // ---------------------------------------------------------------- 读位

  Future<List<bool>> readBits(List<S7Point> points,
      {Duration timeout = const Duration(seconds: 3)}) {
    return _serialize(() => _readBitsRaw(points, timeout: timeout));
  }

  Future<List<bool>> _readBitsRaw(List<S7Point> points,
      {required Duration timeout}) async {
    if (points.isEmpty) return <bool>[];
    if (!_connected) throw S7Exception('未连接');

    final maxItems = ((_pduSize - 20) ~/ 12).clamp(1, 19);
    final n = points.length > maxItems ? maxItems : points.length;
    final result = List<bool>.filled(points.length, false);

    int start = 0;
    while (start < points.length) {
      final cnt = (points.length - start) < n ? points.length - start : n;
      _pduRef = (_pduRef + 1) & 0xFFFF;
      final paramLen = 2 + cnt * 12;

      final b = BytesBuilder();
      b.add(<int>[0x03, 0x00, 0x00, 0x00]); // TPKT 占位
      b.add(<int>[0x02, 0xF0, 0x80]); // COTP DT
      b.add(<int>[0x32, 0x01, 0x00, 0x00]); // Job / user data / reserved
      b.add(<int>[(_pduRef >> 8) & 0xFF, _pduRef & 0xFF]);
      b.add(<int>[(paramLen >> 8) & 0xFF, paramLen & 0xFF]);
      b.add(<int>[0x00, 0x00]); // dataLen = 0（读请求无数据段）
      b.add(<int>[0x04, cnt & 0xFF]); // 功能：读
      for (int i = 0; i < cnt; i++) {
        final p = points[start + i];
        final addr = p.byteIndex * 8 + p.bitIndex;
        b.add(<int>[0x12, 0x0A, 0x10]); // S7ANY
        b.add(<int>[0x01]); // 传输尺寸：BIT
        b.add(<int>[0x00, 0x01]); // 长度：1 位
        b.add(<int>[(p.db >> 8) & 0xFF, p.db & 0xFF]);
        b.add(<int>[p.area & 0xFF]);
        b.add(<int>[(addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF]);
      }
      final bytes = b.toBytes();
      final tpkt = bytes.length;
      bytes[2] = (tpkt >> 8) & 0xFF;
      bytes[3] = tpkt & 0xFF;

      final r = await _exchange(bytes, timeout);
      final plen = (r[13] << 8) | r[14];
      final errClass = r[17], errCode = r[18];
      if (errClass != 0) throw _mapError(errClass, errCode);

      int pos = 19 + plen;
      for (int i = 0; i < cnt; i++) {
        if (pos + 4 > r.length) break;
        final rc = r[pos];
        final ts = r[pos + 1];
        final len = (r[pos + 2] << 8) | r[pos + 3];
        final isBitArea = ts == 0x03 || ts == 0x04;
        final byteLen = isBitArea ? ((len + 7) >> 3) : len;
        final padded = byteLen + (byteLen & 1); // 数据段按偶数字节对齐
        if (rc == 0xFF) {
          if (pos + 4 < r.length) {
            result[start + i] =
                decodeBit([r[pos + 4]], points[start + i].bitIndex);
          }
        } else if (rc == 0x05) {
          throw S7Exception('地址不存在（点位 ${start + i + 1}），请检查地址是否超出 PLC 实际范围');
        } else if (rc == 0x0A) {
          throw S7Exception('对象不存在（点位 ${start + i + 1}），DB 块可能未创建或为优化块');
        } else if (rc != 0xFF) {
          throw S7Exception('读点位 ${start + i + 1} 失败，返回码 0x${rc.toRadixString(16)}');
        }
        pos += 4 + padded;
      }
      start += cnt;
    }
    return result;
  }

  // ---------------------------------------------------------------- 读多类型

  /// 按数据类型批量读取，返回 Object?（bool / int / double）
  Future<List<Object?>> readValues(List<S7ReadItem> items,
      {Duration timeout = const Duration(seconds: 3)}) {
    return _serialize(() => _readValuesRaw(items, timeout: timeout));
  }

  Future<List<Object?>> _readValuesRaw(List<S7ReadItem> items,
      {required Duration timeout}) async {
    if (items.isEmpty) return <Object?>[];
    if (!_connected) throw S7Exception('未连接');

    badAddresses.clear();

    final maxItems = ((_pduSize - 20) ~/ 12).clamp(1, 19);
    final result = List<Object?>.filled(items.length, null);

    int start = 0;
    while (start < items.length) {
      final remain = items.length - start;
      final cnt = remain < maxItems ? remain : maxItems;
      _pduRef = (_pduRef + 1) & 0xFFFF;
      final paramLen = 2 + cnt * 12;

      final b = BytesBuilder();
      b.add(<int>[0x03, 0x00, 0x00, 0x00]); // TPKT 占位
      b.add(<int>[0x02, 0xF0, 0x80]); // COTP DT
      b.add(<int>[0x32, 0x01, 0x00, 0x00]); // Job
      b.add(<int>[(_pduRef >> 8) & 0xFF, _pduRef & 0xFF]);
      b.add(<int>[(paramLen >> 8) & 0xFF, paramLen & 0xFF]);
      b.add(<int>[0x00, 0x00]); // 读请求 dataLen = 0
      b.add(<int>[0x04, cnt & 0xFF]); // 功能：读

      for (int i = 0; i < cnt; i++) {
        final it = items[start + i];
        final p = it.point;
        final isBit = it.type.isBit;
        final bits = p.byteIndex * 8 + (isBit ? p.bitIndex : 0);
        final size = isBit ? 1 : it.type.byteSize;
        b.add(<int>[0x12, 0x0A, 0x10]); // S7ANY
        b.add(<int>[isBit ? 0x01 : 0x02]); // 传输尺寸：BIT / BYTE
        b.add(<int>[(size >> 8) & 0xFF, size & 0xFF]);
        b.add(<int>[(p.db >> 8) & 0xFF, p.db & 0xFF]);
        b.add(<int>[p.area & 0xFF]);
        b.add(<int>[(bits >> 16) & 0xFF, (bits >> 8) & 0xFF, bits & 0xFF]);
      }

      final bytes = b.toBytes();
      bytes[2] = (bytes.length >> 8) & 0xFF;
      bytes[3] = bytes.length & 0xFF;

      final r = await _exchange(bytes, timeout);
      final plen = (r[13] << 8) | r[14];
      final errClass = r[17], errCode = r[18];
      if (errClass != 0) throw _mapError(errClass, errCode);

      // 应答头 12 字节：0x32 / ROSCTR / 冗余ID×2 / PDUref×2 / paramLen×2 / dataLen×2
      // 绝对偏移：7=协议ID 8=ROSCTR 13-14=paramLen 15-16=dataLen 17-18=错误
      final dataLen = (r[15] << 8) | r[16];
      final dataStart = 19 + plen;

      // 数据项布局：不同固件对「填充字节」的处理不一致。
      // 有填充 / 无填充各解析一遍，谁能让游标正好落在数据段末尾就用谁。
      List<Object?>? parsed = _parseItems(r, dataStart, dataLen, items, start, cnt, pad: true);
      parsed ??= _parseItems(r, dataStart, dataLen, items, start, cnt, pad: false);
      // 兜底：dataLen 字段不可信时，按「奇数长度补 1 字节」硬解析到帧尾
      parsed ??= _parseItems(r, dataStart,
          (r.length - dataStart).clamp(0, r.length), items, start, cnt,
          pad: true, strict: false);

      if (parsed == null) {
        if (_itemError != null) _raiseItemError(_itemError!, start);
        throw S7Exception('读应答的数据段无法解析（长度 ${r.length} 字节）。'
            '可能是 PLC 与 App 的 PDU 尺寸不匹配，请重新连接后再试。');
      }
      for (int i = 0; i < cnt; i++) {
        result[start + i] = parsed[i];
      }
      start += cnt;
    }
    return result;
  }

  /// 最近一次解析遇到的项错误码（用于给出准确的中文提示）
  int? _itemError;

  /// 最近一次 readValues 里 PLC 上读不到的点位地址（rc != 0xFF，值为 null）
  final List<String> badAddresses = [];

  // ---------------------------------------------------------------- 读字节块

  /// 从 [start] 开始连续读 [count] 个字节（报警位批量采集用，一次读一整段）
  ///
  /// 返回原始字节。地址超界（rc=0x05/0x0A）等错误直接抛异常。
  Future<List<int>> readBytes(S7Point start, int count,
      {Duration timeout = const Duration(seconds: 3)}) {
    return _serialize(() => _readBytesRaw(start, count, timeout: timeout));
  }

  Future<List<int>> _readBytesRaw(S7Point start, int count,
      {required Duration timeout}) async {
    if (count <= 0) return <int>[];
    if (!_connected) throw S7Exception('未连接');

    _pduRef = (_pduRef + 1) & 0xFFFF;
    final addr = start.byteIndex * 8;
    final b = BytesBuilder();
    b.add(<int>[0x03, 0x00, 0x00, 0x00]); // TPKT 占位
    b.add(<int>[0x02, 0xF0, 0x80]); // COTP DT
    b.add(<int>[0x32, 0x01, 0x00, 0x00]); // Job
    b.add(<int>[(_pduRef >> 8) & 0xFF, _pduRef & 0xFF]);
    b.add(<int>[0x00, 0x0E]); // paramLen = 14（功能 1 字节 + 项数 1 字节 + 项 12 字节）
    b.add(<int>[0x00, 0x00]); // dataLen = 0
    b.add(<int>[0x04, 0x01]); // 功能：读，1 个项
    b.add(<int>[0x12, 0x0A, 0x10]); // S7ANY
    b.add(<int>[0x02]); // 传输尺寸：BYTE
    b.add(<int>[(count >> 8) & 0xFF, count & 0xFF]); // 长度：count 字节
    b.add(<int>[(start.db >> 8) & 0xFF, start.db & 0xFF]);
    b.add(<int>[start.area & 0xFF]);
    b.add(<int>[(addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF]);

    final bytes = b.toBytes();
    final tpkt = bytes.length;
    bytes[2] = (tpkt >> 8) & 0xFF;
    bytes[3] = tpkt & 0xFF;

    final r = await _exchange(bytes, timeout);
    final errClass = r[17], errCode = r[18];
    if (errClass != 0) throw _mapError(errClass, errCode);

    final plen = (r[13] << 8) | r[14];
    int pos = 19 + plen;
    if (pos + 4 > r.length) throw S7Exception('读字节块应答异常');
    final rc = r[pos];
    final ts = r[pos + 1];
    final lenField = (r[pos + 2] << 8) | r[pos + 3];
    if (rc != 0xFF) {
      throw S7Exception('读字节块失败，返回码 0x${rc.toRadixString(16)}'
          '${rc == 0x0A ? '（DB 块可能未创建或为优化块）' : ''}');
    }
    // BYTE/WORD 应答长度是「位数」，OCTET_STRING(0x09) 是「字节数」
    final byteLen =
        ts == 0x09 ? lenField : (ts == 0x03 || ts == 0x04 ? (lenField + 7) >> 3 : lenField);
    final take = byteLen < count ? byteLen : count;
    final out = <int>[];
    for (int i = 0; i < take; i++) {
      out.add(r[pos + 4 + i] & 0xFF);
    }
    while (out.length < count) out.add(0); // 不足补 0，不打断轮询
    return out;
  }


  /// 解析读应答的数据项；布局与声明长度不符时返回 null
  ///
  /// 容错：某个项 rc != 0xFF（地址不存在 / 优化块等）时，该项值保持 null、
  /// 地址记入 [badAddresses]，其余项正常解析——一个坏点位不再打死整帧读取。
  List<Object?>? _parseItems(Uint8List r, int dataStart, int dataLen,
      List<S7ReadItem> items, int start, int cnt,
      {required bool pad, bool strict = true}) {
    _itemError = null;
    if (dataStart < 0 || dataStart > r.length) return null;
    final end = dataStart + dataLen;
    if (end > r.length) return null;

    final out = List<Object?>.filled(cnt, null);
    int pos = dataStart;
    for (int i = 0; i < cnt; i++) {
      final idx = start + i;
      if (pos + 4 > end) return null;
      final rc = r[pos];
      if (rc != 0xFF) {
        // 错误项应答：transport size 固定 0x04、长度 0 → 只有 4 字节头、无数据
        _itemError ??= rc;
        badAddresses.add(formatS7Point(items[idx].point,
            isBit: items[idx].type.isBit));
        pos += 4;
        continue;
      }
      final ts = r[pos + 1];
      final lenField = (r[pos + 2] << 8) | r[pos + 3];
      final byteLen = dataLenBytes(ts, lenField, items[idx].type.byteSize);
      if (byteLen < 0 || pos + 4 + byteLen > end) return null;

      // 声明长度可能少于类型所需（个别固件 REAL 只报 4「位」），
      // 此时按类型字节数往后取，但绝不越过数据段。
      final need = items[idx].type.byteSize;
      final avail = end - (pos + 4);
      final take = byteLen >= need ? byteLen : (need <= avail ? need : avail);
      final raw = r.sublist(pos + 4, pos + 4 + take);
      out[i] = items[idx].type.isBit
          ? decodeBit(raw, items[idx].point.bitIndex)
          : items[idx].type.decode(raw);

      // 奇数长度项后跟 1 个填充字节；但最后一项不补（补了会越过数据段末尾）
      var next = pos + 4 + byteLen;
      if (pad && (byteLen & 1) == 1 && next + 1 <= end) next += 1;
      pos = next;
      if (pos > end) return null;
    }
    if (strict && pos != end) return null;
    return out;
  }

  void _raiseItemError(int rc, int start) {
    if (rc == 0x05) {
      throw S7Exception('地址不存在（点位 ${start + 1} 起），请检查地址是否超出 PLC 实际范围');
    }
    if (rc == 0x0A) {
      throw S7Exception('对象不存在（点位 ${start + 1} 起），DB 块可能未创建或为「优化的块访问」');
    }
    throw S7Exception('读点位 ${start + 1} 失败，返回码 0x${rc.toRadixString(16)}');
  }

  // ---------------------------------------------------------------- 写位

  Future<bool> writeBit(S7Point p, bool value,
      {Duration timeout = const Duration(seconds: 3)}) {
    return _serialize(() => _writeBitRaw(p, value, timeout: timeout));
  }

  Future<bool> _writeBitRaw(S7Point p, bool value,
      {required Duration timeout}) async {
    if (!_connected) throw S7Exception('未连接');
    _pduRef = (_pduRef + 1) & 0xFFFF;
    final addr = p.byteIndex * 8 + p.bitIndex;

    final b = BytesBuilder();
    b.add(<int>[0x03, 0x00, 0x00, 0x00]);
    b.add(<int>[0x02, 0xF0, 0x80]);
    b.add(<int>[0x32, 0x01, 0x00, 0x00]);
    b.add(<int>[(_pduRef >> 8) & 0xFF, _pduRef & 0xFF]);
    b.add(<int>[0x00, 0x0E]); // paramLen = 14
    b.add(<int>[0x00, 0x06]); // dataLen = 6
    b.add(<int>[0x05, 0x01]); // 功能：写，1 个项
    b.add(<int>[0x12, 0x0A, 0x10]);
    b.add(<int>[0x01]); // BIT
    b.add(<int>[0x00, 0x01]);
    b.add(<int>[(p.db >> 8) & 0xFF, p.db & 0xFF]);
    b.add(<int>[p.area & 0xFF]);
    b.add(<int>[(addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF]);
    // 数据段
    b.add(<int>[0x00, 0x03, 0x00, 0x01, value ? 0x01 : 0x00, 0x00]);

    final bytes = b.toBytes();
    bytes[2] = (bytes.length >> 8) & 0xFF;
    bytes[3] = bytes.length & 0xFF;

    final r = await _exchange(bytes, timeout);
    final plen = (r[13] << 8) | r[14];
    final errClass = r[17], errCode = r[18];
    if (errClass != 0) throw _mapError(errClass, errCode);
    final dataStart = 19 + plen;
    if (dataStart < r.length) {
      final rc = r[dataStart];
      if (rc == 0xFF) return true;
      throw S7Exception('写点位失败，返回码 0x${rc.toRadixString(16)}'
          '（0x05=地址不存在，0x0A=对象不存在/优化块）');
    }
    return false;
  }

  // ---------------------------------------------------------------- 写字节

  /// 写数值型变量（BYTE / WORD / DWORD / INT / DINT / REAL / LREAL）
  ///
  /// S7 写请求里 item 的 transport size 统一用 0x02（BYTE）、长度为字节数，
  /// data 段 transport size 用 0x04（BYTE/WORD/DWORD）、长度字段为位数。
  /// 这样 INT / DINT / REAL 不用各写一套，PLC 按字节覆盖写入，兼容性最好。
  Future<bool> writeVar(S7Point p, VarType t, num value,
      {Duration timeout = const Duration(seconds: 3)}) {
    return _serialize(() => _writeVarRaw(p, t, value, timeout: timeout));
  }

  Future<bool> _writeVarRaw(S7Point p, VarType t, num value,
      {required Duration timeout}) async {
    if (!_connected) throw S7Exception('未连接');
    final bytes = t.encodeNum(value);
    _pduRef = (_pduRef + 1) & 0xFFFF;
    final addr = p.byteIndex * 8; // 字节型变量按字节对齐

    final b = BytesBuilder();
    b.add(<int>[0x03, 0x00, 0x00, 0x00]);
    b.add(<int>[0x02, 0xF0, 0x80]);
    b.add(<int>[0x32, 0x01, 0x00, 0x00]);
    b.add(<int>[(_pduRef >> 8) & 0xFF, _pduRef & 0xFF]);
    b.add(<int>[0x00, 0x0E]); // paramLen = 14
    final dataLen = 4 + bytes.length + (bytes.length.isOdd ? 1 : 0);
    b.add(<int>[(dataLen >> 8) & 0xFF, dataLen & 0xFF]);
    b.add(<int>[0x05, 0x01]); // 功能：写，1 个项
    b.add(<int>[0x12, 0x0A, 0x10]);
    b.add(<int>[0x02]); // BYTE
    b.add(<int>[0x00, bytes.length]); // 元素个数 = 字节数
    b.add(<int>[(p.db >> 8) & 0xFF, p.db & 0xFF]);
    b.add(<int>[p.area & 0xFF]);
    b.add(<int>[(addr >> 16) & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF]);
    // 数据段
    b.add(<int>[0x00, 0x04]);
    final bits = bytes.length * 8;
    b.add(<int>[(bits >> 8) & 0xFF, bits & 0xFF]);
    b.add(bytes);
    if (bytes.length.isOdd) b.add(<int>[0x00]); // 奇数长度补 1 字节

    final raw = b.toBytes();
    raw[2] = (raw.length >> 8) & 0xFF;
    raw[3] = raw.length & 0xFF;

    final r = await _exchange(raw, timeout);
    final plen = (r[13] << 8) | r[14];
    final errClass = r[17], errCode = r[18];
    if (errClass != 0) throw _mapError(errClass, errCode);
    final dataStart = 19 + plen;
    if (dataStart < r.length) {
      final rc = r[dataStart];
      if (rc == 0xFF) return true;
      throw S7Exception('写入失败，返回码 0x${rc.toRadixString(16)}'
          '（0x05=地址不存在，0x0A=对象不存在/优化块）');
    }
    return false;
  }

  // ---------------------------------------------------------------- 错误

  S7Exception _mapError(int errClass, int errCode) {
    final hex = '0x${errClass.toRadixString(16).padLeft(2, '0')}'
        '${errCode.toRadixString(16).padLeft(2, '0')}';
    if (errClass == 0x81 && errCode == 0x04) {
      return S7Exception('PLC 拒绝访问（$hex）：未开启 PUT/GET 通讯许可。请在博图里 '
          'CPU 属性 → 保护与安全 → 连接机制，勾选「允许来自远程伙伴的 PUT/GET 通讯访问」，'
          '然后重新下载硬件组态。');
    }
    if (errClass == 0x85) {
      return S7Exception('CPU 无法处理请求（$hex）：仿真未运行 / CPU 处于 STOP / 该功能不被支持');
    }
    if (errClass == 0x81) {
      return S7Exception('访问被拒绝（$hex）：地址区域不允许外部读写，或 CPU 保护等级过高');
    }
    return S7Exception('PLC 返回错误 $hex（错误类 0x${errClass.toRadixString(16)}'
        '，错误码 0x${errCode.toRadixString(16)}）');
  }

  S7Exception _wrapSocket(SocketException e) {
    final msg = e.message.toLowerCase();
    final os = (e.osError?.message ?? '').toLowerCase();
    if (msg.contains('permitted') || os.contains('permitted') ||
        msg.contains('denied') || os.contains('denied')) {
      return S7Exception('没有网络权限：APK 未声明 INTERNET 权限（这是安装包问题，不是网络问题）');
    }
    if (msg.contains('refused') || os.contains('refused')) {
      return S7Exception('目标拒绝连接：${ip}:102 没有 S7 服务（IP 填错 / PLC 未运行 / 该地址不是 PLC）');
    }
    if (msg.contains('unreachable') || os.contains('unreachable') ||
        msg.contains('no route')) {
      return S7Exception('网络不可达：手机与 ${ip} 不在同一网段，或中间路由不通');
    }
    return S7Exception('网络错误：${e.message}${e.osError != null ? '（${e.osError!.message}）' : ''}');
  }
}
