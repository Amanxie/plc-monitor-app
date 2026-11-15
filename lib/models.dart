/// 点位与设备模型
library models;

import 'dart:typed_data';

/// 点位类型
enum PointType { input, output, image }

/// 变量数据类型（西门子标准命名）
///
/// int16 对应西门子 INT（16 位有符号）
/// dint 对应 DINT（32 位有符号）
enum VarType { boolean, byte, word, dword, int16, dint, real, lreal }

extension VarTypeInfo on VarType {
  /// 界面上显示的西门子类型名
  String get label => switch (this) {
        VarType.boolean => 'BOOL',
        VarType.byte => 'BYTE',
        VarType.word => 'WORD',
        VarType.dword => 'DWORD',
        VarType.int16 => 'INT',
        VarType.dint => 'DINT',
        VarType.real => 'REAL',
        VarType.lreal => 'LREAL',
      };

  /// 占用字节数（BOOL 按 1 字节读取后取位）
  int get byteSize => switch (this) {
        VarType.boolean => 1,
        VarType.byte => 1,
        VarType.word => 2,
        VarType.dword => 4,
        VarType.int16 => 2,
        VarType.dint => 4,
        VarType.real => 4,
        VarType.lreal => 8,
      };

  bool get isBit => this == VarType.boolean;
  bool get isFloat => this == VarType.real || this == VarType.lreal;
  bool get isSigned => this == VarType.int16 || this == VarType.dint;
  bool get isNumeric => this != VarType.boolean;

  /// 从 PLC 返回的原始字节（S7 为大端）解码为 Dart 值
  ///
  /// 字节不足时按 0 补齐：PLC 若只回了部分数据（某些固件的 REAL 长度字段写法不同），
  /// 宁可显示偏差值也不要抛异常把整轮轮询打断。
  Object decode(List<int> b) {
    int at(int i) => i < b.length ? (b[i] & 0xFF) : 0;
    switch (this) {
      case VarType.boolean:
        return (at(0) & 0x01) == 1;
      case VarType.byte:
        return at(0);
      case VarType.word:
        return (at(0) << 8) | at(1);
      case VarType.int16:
        final v = (at(0) << 8) | at(1);
        return v >= 0x8000 ? v - 0x10000 : v;
      case VarType.dword:
        return (at(0) << 24) | (at(1) << 16) | (at(2) << 8) | at(3);
      case VarType.dint:
        final v = (at(0) << 24) | (at(1) << 16) | (at(2) << 8) | at(3);
        return v >= 0x80000000 ? v - 0x100000000 : v;
      case VarType.real:
        final buf = Uint8List.fromList([at(0), at(1), at(2), at(3)]);
        return ByteData.sublistView(buf).getFloat32(0, Endian.big);
      case VarType.lreal:
        final buf = Uint8List.fromList(
            [at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7)]);
        return ByteData.sublistView(buf).getFloat64(0, Endian.big);
    }
  }

  /// 是否可写入（BOOL 按位写，数值按字节写）
  bool get writable => true;

  /// 数值下限（用于写入前校验）
  num get minValue => switch (this) {
        VarType.boolean => 0,
        VarType.byte || VarType.word || VarType.dword => 0,
        VarType.int16 => -32768,
        VarType.dint => -2147483648,
        VarType.real => -3.4028234663852886e38,
        VarType.lreal => -1.7976931348623157e308,
      };

  /// 数值上限（用于写入前校验）
  num get maxValue => switch (this) {
        VarType.boolean => 1,
        VarType.byte => 255,
        VarType.word => 65535,
        VarType.dword => 4294967295,
        VarType.int16 => 32767,
        VarType.dint => 2147483647,
        VarType.real => 3.4028234663852886e38,
        VarType.lreal => 1.7976931348623157e308,
      };

  bool inRange(num v) => v >= minValue && v <= maxValue;

  /// 把要写入的值编码成 S7 大端字节（BOOL 走位写，这里按 0/1 编码单字节备用）
  Uint8List encodeNum(num v) {
    final bd = ByteData(byteSize);
    switch (this) {
      case VarType.boolean:
        bd.setUint8(0, v == 0 ? 0 : 1);
      case VarType.byte:
        bd.setUint8(0, v.toInt() & 0xFF);
      case VarType.word:
        bd.setUint16(0, v.toInt() & 0xFFFF, Endian.big);
      case VarType.int16:
        bd.setInt16(0, v.toInt(), Endian.big);
      case VarType.dword:
        bd.setUint32(0, v.toInt() & 0xFFFFFFFF, Endian.big);
      case VarType.dint:
        bd.setInt32(0, v.toInt(), Endian.big);
      case VarType.real:
        bd.setFloat32(0, v.toDouble(), Endian.big);
      case VarType.lreal:
        bd.setFloat64(0, v.toDouble(), Endian.big);
    }
    return bd.buffer.asUint8List();
  }

  /// 把用户输入的文本解析成本类型的值；返回 null 表示格式不对或超范围
  num? parseNum(String text) {
    final t = text.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    if (isFloat) {
      final v = double.tryParse(t);
      return (v != null && inRange(v)) ? v : null;
    }
    final v = int.tryParse(t);
    if (v == null) return null;
    return inRange(v) ? v : null;
  }
}

/// 位解码：S7 按位读回的是「包含该位的那一整个字节」，位在原位置。
/// 例：读 M30.3，回 0x08 → 为 1；回 0x00 → 为 0。
/// 少数网关会把结果归一到最低位（回 0x01 表示 ON），两种都兼容。
bool decodeBit(List<int> b, int bitIndex) {
  final v = b.isEmpty ? 0 : (b[0] & 0xFF);
  if (((v >> (bitIndex & 7)) & 1) == 1) return true;
  return v == 0x01;
}

/// 把监控到的值格式化成界面文本
///
/// 浮点数的坑（v1.2 之前这里有 bug）：
///   · `toStringAsFixed(3)` 会把 1.2e-5 显示成 0.000、把 12.3456789 截成 12.346
///   · REAL 实际只有 7 位有效数字，float32 → double 会带出 3.140000104904175 这种尾巴
/// 现在按「有效数字」格式化：REAL 7 位、LREAL 15 位，再清尾零。
String formatVarValue(VarType t, Object? v) {
  if (v == null) return '--';
  if (v is bool) return v ? 'ON' : 'OFF';
  if (v is double) return formatFloat(v, t == VarType.lreal ? 15 : 7);
  if (v is num) return v.toString();
  return v.toString();
}

/// 按有效数字格式化浮点（自动在过大/过小时切科学计数法）
String formatFloat(double v, int sig) {
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v.isNegative ? '-∞' : '∞';
  if (v == 0) return '0';
  final a = v.abs();

  // 超出有效数字量级 → 科学计数法（如 1.234568e+12 / 1.5e-7）
  final exp = (a >= 1e9) || (a < 1e-6);
  String s = exp ? v.toStringAsExponential(sig - 1) : v.toStringAsPrecision(sig);

  // 统一处理尾零："3.140000" → "3.14"，"100.0000" → "100"
  final eIdx = s.indexOf(RegExp('[eE]'));
  final mant = eIdx >= 0 ? s.substring(0, eIdx) : s;
  final tail = eIdx >= 0 ? s.substring(eIdx) : '';
  var m = mant;
  if (m.contains('.')) {
    m = m.replaceFirst(RegExp(r'0+$'), '');
    if (m.endsWith('.')) m = m.substring(0, m.length - 1);
  }
  if (m == '-0') m = '0';
  // 科学计数法尾巴统一成 e+7 / e-7（去掉 Dart 的 e+7 前导 0 差异）
  if (tail.isEmpty) return m;
  final t = tail.replaceFirst(RegExp(r'[eE]'), 'e');
  return m + t;
}

/// 点位（模板里的一个信号/按钮）
///
/// 控件按「用户能不能操作」分三种：
///   · 状态显示：type=input + writable=false —— 只显示，不给操作
///   · 输入域： type=input + writable=true  —— 用户可写 0/1 或数值
///   · 点动按钮：type=output                —— 按下置 1、松开置 0
class PointItem {
  String id;
  String name;      // 显示名：如 一层到位
  String address;   // 原始地址：I0.0 / Q0.1 / M10.0 / MW10 / DB1.DBX0.0
  PointType type;   // 输入（状态/输入域） / 输出（点动按钮）
  VarType dataType; // 变量数据类型
  bool visible;
  /// 是否允许用户操作：false = 状态显示（只读），true = 输入域（可写）
  bool writable;
  /// 变量注释（对应博图变量表里的注释列）。留空时自动取符号表里同地址的注释。
  String comment;

  PointItem({
    required this.id,
    required this.name,
    required this.address,
    required this.type,
    this.dataType = VarType.boolean,
    this.visible = true,
    this.writable = true,
    this.comment = '',
  });

  bool get isOutput => type == PointType.output;

  /// 状态显示（只读，不可操作）
  bool get isStatusOnly => type == PointType.input && !writable;

  /// 输入域（用户可写）
  bool get isInputField => type == PointType.input && writable;

  /// 控件角色名，界面与编辑弹窗共用
  String get roleLabel => isOutput ? '点动按钮' : (writable ? '输入域' : '状态显示');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'type': type.name,
        'dataType': dataType.name,
        'visible': visible,
        'writable': writable,
        'comment': comment,
      };

  factory PointItem.fromJson(Map<String, dynamic> j) => PointItem(
        id: j['id'] as String,
        name: j['name'] as String,
        address: j['address'] as String,
        type: PointType.values.byName(j['type'] as String),
        // 旧版本存档没有 dataType 字段，按 BOOL 处理
        dataType: VarType.values.firstWhere(
          (e) => e.name == (j['dataType'] as String?),
          orElse: () => VarType.boolean,
        ),
        visible: (j['visible'] as bool?) ?? true,
        // 旧存档默认按「输入域」处理，保持 1.7.x 的既有行为不变
        writable: (j['writable'] as bool?) ?? true,
        comment: (j['comment'] as String?) ?? '',
      );
}

/// 模板（界面布局 + 点位集合）
class Template {
  String id;
  String name;
  String desc;
  List<PointItem> points;
  String? imagePath; // 背景图片本地路径

  Template({
    required this.id,
    required this.name,
    required this.desc,
    required this.points,
    this.imagePath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'desc': desc,
        'points': points.map((p) => p.toJson()).toList(),
        'imagePath': imagePath,
      };

  factory Template.fromJson(Map<String, dynamic> j) => Template(
        id: j['id'] as String,
        name: j['name'] as String,
        desc: (j['desc'] as String?) ?? '',
        points: (j['points'] as List)
            .map((e) => PointItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        imagePath: j['imagePath'] as String?,
      );
}

/// 协议类型
enum Protocol { s7, opcua, modbusTcp, plcsim }

/// 设备配置
class Device {
  String id;
  String name;
  String templateId;
  String plcType;      // S7-1200 / S7-1500 / S7-300 / 其他
  Protocol protocol;
  String ip;
  int port;            // S7 ISO-on-TCP 端口，默认 102
  int rack;
  int slot;
  Map<String, String> addresses; // pointId -> 地址（设备可覆盖模板地址）

  Device({
    required this.id,
    required this.name,
    required this.templateId,
    this.plcType = 'S7-1200',
    this.protocol = Protocol.s7,
    this.ip = '192.168.0.1',
    this.port = 102,
    this.rack = 0,
    this.slot = 1,
    Map<String, String>? addresses,
  }) : addresses = addresses ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'templateId': templateId,
        'plcType': plcType,
        'protocol': protocol.name,
        'ip': ip,
        'port': port,
        'rack': rack,
        'slot': slot,
        'addresses': addresses,
      };

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'] as String,
        name: j['name'] as String,
        templateId: j['templateId'] as String,
        plcType: (j['plcType'] as String?) ?? 'S7-1200',
        protocol: Protocol.values.byName((j['protocol'] as String?) ?? 's7'),
        ip: (j['ip'] as String?) ?? '192.168.0.1',
        port: (j['port'] as int?) ?? 102,
        rack: (j['rack'] as int?) ?? 0,
        slot: (j['slot'] as int?) ?? 1,
        addresses: ((j['addresses'] as Map?) ?? {})
            .map((k, v) => MapEntry(k as String, v as String)),
      );
}

/// 内置模板
final builtinTemplates = <Template>[
  Template(
    id: 'tpl_lift',
    name: '升降机',
    desc: '6 点位 · 2 层站 · 上升/下降点动',
    points: [
      PointItem(id: 'p1', name: '一层到位', address: 'I0.0', type: PointType.input),
      PointItem(id: 'p2', name: '二层到位', address: 'I0.1', type: PointType.input),
      PointItem(id: 'p3', name: '上升极限', address: 'I0.2', type: PointType.input),
      PointItem(id: 'p4', name: '下降极限', address: 'I0.3', type: PointType.input),
      PointItem(id: 'p5', name: '上升按钮', address: 'Q0.0', type: PointType.output),
      PointItem(id: 'p6', name: '下降按钮', address: 'Q0.1', type: PointType.output),
    ],
  ),
  Template(
    id: 'tpl_lift_transfer',
    name: '顶升移载',
    desc: '8 点位 · 横向/纵向 正反转点动',
    points: [
      PointItem(id: 'p1', name: '到位信号', address: 'I0.0', type: PointType.input),
      PointItem(id: 'p2', name: '减速信号', address: 'I0.1', type: PointType.input),
      PointItem(id: 'p3', name: '上升到位', address: 'I0.2', type: PointType.input),
      PointItem(id: 'p4', name: '下降到位', address: 'I0.3', type: PointType.input),
      PointItem(id: 'p5', name: '横向正转', address: 'Q0.0', type: PointType.output),
      PointItem(id: 'p6', name: '横向反转', address: 'Q0.1', type: PointType.output),
      PointItem(id: 'p7', name: '纵向正转', address: 'Q0.2', type: PointType.output),
      PointItem(id: 'p8', name: '纵向反转', address: 'Q0.3', type: PointType.output),
    ],
  ),
];
