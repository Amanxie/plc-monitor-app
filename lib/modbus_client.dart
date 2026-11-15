/// Modbus TCP 客户端（纯 Dart，0x502 端口 502）
/// 支持：读线圈/离散量，写单个线圈
library modbus_client;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 地址约定："HR0"=线圈0（位），"IR0"=离散输入0
/// 简化约定：线圈写地址 0-9999；离散输入用前缀 'I'，如 "I0"
class MbPoint {
  final bool isInput; // true=离散输入(0x02)，false=线圈(0x01/0x05)
  final int addr;
  MbPoint(this.isInput, this.addr);
}

MbPoint? parseModbusAddress(String addr) {
  final a = addr.trim().toUpperCase();
  try {
    if (a.startsWith('I') && int.tryParse(a.substring(1)) != null) {
      return MbPoint(true, int.parse(a.substring(1)));
    }
    if (a.startsWith('HR') && int.tryParse(a.substring(2)) != null) {
      return MbPoint(false, int.parse(a.substring(2)));
    }
    final v = int.tryParse(a);
    if (v != null) return MbPoint(false, v);
  } catch (_) {}
  return null;
}

class ModbusTcpClient {
  Socket? _socket;
  bool _connected = false;
  int _txn = 0;
  final String ip;
  final int unitId;
  final List<int> _buf = [];

  ModbusTcpClient(this.ip, {this.unitId = 1});

  bool get isConnected => _connected;

  Future<void> connect({Duration timeout = const Duration(seconds: 3)}) async {
    final s = await Socket.connect(ip, 502, timeout: timeout);
    _socket = s;
    _buf.clear();
    s.listen((d) => _buf.addAll(d), onDone: () => _connected = false,
        onError: (_) => _connected = false);
    _connected = true;
  }

  Future<void> disconnect() async {
    _connected = false;
    try { await _socket?.close(); } catch (_) {}
    try { _socket?.destroy(); } catch (_) {}
    _socket = null;
  }

  Future<List<bool>> readBits(List<MbPoint> points,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final result = List<bool>.filled(points.length, false);
    // 按输入/输出分组，各自最多 120 个连续读太复杂，这里简化为逐点读（点位少，够用）
    final s = _socket;
    if (s == null || !_connected) throw Exception('未连接');
    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      _txn = (_txn + 1) & 0xFFFF;
      final req = Uint8List(12);
      final bd = ByteData.view(req.buffer);
      bd.setUint16(0, _txn);
      bd.setUint16(2, 0);
      bd.setUint16(4, 6);
      req[6] = unitId;
      req[7] = p.isInput ? 0x02 : 0x01;
      bd.setUint16(8, p.addr);
      bd.setUint16(10, 1);
      _buf.clear();
      s.add(req);
      final resp = await _readResp(_txn, timeout);
      if (resp.length >= 10 && resp[7] == req[7]) {
        result[i] = (resp[9] & 0x01) == 1;
      }
    }
    return result;
  }

  Future<bool> writeBit(int addr, bool value,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final s = _socket;
    if (s == null || !_connected) throw Exception('未连接');
    _txn = (_txn + 1) & 0xFFFF;
    final req = Uint8List(12);
    final bd = ByteData.view(req.buffer);
    bd.setUint16(0, _txn);
    bd.setUint16(2, 0);
    bd.setUint16(4, 6);
    req[6] = unitId;
    req[7] = 0x05; // write single coil
    bd.setUint16(8, addr);
    bd.setUint16(10, value ? 0xFF00 : 0x0000);
    _buf.clear();
    s.add(req);
    final resp = await _readResp(_txn, timeout);
    return resp.length >= 12;
  }

  Future<Uint8List> _readResp(int txn, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (_buf.length >= 8) {
        final len = (_buf[4] << 8) | _buf[5];
        if (_buf.length >= 6 + len) {
          final out = Uint8List.fromList(_buf.sublist(0, 6 + len));
          _buf.removeRange(0, 6 + len);
          final t = (out[0] << 8) | out[1];
          if (t == txn) return out;
          continue;
        }
      }
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('PLC 响应超时');
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }
}
