/// 西门子 S7 地址的「结构化」表示与生成规则
///
/// 用户不再手打 `DB1.DBX0.3`，而是：选区域（I/Q/M/DB）→ 选类型（BOOL/WORD…）
/// → 界面给出带方框的模板，他只在方框里填数字。
///
/// 生成规则（与博图地址写法一致）：
///   I/Q/M + BOOL              →  I0.0 / M12.3
///   I/Q/M + BYTE              →  IB0 / QB2 / MB10
///   I/Q/M + WORD|INT          →  IW0 / MW10
///   I/Q/M + DWORD|DINT|REAL|LREAL → ID0 / MD10
///   DB    + BOOL              →  DB1.DBX0.3
///   DB    + BYTE              →  DB1.DBB0
///   DB    + WORD|INT          →  DB1.DBW0
///   DB    + DWORD|DINT|REAL|LREAL →  DB1.DBD0
library s7_addr;

import 'models.dart';

/// 地址区域
enum VarArea {
  input,  // I 区：过程映像输入
  output, // Q 区：过程映像输出
  memory, // M 区：位存储器
  db,     // DB 区：数据块
}

extension VarAreaInfo on VarArea {
  /// 地址字母
  String get letter => switch (this) {
        VarArea.input => 'I',
        VarArea.output => 'Q',
        VarArea.memory => 'M',
        VarArea.db => 'DB',
      };

  /// 中文名（选择器上显示）
  String get cn => switch (this) {
        VarArea.input => 'I 区 · 输入',
        VarArea.output => 'Q 区 · 输出',
        VarArea.memory => 'M 区 · 位存储',
        VarArea.db => 'DB 区 · 数据块',
      };

  /// 该区是否可按位写（点动按钮只允许 BOOL）
  bool get bitAccessible => true;
}

/// 类型 → 地址尺寸字母
String sizeTag(VarType t) => switch (t) {
      VarType.boolean => '',
      VarType.byte => 'B',
      VarType.word || VarType.int16 => 'W',
      VarType.dword || VarType.dint || VarType.real || VarType.lreal => 'D',
    };

/// 结构化地址
class AddrSpec {
  VarArea area;
  int db;        // 仅 DB 区有效
  int byteIndex; // 起始字节
  int bitIndex;  // 位号（仅 BOOL）

  AddrSpec({
    this.area = VarArea.input,
    this.db = 1,
    this.byteIndex = 0,
    this.bitIndex = 0,
  });

  AddrSpec copy() => AddrSpec(area: area, db: db, byteIndex: byteIndex, bitIndex: bitIndex);

  /// 生成标准地址文本
  String text(VarType t) {
    if (area == VarArea.db) {
      final head = 'DB$db.DB${sizeTag(t).isEmpty ? 'X' : sizeTag(t)}$byteIndex';
      return t.isBit ? '$head.$bitIndex' : head;
    }
    final head = '${area.letter}${sizeTag(t)}$byteIndex';
    return t.isBit ? '$head.$bitIndex' : head;
  }

  @override
  String toString() => text(VarType.boolean);
}

/// 解析任意写法的地址（兼容旧存档与手工粘贴）
AddrSpec? parseAddrSpec(String raw) {
  final a = normalizeAddr(raw);
  if (a.isEmpty) return null;

  // DB 区：DB1.DBX0.3 / DB1.DBB0 / DB1.DBW0 / DB1.DBD0，也兼容 DB1.0.3（省略尺寸）
  final mDb = RegExp(r'^DB(\d+)\.(DBX|DBB|DBW|DBD)?(\d+)(?:\.(\d+))?$')
      .firstMatch(a);
  if (mDb != null) {
    final db = int.tryParse(mDb.group(1)!);
    final b = int.tryParse(mDb.group(3)!);
    if (db == null || b == null) return null;
    final kind = mDb.group(2) ?? 'DBX';
    return AddrSpec(
      area: VarArea.db,
      db: db,
      byteIndex: b,
      bitIndex: kind == 'DBX' ? (int.tryParse(mDb.group(4) ?? '0') ?? 0) : 0,
    );
  }

  // I/Q/M 区：I0.0 / IB0 / IW0 / ID0 / %I0.0
  final m = RegExp(r'^([IQM])([BWD])?(\d+)(?:\.(\d+))?$').firstMatch(a);
  if (m == null) return null;
  final area = switch (m.group(1)!) {
    'I' => VarArea.input,
    'Q' => VarArea.output,
    _ => VarArea.memory,
  };
  final b = int.tryParse(m.group(3)!);
  if (b == null) return null;
  return AddrSpec(
    area: area,
    byteIndex: b,
    bitIndex: int.tryParse(m.group(4) ?? '0') ?? 0,
  );
}

/// 规范化：大写、去空格、去 % 前缀（博图导出的绝对地址常带 %）
String normalizeAddr(String raw) {
  var s = raw.trim().toUpperCase().replaceAll(' ', '').replaceAll('\t', '');
  if (s.startsWith('%')) s = s.substring(1);
  return s;
}

/// 地址是否属于某个区（给界面做统计/提示用）
bool addrInArea(String addr, VarArea area) => parseAddrSpec(addr)?.area == area;

/// 换了变量类型后重新生成地址文本（保留原字节号 / 位号）
///
/// 例：M10.2 从 BOOL 改成 WORD → MW10；DB1.DBD0 从 REAL 改成 BOOL → DB1.DBX0.0
String addrFromText(String addr, VarType t) {
  final s = parseAddrSpec(addr);
  if (s == null) return addr;
  return s.text(t);
}
