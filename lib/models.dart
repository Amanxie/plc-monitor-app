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

/// 地址是否落在 I 区 / Q 区（过程映像输入 / 输出）
///
/// 这两区的值由 PLC 扫描周期和用户程序决定，App 直接写入会绕过梯形图里的互锁，
/// 现场太危险 —— 所以统一按只读处理，只能做状态显示。
/// M 区、DB 区不受限制。
bool isForcedReadOnlyAddress(String raw) {
  var s = raw.trim().toUpperCase().replaceAll(' ', '').replaceAll('\t', '');
  if (s.startsWith('%')) s = s.substring(1);
  return RegExp(r'^[IQ][BWD]?\d+(\.\d+)?$').hasMatch(s);
}

/// 地址归属区（I / Q / M / DB），认不出来返回 '?'
String addrAreaOf(String raw) {
  var s = raw.trim().toUpperCase().replaceAll(' ', '');
  if (s.startsWith('%')) s = s.substring(1);
  if (s.startsWith('DB')) return 'DB';
  if (s.startsWith('I')) return 'I';
  if (s.startsWith('Q')) return 'Q';
  if (s.startsWith('M')) return 'M';
  return '?';
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

/// 点位（模板 / 案例里的一个信号或按钮）
///
/// 控件按「用户能不能操作」分三种：
///   · 状态显示：只显示实时值，监控页不提供操作
///   · 输入域： 用户可写 0/1 或数值（仅限 M 区 / DB 区）
///   · 点动按钮：按下置 1、松开置 0（仅限 M 区 / DB 区，BOOL）
///
/// 硬规则：地址落在 I 区 / Q 区的点位一律按状态显示处理，
/// [writable] 和 [type] 上的历史设置会被 [enforceReadOnlyRule] 纠正。
class PointItem {
  String id;
  String name;      // 显示名：如 一层到位
  String address;   // 原始地址：I0.0 / Q0.1 / M10.0 / MW10 / DB1.DBX0.0
  PointType type;   // 输入（状态/输入域） / 输出（点动按钮）
  VarType dataType; // 变量数据类型
  bool visible;
  /// 是否允许用户操作：false = 状态显示（只读），true = 输入域/点动按钮
  bool writable;
  /// 变量注释（对应博图变量表里的注释列）。留空时自动取符号表里同地址的注释。
  String comment;

  /// 变量组（对点模板从 CSV B 列导入）：监控页按下拉框分组过滤显示
  String group;

  /// 控件种类：'' = 按性质自动（状态显示/输入域/点动按钮），'cross' = 十字按钮
  String ctrl;
  /// 十字按钮四脚地址（前/后/左/右），仅 ctrl == 'cross' 时使用
  Map<String, String> dirs;

  /// 监控操作区域里的位置与尺寸（设计坐标，画布宽 360）。
  /// x/y < 0 表示未定位（迁移时自动排布）；w/h <= 0 表示用默认尺寸。
  double x, y, w, h;

  PointItem({
    required this.id,
    required this.name,
    required this.address,
    required this.type,
    this.dataType = VarType.boolean,
    this.visible = true,
    this.writable = true,
    this.comment = '',
    this.group = '',
    this.ctrl = '',
    Map<String, String>? dirs,
    this.x = -1,
    this.y = -1,
    this.w = 0,
    this.h = 0,
  }) : dirs = dirs ?? {};

  bool get isCross => ctrl == 'cross';

  /// 地址在 I / Q 区 —— 只读，写不了
  bool get ioLocked => isForcedReadOnlyAddress(address);

  /// 声明的可写属性是否真的生效（I/Q 区一律不算）
  bool get canWrite => writable && !ioLocked;

  /// 点动按钮：输出属性 + BOOL + 地址不在 I/Q 区
  bool get isJogButton => type == PointType.output && !ioLocked;

  /// 状态显示（只读，不可操作）
  bool get isStatusOnly => !isJogButton && !canWrite;

  /// 输入域（用户可写）
  bool get isInputField =>
      type == PointType.input && writable && !ioLocked;

  /// 控件角色名，界面与编辑弹窗共用
  String get roleLabel =>
      isJogButton ? '点动按钮' : (canWrite ? '输入域' : '状态显示');

  /// 按「I/Q 只读」规则纠正控件性质，返回 true 表示确实改动了
  bool enforceReadOnlyRule() {
    if (!ioLocked) return false;
    final changed = type != PointType.input || writable;
    type = PointType.input;
    writable = false;
    return changed;
  }

  PointItem clone({String? id}) => PointItem(
        id: id ?? this.id,
        name: name,
        address: address,
        type: type,
        dataType: dataType,
        visible: visible,
        writable: writable,
        comment: comment,
        group: group,
        ctrl: ctrl,
        dirs: Map.of(dirs),
        x: x, y: y, w: w, h: h,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'type': type.name,
        'dataType': dataType.name,
        'visible': visible,
        'writable': writable,
        'comment': comment,
        if (group.isNotEmpty) 'group': group,
        if (ctrl.isNotEmpty) 'ctrl': ctrl,
        if (dirs.isNotEmpty) 'dirs': dirs,
        'x': x, 'y': y, 'w': w, 'h': h,
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
        group: (j['group'] as String?) ?? '',
        ctrl: (j['ctrl'] as String?) ?? '',
        dirs: ((j['dirs'] as Map?) ?? {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
        x: (j['x'] as num?)?.toDouble() ?? -1,
        y: (j['y'] as num?)?.toDouble() ?? -1,
        w: (j['w'] as num?)?.toDouble() ?? 0,
        h: (j['h'] as num?)?.toDouble() ?? 0,
      );
}

/// 报警定义（案例自己的报警表，对应「报警记录」Excel 的 A~F 列）
///
/// 列含义：
///   A 报警ID / B 优先级（0 排最上面）/ C 读取区域（DB91Bit、DB90Bit、MW）/
///   D 绝对地址（最后一位是位地址，前面是字地址，如 3150 → 315.0）/
///   E 触发数值（1=值为 1 报警，0=值为 0 报警）/ F 报警内容（≤50 字）
class AlarmItem {
  int id;
  int priority;
  String address;    // 解析后的绝对地址：DB91.DBX3.0 / M186.6
  bool triggerHigh;  // true = 值为 1 报警；false = 值为 0 报警
  String text;

  AlarmItem({
    required this.id,
    required this.priority,
    required this.address,
    required this.triggerHigh,
    required this.text,
  });

  AlarmItem clone() => AlarmItem(
        id: id, priority: priority, address: address,
        triggerHigh: triggerHigh, text: text,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'priority': priority,
        'address': address,
        'triggerHigh': triggerHigh,
        'text': text,
      };

  factory AlarmItem.fromJson(Map<String, dynamic> j) => AlarmItem(
        id: (j['id'] as num?)?.toInt() ?? 0,
        priority: (j['priority'] as num?)?.toInt() ?? 0,
        address: (j['address'] as String?) ?? '',
        triggerHigh: (j['triggerHigh'] as bool?) ?? true,
        text: (j['text'] as String?) ?? '',
      );
}

/// 解析从 Excel 复制粘贴过来的报警表（制表符分隔 A~F 列，每行一条，可含表头）
///
/// 返回 (报警列表, 被丢弃行的错误说明)。解析规则：
///   · C 列「DB91Bit」→ DB91 区；「DB90Bit」→ DB90 区；「MW」→ M 区
///   · D 列绝对地址：末位是位地址、前面是字地址（3150 → 315.0，30 → 3.0）
///   · E 列触发数值：1 → 值为 1 报警；0 → 值为 0 报警
(List<AlarmItem>, List<String>) parseAlarmTable(String raw) {
  final alarms = <AlarmItem>[];
  final errors = <String>[];
  final lines = raw.replaceAll('\r', '').split('\n');
  for (int ln = 0; ln < lines.length; ln++) {
    final line = lines[ln].trim();
    if (line.isEmpty) continue;
    // Excel 粘贴是制表符分隔；兼容 2 个以上空格分隔
    var cols = line.split('\t').map((e) => e.trim()).toList();
    if (cols.length < 6) {
      final alt = line.split(RegExp(r'\s{2,}')).map((e) => e.trim()).toList();
      if (alt.length >= 6) cols = alt;
    }
    if (cols.length < 6) {
      // Excel「另存为 CSV」是逗号分隔：只切前 5 个逗号，第 6 段整段作为内容，
      // 这样报警内容里自带逗号也不会被截断
      final parts = line.split(',');
      if (parts.length >= 6) {
        cols = [
          ...parts.take(5).map((e) => e.trim()),
          parts.skip(5).join(',').trim(),
        ];
      }
    }
    if (cols.length < 6) {
      errors.add('第${ln + 1}行：列数不足（需要 6 列：ID/优先级/区域/地址/触发值/内容）');
      continue;
    }
    final id = num.tryParse(cols[0])?.toInt();
    if (id == null) continue; // 表头行 / 干扰行静默跳过
    final priority = num.tryParse(cols[1])?.toInt() ?? 0;
    final areaRaw = cols[2].trim().toUpperCase().replaceAll(' ', '');
    final addrRaw = num.tryParse(cols[3])?.toInt();
    if (addrRaw == null || addrRaw < 0) {
      errors.add('第${ln + 1}行：绝对地址「${cols[3]}」不是数字');
      continue;
    }
    // D 列：末位是位地址，前面是字地址
    final word = addrRaw ~/ 10;
    final bit = addrRaw % 10;
    if (bit > 7) {
      errors.add('第${ln + 1}行：地址 $addrRaw 的位号 $bit 超出 0~7');
      continue;
    }
    final trig = num.tryParse(cols[4])?.toInt();
    if (trig == null || (trig != 0 && trig != 1)) {
      errors.add('第${ln + 1}行：触发数值「${cols[4]}」只能是 0 或 1');
      continue;
    }
    // C 列：DB 区（DB91Bit / DB91）→ DB91.DBX{word}.{bit}；MW → M{word}.{bit}
    String address;
    final dbMatch = RegExp(r'^DB(\d+)(BIT)?$').firstMatch(areaRaw);
    if (dbMatch != null) {
      address = 'DB${dbMatch.group(1)}.DBX$word.$bit';
    } else if (areaRaw == 'MW' || areaRaw == 'M') {
      address = 'M$word.$bit';
    } else {
      errors.add('第${ln + 1}行：区域「${cols[2]}」认不出来，只支持 DBxxBit / MW');
      continue;
    }
    // F 列：报警内容，限 50 字
    final text = cols.sublist(5).join(' ').trim();
    if (text.isEmpty) {
      errors.add('第${ln + 1}行：报警内容为空');
      continue;
    }
    alarms.add(AlarmItem(
      id: id,
      priority: priority,
      address: address,
      triggerHigh: trig == 1,
      text: text.length > 50 ? text.substring(0, 50) : text,
    ));
  }
  return (alarms, errors);
}

/// 模板（界面布局 + 点位集合）
class Template {
  String id;
  String name;
  String desc;
  List<PointItem> points;
  String? imagePath; // 背景图片本地路径
  /// 对点模板（需求 28）：点位从 CSV 批量导入，监控页按变量组列表核对，
  /// 不走画布布局；通讯只读当前可见区域
  bool check;

  Template({
    required this.id,
    required this.name,
    required this.desc,
    required this.points,
    this.imagePath,
    this.check = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'desc': desc,
        'points': points.map((p) => p.toJson()).toList(),
        'imagePath': imagePath,
        if (check) 'check': true,
      };

  factory Template.fromJson(Map<String, dynamic> j) => Template(
        id: j['id'] as String,
        name: j['name'] as String,
        desc: (j['desc'] as String?) ?? '',
        points: (j['points'] as List)
            .map((e) => PointItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        imagePath: j['imagePath'] as String?,
        check: (j['check'] as bool?) ?? false,
      );
}

/// 协议类型
enum Protocol { s7, opcua, modbusTcp, plcsim }

/// 设备配置（一个「案例」）
///
/// 点位是**设备自己的副本**：新建案例时从模板深拷贝一份，之后互不相干。
/// · 改模板不会动已建案例
/// · 删模板不会影响已建案例（[templateId] 只是来源记录）
/// · 改案例的点位也不会动模板
class Device {
  String id;
  String name;
  String templateId;      // 来源模板 id（模板删了也不影响本案例）
  String sourceTemplate;  // 来源模板名，仅用于界面展示
  String plcType;      // S7-1200 / S7-1500 / S7-300 / 其他
  Protocol protocol;
  String ip;
  int port;            // S7 ISO-on-TCP 端口，默认 102
  int rack;
  int slot;
  /// 案例自己的点位（含名称、地址、类型、控件性质）
  List<PointItem> points;
  /// 案例自己的报警表（从报警记录表导入，随案例保存）
  List<AlarmItem> alarms;
  /// 状态灯三色地址（BOOL，值为 1 该颜色亮；都为 0 或未配置为灰）。
  /// 旧版 alarmLamp（1红/0绿）迁移到红灯地址。
  String lampRed = '';
  String lampYellow = '';
  String lampGreen = '';
  /// 1.9.0 之前的报警灯地址，迁移用
  String alarmLamp = '';
  /// 案例自己的背景图（从模板带过来，之后独立）
  String? imagePath;

  /// 对点案例（需求 28）：从对点模板创建，监控页走变量组列表核对模式
  bool check = false;

  /// 状态显示控件被点击后「名称 ⇄ 地址」的切换记忆（需求 33）：
  /// 存被切换成地址显示的点位 id，退出页面 / 重启 App 都保持
  List<String> addrLabels = [];

  /// 状态灯的有效地址列表（非空地址 → 颜色名）
  List<(String, String)> get lampAddrs => [
        if (lampRed.trim().isNotEmpty) (lampRed.trim(), 'red'),
        if (lampYellow.trim().isNotEmpty) (lampYellow.trim(), 'yellow'),
        if (lampGreen.trim().isNotEmpty) (lampGreen.trim(), 'green'),
      ];

  /// 1.8.2 及更早版本的「设备地址覆盖表」，只在迁移时用一次
  Map<String, String> legacyAddresses = {};

  Device({
    required this.id,
    required this.name,
    required this.templateId,
    this.sourceTemplate = '',
    this.plcType = 'S7-1200',
    this.protocol = Protocol.s7,
    this.ip = '192.168.0.1',
    this.port = 102,
    this.rack = 0,
    this.slot = 1,
    List<PointItem>? points,
    List<AlarmItem>? alarms,
    this.lampRed = '',
    this.lampYellow = '',
    this.lampGreen = '',
    this.alarmLamp = '',
    this.imagePath,
  }) : points = points ?? [],
       alarms = alarms ?? [] {
    // 旧签名 alarmLamp（1红/0绿）：自动迁移为状态灯红灯地址
    if (lampRed.isEmpty && alarmLamp.trim().isNotEmpty) {
      lampRed = alarmLamp.trim();
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'templateId': templateId,
        'sourceTemplate': sourceTemplate,
        'plcType': plcType,
        'protocol': protocol.name,
        'ip': ip,
        'port': port,
        'rack': rack,
        'slot': slot,
        'points': points.map((p) => p.toJson()).toList(),
        'alarms': alarms.map((a) => a.toJson()).toList(),
        'lampRed': lampRed,
        'lampYellow': lampYellow,
        'lampGreen': lampGreen,
        if (check) 'check': true,
        if (addrLabels.isNotEmpty) 'addrLabels': addrLabels,
        'imagePath': imagePath,
      };

  factory Device.fromJson(Map<String, dynamic> j) =>
      _migrateLamp(Device(
      id: j['id'] as String,
      name: j['name'] as String,
      templateId: (j['templateId'] as String?) ?? '',
      sourceTemplate: (j['sourceTemplate'] as String?) ?? '',
      plcType: (j['plcType'] as String?) ?? 'S7-1200',
      protocol: Protocol.values.byName((j['protocol'] as String?) ?? 's7'),
      ip: (j['ip'] as String?) ?? '192.168.0.1',
      port: (j['port'] as int?) ?? 102,
      rack: (j['rack'] as int?) ?? 0,
      slot: (j['slot'] as int?) ?? 1,
      // 1.8.3 之前没有 points 字段，靠 store 里的迁移从模板补齐
      points: (j['points'] as List?)
          ?.map((e) => PointItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      alarms: (j['alarms'] as List?)
          ?.map((e) => AlarmItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      lampRed: (j['lampRed'] as String?) ?? '',
      lampYellow: (j['lampYellow'] as String?) ?? '',
      lampGreen: (j['lampGreen'] as String?) ?? '',
      // 旧版只有 alarmLamp（1红/0绿）：迁移为红灯地址，语义一致
      alarmLamp: (j['alarmLamp'] as String?) ?? '',
      imagePath: j['imagePath'] as String?,
    )..legacyAddresses = ((j['addresses'] as Map?) ?? {})
        .map((k, v) => MapEntry(k.toString(), v.toString())))
      ..check = (j['check'] as bool?) ?? false
      ..addrLabels = ((j['addrLabels'] as List?) ?? const [])
          .map((e) => e.toString()).toList();
}

/// Device 后处理：旧版报警灯地址迁移为状态灯红灯（保持「该地址为 1 亮红」语义）
Device _migrateLamp(Device d) {
  if (d.lampRed.isEmpty && d.alarmLamp.trim().isNotEmpty) {
    d.lampRed = d.alarmLamp.trim();
  }
  return d;
}

// ---------------- 监控操作区域画布（需求 23） ----------------

/// 画布设计宽度。控件 x/y/w/h 都在这个坐标系里；实际渲染按屏宽等比缩放。
const double kCanvasW = 360;

/// 控件默认尺寸（设计坐标）。w/h <= 0 时用它。
(double, double) defaultCtrlSize(PointItem p) {
  if (p.isCross) return (150, 150);
  if (p.isJogButton) return (170, 52);
  return (170, 60);
}

/// 画布总高度：所有控件的最大底边 + 边距
double canvasHeight(List<PointItem> points) {
  double bottom = 0;
  for (final p in points) {
    if (p.type == PointType.image) continue;
    bottom = bottom > p.y + p.h ? bottom : p.y + p.h;
  }
  return bottom <= 0 ? 120 : bottom + 10;
}

/// 给未定位的控件自动排布（单列纵排），尺寸 0 的补默认值。
/// 老存档迁移与画布编辑器进入时都会调用。
void normalizeLayout(List<PointItem> points) {
  double y = 10;
  for (final p in points) {
    if (p.type == PointType.image) continue;
    final (dw, dh) = defaultCtrlSize(p);
    if (p.w <= 0) p.w = dw;
    if (p.h <= 0) p.h = dh;
    if (p.x < 0 || p.y < 0) {
      p.x = 10;
      p.y = y;
    }
    y = p.y + p.h + 8;
  }
}

/// 内置模板
///
/// 注意：Q 区是过程映像输出，App 不允许写入，所以这里的输出点全部是状态显示。
/// 现场要点动，请在案例里新增控件并把地址填到 M 区（M0.0…），由 PLC 程序去驱动 Q。
final builtinTemplates = <Template>[
  Template(
    id: 'tpl_lift',
    name: '升降机',
    desc: '6 点位 · 2 层站 · 4 输入 + 2 输出反馈',
    points: [
      PointItem(id: 'p1', name: '一层到位', address: 'I0.0', type: PointType.input, writable: false),
      PointItem(id: 'p2', name: '二层到位', address: 'I0.1', type: PointType.input, writable: false),
      PointItem(id: 'p3', name: '上升极限', address: 'I0.2', type: PointType.input, writable: false),
      PointItem(id: 'p4', name: '下降极限', address: 'I0.3', type: PointType.input, writable: false),
      PointItem(id: 'p5', name: '上升输出', address: 'Q0.0', type: PointType.input, writable: false),
      PointItem(id: 'p6', name: '下降输出', address: 'Q0.1', type: PointType.input, writable: false),
    ],
  ),
  Template(
    id: 'tpl_lift_transfer',
    name: '顶升移载',
    desc: '8 点位 · 横向/纵向 · 4 输入 + 4 输出反馈',
    points: [
      PointItem(id: 'p1', name: '到位信号', address: 'I0.0', type: PointType.input, writable: false),
      PointItem(id: 'p2', name: '减速信号', address: 'I0.1', type: PointType.input, writable: false),
      PointItem(id: 'p3', name: '上升到位', address: 'I0.2', type: PointType.input, writable: false),
      PointItem(id: 'p4', name: '下降到位', address: 'I0.3', type: PointType.input, writable: false),
      PointItem(id: 'p5', name: '横向正转输出', address: 'Q0.0', type: PointType.input, writable: false),
      PointItem(id: 'p6', name: '横向反转输出', address: 'Q0.1', type: PointType.input, writable: false),
      PointItem(id: 'p7', name: '纵向正转输出', address: 'Q0.2', type: PointType.input, writable: false),
      PointItem(id: 'p8', name: '纵向反转输出', address: 'Q0.3', type: PointType.input, writable: false),
    ],
  ),
  Template(
    id: 'tpl_check',
    name: '对点模板',
    desc: '导入 CSV 批量生成点位 · 监控页按变量组核对',
    points: [],
    check: true,
  ),
];

// ---------------- 对点模板 CSV 导入（需求 28） ----------------

/// 对点点位上限（需求 28-10）
const int kCheckPointMax = 60000;

/// 解析对点 CSV：A 列变量名称 / B 列变量组 / C 列变量类型 / D 列变量地址 /
/// F 列是否可读；其他列忽略。
///
/// 过滤规则（需求 28-8/9/7）：
///   · M 区地址（M0.0 / MW10 …）不产生控件
///   · F 列为 false 不产生控件（空 / true / 1 视为保留）
///   · 类型只支持 BOOL / BYTE / WORD / DWORD，其余丢弃
///   · 超出 [kCheckPointMax] 条截断
///
/// 返回 (点位列表, 提示说明列表)。对点控件默认全部是状态显示（需求 28-4）。
(List<PointItem>, List<String>) parseCheckCsv(String raw) {
  final points = <PointItem>[];
  final notes = <String>[];
  int skipM = 0, skipF = 0, skipType = 0, skipBad = 0;
  final stamp = DateTime.now().millisecondsSinceEpoch;
  int seq = 0;
  final lines = raw.replaceAll('\r', '').split('\n');
  // D 列必须长得像 PLC 地址（DB1.DBX0.0 / I0.0 / Q0.1 / MW10 …），
  // 表头行 / 干扰行（如 D 列写「变量地址」）按此静默跳过
  final addrLike = RegExp(r'^%?(DB\d+\.[A-Z]|DB\d+|[IQM][BWWD]?\d+)',
      caseSensitive: false);
  for (int ln = 0; ln < lines.length; ln++) {
    final line = lines[ln].trim();
    if (line.isEmpty) continue;
    final cols = splitCsvLine(line);
    final name = cols.isNotEmpty ? cols[0].trim() : '';
    final addr = cols.length > 3 ? cols[3].trim() : '';
    if (name.isEmpty || !addrLike.hasMatch(addr)) continue; // 表头 / 干扰行
    final group = cols.length > 1 ? cols[1].trim() : '';
    final typeRaw = cols.length > 2 ? cols[2].trim().toUpperCase() : 'BOOL';
    // F 列（第 6 列）：明确为 false 时不产生控件
    if (cols.length > 5) {
      final f = cols[5].trim().toLowerCase();
      if (f == 'false' || f == 'f' || f == '0' || f == '否') { skipF++; continue; }
    }
    // 类型映射（需求 28-7）：只支持四种
    final dtype = switch (typeRaw) {
      'BOOL' => VarType.boolean,
      'BYTE' => VarType.byte,
      'WORD' => VarType.word,
      'DWORD' => VarType.dword,
      _ => null,
    };
    if (dtype == null) { skipType++; continue; }
    // M 区地址过滤（需求 28-8）
    if (addrAreaOf(addr) == 'M') { skipM++; continue; }
    if (points.length >= kCheckPointMax) {
      notes.add('点位已达上限 $kCheckPointMax 条，第 ${ln + 1} 行起的多余内容未导入');
      break;
    }
    // 去掉博图导出的 % 前缀（%I0.1 → I0.1），存干净地址，
    // 监控 / 通讯 / 写入全链路都不用再判 %（s7_client.parseS7Address 也已兼容）
    final cleanAddr = addr.startsWith('%') ? addr.substring(1) : addr;
    points.add(PointItem(
      id: 'ck_${stamp}_${seq++}',
      name: name,
      address: cleanAddr,
      type: PointType.input,
      dataType: dtype,
      writable: false, // 需求 28-4：对点默认属性是状态显示
      group: group.isEmpty ? '未分组' : group,
    ));
  }
  if (skipM > 0) notes.add('M 区地址 $skipM 条已过滤');
  if (skipF > 0) notes.add('F 列为 false 的 $skipF 条已过滤');
  if (skipType > 0) notes.add('类型不支持的 $skipType 条已过滤（只支持 BOOL/BYTE/WORD/DWORD）');
  if (skipBad > 0) notes.add('名称或地址为空的 $skipBad 行已跳过');
  return (points, notes);
}

/// 按 CSV 规则切一行：支持双引号包裹（引号内逗号/双引号转义），无引号按逗号切
List<String> splitCsvLine(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  bool inQuote = false;
  for (int i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQuote) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') { buf.write('"'); i++; }
        else { inQuote = false; }
      } else {
        buf.write(c);
      }
    } else if (c == '"') {
      inQuote = true;
    } else if (c == ',') {
      out.add(buf.toString());
      buf.clear();
    } else if (c == '\t') {
      // Excel 直接粘贴是制表符分隔，兼容
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  out.add(buf.toString());
  return out;
}
