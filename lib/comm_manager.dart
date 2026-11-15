/// 通讯管理器：按设备维护连接、轮询、写入
library comm_manager;

import 'dart:async';
import 'models.dart';
import 's7_client.dart' as s7;
import 'modbus_client.dart' as mb;
import 'store.dart';

enum ConnState { disconnected, connecting, connected, error }

class DeviceStatus {
  ConnState state = ConnState.disconnected;
  String message = '未连接';
  int latencyMs = 0;

  /// pointId -> 变量值（bool / int / double）
  Map<String, Object?> values = {};

  /// 最近一次写入失败的说明（长按点动用）
  String? writeError;

  /// 某点位当前是否「有效」（布尔看真假，数值看是否非 0）
  bool isOn(String pointId) {
    final v = values[pointId];
    if (v is bool) return v;
    if (v is num) return v != 0;
    return false;
  }
}

class CommManager {
  CommManager._();
  static final CommManager instance = CommManager._();

  final Map<String, DeviceStatus> status = {};
  final Map<String, dynamic> _clients = {};
  final Map<String, Timer?> _pollers = {};
  final Map<String, bool> _polling = {};
  final Map<String, List<void Function()>> _listeners = {};
  final List<void Function()> _globalListeners = [];

  DeviceStatus st(String deviceId) =>
      status.putIfAbsent(deviceId, () => DeviceStatus());

  void onChange(String deviceId, void Function() fn) {
    _listeners.putIfAbsent(deviceId, () => []).add(fn);
  }

  /// 全局连接状态变化监听（设备列表页用）
  void onAnyChange(void Function() fn) => _globalListeners.add(fn);

  void _notify(String deviceId) {
    for (final fn in _listeners[deviceId] ?? const []) fn();
    for (final fn in _globalListeners) fn();
  }

  bool _isModbus(Device d) => d.protocol == Protocol.modbusTcp;

  Future<bool> connect(Device d) async {
    final s = st(d.id);
    s.state = ConnState.connecting;
    s.message = '正在连接 ${d.ip} …';
    _notify(d.id);
    try {
      await disconnect(d);
      s.state = ConnState.connecting;
      if (_isModbus(d)) {
        final c = mb.ModbusTcpClient(d.ip);
        await c.connect();
        _clients[d.id] = c;
      } else {
        // s7 与 plcsim 都走 S7 协议
        final c = s7.S7Client(d.ip.split(':').first.trim(),
            rack: d.rack, slot: d.slot, port: d.port);
        await c.connect();
        _clients[d.id] = c;
      }
      s.state = ConnState.connected;
      s.message = '通讯正常';
      _notify(d.id);
      _startPoll(d);
      return true;
    } catch (e) {
      s.state = ConnState.error;
      s.message = _describe(e);
      _notify(d.id);
      return false;
    }
  }

  Future<void> disconnect(Device d) async {
    // 先同步更新状态，返回设备页时卡片能立即显示"未连接"
    _pollers[d.id]?.cancel();
    _pollers[d.id] = null;
    _polling[d.id] = false;
    final s = st(d.id);
    s.state = ConnState.disconnected;
    s.message = '未连接';
    final c = _clients.remove(d.id);
    if (c != null) {
      try {
        await c.disconnect();
      } catch (_) {}
    }
    _notify(d.id);
  }

  /// 设备被删除后清掉它的状态与监听（务必在 disconnect 之后调用）
  void forget(String deviceId) {
    _pollers.remove(deviceId)?.cancel();
    _polling.remove(deviceId);
    _clients.remove(deviceId);
    status.remove(deviceId);
    _listeners.remove(deviceId);
  }

  // ------------------------------------------------------------ 轮询

  void _startPoll(Device d) {
    _pollers[d.id]?.cancel();
    _pollers[d.id] = Timer(const Duration(milliseconds: 200), () => _pollOnce(d));
  }

  Future<void> _pollOnce(Device d) async {
    if (_polling[d.id] == true) return;
    _polling[d.id] = true;
    final s = st(d.id);
    try {
      final c = _clients[d.id];
      if (c == null) return;
      final tpl = AppStore.instance.templateOf(d);
      if (tpl == null) return;
      final points = tpl.points.where((p) => p.type != PointType.image).toList();
      if (points.isEmpty) return;

      final t0 = DateTime.now();
      List<Object?> vals;
      if (_isModbus(d)) {
        final mbp = points
            .map((p) => mb.parseModbusAddress(AppStore.instance.addrOf(d, p)))
            .toList();
        if (mbp.any((e) => e == null)) throw Exception('存在无法解析的地址');
        final bits =
            await (c as mb.ModbusTcpClient).readBits(mbp.cast<mb.MbPoint>());
        vals = List<Object?>.from(bits);
      } else {
        final items = <s7.S7ReadItem>[];
        for (final p in points) {
          final addr = AppStore.instance.addrOf(d, p);
          final sp = s7.parseS7Address(addr);
          if (sp == null) {
            throw Exception('地址「$addr」无法解析（支持 I0.0 / M10.0 / MW10 / DB1.DBW0 等写法）');
          }
          items.add(s7.S7ReadItem(sp, p.dataType));
        }
        vals = await (c as s7.S7Client).readValues(items);
      }
      s.latencyMs = DateTime.now().difference(t0).inMilliseconds;
      for (int i = 0; i < points.length && i < vals.length; i++) {
        s.values[points[i].id] = vals[i];
      }
      if (s.state != ConnState.connected || s.message != '通讯正常') {
        s.state = ConnState.connected;
        s.message = '通讯正常';
      }
    } catch (e) {
      s.state = ConnState.error;
      s.message = _describe(e);
      _notify(d.id);
      _polling[d.id] = false;
      // 断线：2 秒后自动重连
      _pollers[d.id]?.cancel();
      if (_clients.containsKey(d.id)) {
        _pollers[d.id] = Timer(const Duration(seconds: 2), () {
          if (_clients.containsKey(d.id)) connect(d);
        });
      }
      return;
    } finally {
      _polling[d.id] = false;
      _notify(d.id);
    }
    // 上一次读完成后 400ms 再读，避免请求堆积
    if (_clients.containsKey(d.id) && st(d.id).state == ConnState.connected) {
      _pollers[d.id]?.cancel();
      _pollers[d.id] = Timer(const Duration(milliseconds: 400), () => _pollOnce(d));
    }
  }

  // ------------------------------------------------------------ 写位

  Future<bool> writeBit(Device d, PointItem p, bool value) async {
    if (!p.dataType.isBit) {
      st(d.id).writeError = '「${p.name}」是 ${p.dataType.label} 类型，点动写入只支持 BOOL';
      _notify(d.id);
      return false;
    }
    final c = _clients[d.id];
    if (c == null) {
      st(d.id).writeError = '未连接：无法写入';
      _notify(d.id);
      return false;
    }
    try {
      final addr = AppStore.instance.addrOf(d, p);
      bool ok;
      if (_isModbus(d)) {
        final mp = mb.parseModbusAddress(addr);
        if (mp == null || mp.isInput) {
          st(d.id).writeError = '地址「$addr」不可写（输入点不能写）';
          _notify(d.id);
          return false;
        }
        ok = await (c as mb.ModbusTcpClient).writeBit(mp.addr, value);
      } else {
        final sp = s7.parseS7Address(addr);
        if (sp == null) {
          st(d.id).writeError = '地址「$addr」无法解析';
          _notify(d.id);
          return false;
        }
        ok = await (c as s7.S7Client).writeBit(sp, value);
      }
      if (!ok) {
        st(d.id).writeError = '写入 $addr 失败';
        _notify(d.id);
      } else {
        st(d.id).writeError = null;
      }
      return ok;
    } catch (e) {
      st(d.id).writeError = _describe(e);
      _notify(d.id);
      return false;
    }
  }

  // ------------------------------------------------------------ 写数值

  /// 写入任意类型的值：BOOL 走位写，数值类型走字节写
  Future<bool> writeValue(Device d, PointItem p, Object value) async {
    if (p.dataType.isBit) {
      return writeBit(d, p, value == true || value == 1);
    }
    final c = _clients[d.id];
    if (c == null) {
      st(d.id).writeError = '未连接：无法写入';
      _notify(d.id);
      return false;
    }
    if (_isModbus(d)) {
      st(d.id).writeError = 'Modbus TCP 目前只支持线圈（位）写入，数值写入仅 S7 可用';
      _notify(d.id);
      return false;
    }
    try {
      final addr = AppStore.instance.addrOf(d, p);
      final sp = s7.parseS7Address(addr);
      if (sp == null) {
        st(d.id).writeError = '地址「$addr」无法解析';
        _notify(d.id);
        return false;
      }
      final num v = value is num ? value : 0;
      final ok = await (c as s7.S7Client).writeVar(sp, p.dataType, v);
      if (ok) {
        st(d.id).values[p.id] = v; // 立即回显，不用等下一轮轮询
        st(d.id).writeError = null;
      } else {
        st(d.id).writeError = '写入 $addr 失败';
      }
      _notify(d.id);
      return ok;
    } catch (e) {
      st(d.id).writeError = _describe(e);
      _notify(d.id);
      return false;
    }
  }

  // ------------------------------------------------------------ 错误说明

  String _describe(Object e) {
    final s = e is TimeoutException ? '超时：PLC 无响应（${e.message ?? ''}）' : e.toString();
    if (s.length > 200) return s.substring(0, 200);
    return s;
  }
}
