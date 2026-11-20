// 回归测试：TIA Portal 变量表导出的 CSV（地址带 % 前缀、Bool 首字母大写）
// 曾经导致通讯层报「I0.1 无法解析」：
//   parseCheckCsv 原样保留 %I0.1 → s7_client.parseS7Address 不认 % → 通讯读不到
// 修复：parseCheckCsv 存地址去掉 %；parseS7Address 兼容 % 前缀
import 'package:flutter_test/flutter_test.dart';
import 'package:plc_app/models.dart';
import 'package:plc_app/s7_client.dart';

/// 按 TIA Portal「变量表 → 导出 CSV」的真实格式构造样例（ANSI/GBK 编码的
/// 中文组名用占位文本代替，列结构与真实文件一致）
const String tiaExport = '''
Name,Path,Data Type,Logical Address,Comment,Hmi Visible,Hmi Accessible,Hmi Writeable,Typeobject ID,Version ID
System_Byte,Default,Byte,%MB1,,True,True,True,,
Clock_1Hz,Default,Bool,%M0.5,,True,True,True,,
I0.0,Default,Bool,%I0.0,,True,True,True,,
I0.1,Default,Bool,%I0.1,,True,True,True,,
Q0.0,Default,Bool,%Q0.0,,True,True,True,,
I1000.0,Default,Bool,%I1000.0,,True,True,True,,
tt,Default,"""datatype1""",%I1002.0,,True,True,True,,
''';

void main() {
  test('TIA 变量表导出 CSV：I0.1 可解析且地址不带 %', () {
    final (points, notes) = parseCheckCsv(tiaExport);
    // M 区 2 条（%MB1、%M0.5）+ 类型 1 条（datatype1）被过滤
    expect(points.length, 4, reason: 'notes=$notes');
    expect(notes, contains('M 区地址 2 条已过滤'));
    expect(notes, contains('类型不支持的 1 条已过滤（只支持 BOOL/BYTE/WORD/DWORD）'));

    final i01 = points.where((p) => p.name == 'I0.1').toList();
    expect(i01.length, 1);
    expect(i01.first.address, 'I0.1', reason: '新导入的地址必须去掉 % 前缀');
    expect(points.every((p) => !p.address.startsWith('%')), true);
  });

  test('通讯层兼容带 % 的旧存档地址（修复前已导入的数据无需重新导入）', () {
    final p = parseS7Address('%I0.1');
    expect(p, isNotNull);
    expect(p!.byteIndex, 0);
    expect(p.bitIndex, 1);
    final q = parseS7Address('%Q0.0');
    expect(q, isNotNull);
    expect(q!.byteIndex, 0);
    final db = parseS7Address('%DB90.DBW362');
    expect(db, isNotNull);
    expect(db!.db, 90);
    expect(db.byteIndex, 362);
  });
}
