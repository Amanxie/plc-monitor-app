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

  /// 报警位原始值：报警 ID -> 当前位值（与 AlarmItem.triggerHigh 比较得是否报警）
  Map<int, bool> alarmRaw = {};

  /// 状态灯颜色（'red'/'yellow'/'green'/'gray'；'gray' = 未配置或都为 0 / 未读到）
  String lampColor = 'gray';

  /// 报警采集诊断：本轮扫描的字节段总数 / 其中读不到的段数 / 读不到段的位置描述
  int alarmSegTotal = 0;
  int alarmSegFailed = 0;
  String alarmFailDesc = '';

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

  /// 摘掉监听（页面销毁时必须调，否则回调会打到已销毁的页面）
  void offChange(String deviceId, void Function() fn) {
    _listeners[deviceId]?.remove(fn);
  }

  /// 全局连接状态变化监听（设备列表页用）
  void onAnyChange(void Function() fn) => _globalListeners.add(fn);

  void _notify(String deviceId) {
    for (final fn in _listeners[deviceId] ?? const []) fn();
    for (final fn in _globalListeners) fn();
  }

  /// 外部改了状态对象后手动触发界面刷新（测试 / 特殊场景用）
  void notify(String deviceId) => _notify(deviceId);

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
    _alarmTimers.remove(d.id)?.cancel();
    _alarmPolling.remove(d.id);
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
    _alarmTimers.remove(deviceId)?.cancel();
    _alarmPolling.remove(deviceId);
    _badAddrs.remove(deviceId);
    _alarmFailCnt.removeWhere((k, _) => k.startsWith('$deviceId/'));
  }

  // ------------------------------------------------------------ 轮询

  void _startPoll(Device d) {
    _pollers[d.id]?.cancel();
    _pollers[d.id] = Timer(const Duration(milliseconds: 200), () => _pollOnce(d));
    // 报警独立 1 秒节奏：连上先立即采一次，之后每秒一次，不跟主轮询抢时间
    _alarmTimers[d.id]?.cancel();
    _pollAlarms(d).catchError((_) {});
    _alarmTimers[d.id] = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollAlarms(d).catchError((_) {});
    });
  }

  Future<void> _pollOnce(Device d) async {
    if (_polling[d.id] == true) return;
    _polling[d.id] = true;
    final s = st(d.id);
    try {
      final c = _clients[d.id];
      if (c == null) return;
      // 轮询案例自己的点位：模板删了、改了都不影响通讯
      final points = d.points.where((p) => p.type != PointType.image).toList();
      // 只有「没有任何点位、也没有报警」时才跳过；只配了报警的案例照样要采
      final hasAlarms = d.alarms.isNotEmpty || d.lampAddrs.isNotEmpty;
      if (points.isEmpty && !hasAlarms) return;

      final t0 = DateTime.now();
      List<Object?> vals = const [];
      String badMsg = '';
      if (points.isNotEmpty) {
        if (_isModbus(d)) {
          final mbp = points
              .map((p) => mb.parseModbusAddress(AppStore.instance.addrOf(d, p)))
              .toList();
          if (mbp.any((e) => e == null)) throw Exception('存在无法解析的地址');
          final bits =
              await (c as mb.ModbusTcpClient).readBits(mbp.cast<mb.MbPoint>());
          vals = List<Object?>.from(bits);
        } else {
          // 坏点位（PLC 返回地址不存在）跳过，之后不再对它发通讯请求
          final bad = _badAddrs.putIfAbsent(d.id, () => <String>{});
          final pairs = <(PointItem, s7.S7ReadItem)>[];
          final badNames = <String>[]; // 本轮被跳过的点位（地址解析失败的也算）
          for (final p in points) {
            final addr = AppStore.instance.addrOf(d, p);
            if (bad.contains(addr)) continue;
            final sp = s7.parseS7Address(addr);
            if (sp == null) {
              badNames.add('「${p.name}」$addr 无法解析');
              continue;
            }
            pairs.add((p, s7.S7ReadItem(sp, p.dataType)));
          }
          if (pairs.isNotEmpty) {
            final r = await (c as s7.S7Client)
                .readValues(pairs.map((e) => e.$2).toList());
            for (int i = 0; i < pairs.length && i < r.length; i++) {
              s.values[pairs[i].$1.id] = r[i];
            }
            // PLC 回「地址不存在」的点位：记住地址，下轮起不再读
            bad.addAll(c.badAddresses);
          }
          if (badNames.isNotEmpty || bad.isNotEmpty) {
            final shown = [...badNames, ...bad].take(3).join('、');
            final n = badNames.length + bad.length;
            badMsg = '通讯正常 · $n 个点位 PLC 上读不到，已跳过：$shown';
          }
        }
      }
      s.latencyMs = DateTime.now().difference(t0).inMilliseconds;
      for (int i = 0; i < points.length && i < vals.length; i++) {
        s.values[points[i].id] = vals[i];
      }
      // 报警采集由独立 1 秒定时器驱动（见 _startPoll），这里不再触发
      s.state = ConnState.connected;
      if (s.message != badMsg) s.message = badMsg.isEmpty ? '通讯正常' : badMsg;
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

  // ------------------------------------------------------------ 报警采集

  /// 报警采集独立定时器（deviceId → Timer），每秒触发一次
  final Map<String, Timer> _alarmTimers = {};

  /// 正在采报警的设备（上一轮没读完时跳过本轮，避免请求堆积）
  final Set<String> _alarmPolling = {};

  /// 坏点位地址缓存（deviceId → 地址集）：PLC 明确回答「地址不存在」的点位，
  /// 之后轮询直接跳过，不再向 PLC 发通讯请求；点位改地址后自然失效。
  final Map<String, Set<String>> _badAddrs = {};

  /// 报警字节段连续失败计数（deviceId/db/area/startByte → 次数），
  /// 连续 3 次失败（地址超界等确定性错误）拉黑，之后该段不再通讯
  final Map<String, int> _alarmFailCnt = {};

  /// 批量采集报警位 + 报警灯位（只支持 S7 / PLCSIM；报警表是 S7 地址格式）
  ///
  /// 优化：同一区（DB 号 / M 区）内把连续的字节段合并成一整块读，
  /// 268 条报警通常只需要 3~4 次报文交互，而不是逐位读 268 次。
  Future<void> _pollAlarms(Device d) async {
    if (_alarmPolling.contains(d.id)) return; // 上一轮还没读完，跳过本轮
    _alarmPolling.add(d.id);
    try {
      await _pollAlarmsImpl(d);
    } finally {
      _alarmPolling.remove(d.id);
    }
  }

  Future<void> _pollAlarmsImpl(Device d) async {
    final s0 = st(d.id);
    if (_isModbus(d)) {
      // Modbus 设备：报警表是 S7 地址格式，明确告知不支持，避免一直「读取报警中…」
      s0.alarmSegTotal = 0;
      s0.alarmSegFailed = 1;
      s0.alarmFailDesc = 'Modbus 设备暂不支持报警采集';
      return;
    }
    final c = _clients[d.id];
    if (c == null) return;

    final s = st(d.id);
    // 收集要读的位：状态灯三色（key = -1 红 / -2 黄 / -3 绿）+ 每条报警（key = 报警 ID）
    final wanted = <(s7.S7Point, int, bool)>[]; // (地址解析, key, 是否状态灯)
    int unparsed = 0; // 无法解析的地址条数
    for (final (addr, color) in d.lampAddrs) {
      final p = s7.parseS7Address(addr);
      if (p != null) {
        wanted.add((p, color == 'red' ? -1 : (color == 'yellow' ? -2 : -3), true));
      } else {
        unparsed++;
      }
    }
    for (final a in d.alarms) {
      final p = s7.parseS7Address(a.address);
      if (p != null) {
        wanted.add((p, a.id, false));
      } else {
        unparsed++;
      }
    }
    if (wanted.isEmpty) {
      // 一条有效地址都没有：给出明确诊断，界面不再停在「读取报警中…」
      s.alarmSegTotal = 0;
      s.alarmSegFailed = 1;
      s.alarmFailDesc = unparsed > 0
          ? '${d.alarms.length} 条报警地址全部无法解析，请检查报警表格式'
          : '无有效报警地址';
      return;
    }

    // 按 (db, area) 分组
    final groups = <String, List<(s7.S7Point, int, bool)>>{};
    for (final w in wanted) {
      groups.putIfAbsent('${w.$1.db}/${w.$1.area}', () => []).add(w);
    }

    int segTotal = 0, segFailed = 0;
    final failedDesc = <String>[];
    final lampVals = <int, bool>{}; // 状态灯本轮读数（key: -1红/-2黄/-3绿）
    for (final items in groups.values) {
      items.sort((x, y) => x.$1.byteIndex.compareTo(y.$1.byteIndex));
      // 合并连续字节段：间隔 ≤ 4 字节算连续，每段最多 120 字节
      int i = 0;
      while (i < items.length) {
        int j = i;
        while (j + 1 < items.length &&
            items[j + 1].$1.byteIndex - items[i].$1.byteIndex <= 120 &&
            items[j + 1].$1.byteIndex - items[j].$1.byteIndex <= 4) {
          j++;
        }
        final run = items.sublist(i, j + 1);
        final startByte = run.first.$1.byteIndex;
        final count = run.last.$1.byteIndex - startByte + 1;
        final sp = run.first.$1;
        final blockStart = s7.S7Point(sp.area, sp.db, startByte, 0);
        final segKey = '${d.id}/${sp.db}/${sp.area}/$startByte';
        segTotal++;
        // 拉黑过的段不再通讯；其他段照常读
        if (_alarmFailCnt[segKey] != null && _alarmFailCnt[segKey]! >= 3) {
          segFailed++;
          failedDesc.add(_segDesc(sp));
          i = j + 1;
          continue;
        }
        try {
          final bytes =
              await (c as s7.S7Client).readBytes(blockStart, count);
          _alarmFailCnt.remove(segKey);
          for (final (p, key, isLamp) in run) {
            final b = bytes[p.byteIndex - startByte];
            final v = decodeBit([b], p.bitIndex);
            if (isLamp) {
              lampVals[key] = v;
            } else {
              s.alarmRaw[key] = v;
            }
          }
        } catch (_) {
          // 连续 3 次失败（如 DB 块不存在 / 地址超界）拉黑该段，不再通讯
          _alarmFailCnt[segKey] = (_alarmFailCnt[segKey] ?? 0) + 1;
          segFailed++;
          if (failedDesc.length < 4) failedDesc.add(_segDesc(sp));
        }
        i = j + 1;
      }
    }
    // 诊断结果交给界面：全部段都读不到时报警行给出明确原因
    s.alarmSegTotal = segTotal;
    s.alarmSegFailed = segFailed;
    s.alarmFailDesc = failedDesc.toSet().take(3).join('、');
    // 状态灯颜色：红灯优先，其次黄、绿；都没亮或没读到为灰
    s.lampColor = lampVals[-1] == true
        ? 'red'
        : (lampVals[-2] == true
            ? 'yellow'
            : (lampVals[-3] == true ? 'green' : 'gray'));
  }

  /// 段位置的人类可读描述（如 DB91 / M 区）
  String _segDesc(s7.S7Point p) =>
      p.area == 0x84 ? 'DB${p.db}' : (p.area == 0x83 ? 'M 区' : '区${p.area}');

  // ------------------------------------------------------------ 写位

  Future<bool> writeBit(Device d, PointItem p, bool value) async {
    // 双保险：界面上已经不会给 I / Q 点提供写入入口，这里再挡一次
    if (isForcedReadOnlyAddress(p.address)) {
      st(d.id).writeError = '「${p.name}」在 I / Q 区（${p.address}），只读，不允许写入';
      _notify(d.id);
      return false;
    }
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

  /// 按原始地址写位（十字按钮四脚等非点位地址的写入）。[label] 用于报错提示。
  Future<bool> writeBitAt(Device d, String address, bool value,
      {String label = ''}) async {
    final who = label.isEmpty ? address : '「$label」($address)';
    // I / Q 区只读双保险
    if (isForcedReadOnlyAddress(address)) {
      st(d.id).writeError = '$who 在 I / Q 区，只读，不允许写入';
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
      bool ok;
      if (_isModbus(d)) {
        final mp = mb.parseModbusAddress(address);
        if (mp == null || mp.isInput) {
          st(d.id).writeError = '地址「$address」不可写（输入点不能写）';
          _notify(d.id);
          return false;
        }
        ok = await (c as mb.ModbusTcpClient).writeBit(mp.addr, value);
      } else {
        final sp = s7.parseS7Address(address);
        if (sp == null) {
          st(d.id).writeError = '地址「$address」无法解析';
          _notify(d.id);
          return false;
        }
        ok = await (c as s7.S7Client).writeBit(sp, value);
      }
      st(d.id).writeError = ok ? null : '写入 $address 失败';
      _notify(d.id);
      return ok;
    } catch (e) {
      st(d.id).writeError = _describe(e);
      _notify(d.id);
      return false;
    }
  }

  /// 写入任意类型的值：BOOL 走位写，数值类型走字节写
  Future<bool> writeValue(Device d, PointItem p, Object value) async {
    if (isForcedReadOnlyAddress(p.address)) {
      st(d.id).writeError = '「${p.name}」在 I / Q 区（${p.address}），只读，不允许写入';
      _notify(d.id);
      return false;
    }
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
