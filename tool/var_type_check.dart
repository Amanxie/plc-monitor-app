/// 变量类型解码 / 地址解析的自检脚本
/// 运行：dart run tool/var_type_check.dart
library var_type_check;

import '../lib/models.dart';
import '../lib/s7_client.dart';

int passed = 0;
int failed = 0;

void eq(String label, Object? actual, Object? expected) {
  final ok = '$actual' == '$expected';
  if (ok) {
    passed++;
  } else {
    failed++;
    print('  FAIL  $label  =>  got "$actual"  expected "$expected"');
  }
}

void near(String label, Object? actual, double expected, double tol) {
  if (actual is double && (actual - expected).abs() <= tol) {
    passed++;
  } else {
    failed++;
    print('  FAIL  $label  =>  got "$actual"  expected ~$expected');
  }
}

void main() {
  print('=== VarType.decode (big-endian) ===');
  eq('BOOL 1', VarType.boolean.decode([0x01]), true);
  eq('BOOL 0', VarType.boolean.decode([0x00]), false);

  eq('BYTE 0x00', VarType.byte.decode([0x00]), 0);
  eq('BYTE 0xFF', VarType.byte.decode([0xFF]), 255);
  eq('BYTE 0x80', VarType.byte.decode([0x80]), 128);

  eq('WORD 0', VarType.word.decode([0x00, 0x00]), 0);
  eq('WORD 0x1234', VarType.word.decode([0x12, 0x34]), 0x1234);
  eq('WORD max', VarType.word.decode([0xFF, 0xFF]), 65535);

  eq('INT 1', VarType.int16.decode([0x00, 0x01]), 1);
  eq('INT max', VarType.int16.decode([0x7F, 0xFF]), 32767);
  eq('INT -1', VarType.int16.decode([0xFF, 0xFF]), -1);
  eq('INT min', VarType.int16.decode([0x80, 0x00]), -32768);
  eq('INT -2', VarType.int16.decode([0xFF, 0xFE]), -2);

  eq('DWORD 1', VarType.dword.decode([0, 0, 0, 1]), 1);
  eq('DWORD 0x12345678', VarType.dword.decode([0x12, 0x34, 0x56, 0x78]), 0x12345678);
  eq('DWORD max', VarType.dword.decode([0xFF, 0xFF, 0xFF, 0xFF]), 4294967295);

  eq('DINT 1', VarType.dint.decode([0, 0, 0, 1]), 1);
  eq('DINT -1', VarType.dint.decode([0xFF, 0xFF, 0xFF, 0xFF]), -1);
  eq('DINT min', VarType.dint.decode([0x80, 0, 0, 0]), -2147483648);
  eq('DINT max', VarType.dint.decode([0x7F, 0xFF, 0xFF, 0xFF]), 2147483647);

  near('REAL 1.5', VarType.real.decode([0x3F, 0xC0, 0x00, 0x00]), 1.5, 1e-6);
  near('REAL -2.25', VarType.real.decode([0xC0, 0x10, 0x00, 0x00]), -2.25, 1e-6);
  near('REAL 0', VarType.real.decode([0, 0, 0, 0]), 0.0, 1e-9);
  near('REAL pi', VarType.real.decode([0x40, 0x49, 0x0F, 0xDB]), 3.1415927, 1e-6);

  near('LREAL 1.5', VarType.lreal.decode([0x3F, 0xF8, 0, 0, 0, 0, 0, 0]), 1.5, 1e-12);
  near('LREAL pi',
      VarType.lreal.decode([0x40, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18]),
      3.141592653589793, 1e-12);
  near('LREAL -2', VarType.lreal.decode([0xC0, 0x00, 0, 0, 0, 0, 0, 0]), -2.0, 1e-12);

  print('=== byteSize ===');
  eq('BOOL size', VarType.boolean.byteSize, 1);
  eq('BYTE size', VarType.byte.byteSize, 1);
  eq('WORD size', VarType.word.byteSize, 2);
  eq('INT size', VarType.int16.byteSize, 2);
  eq('DWORD size', VarType.dword.byteSize, 4);
  eq('DINT size', VarType.dint.byteSize, 4);
  eq('REAL size', VarType.real.byteSize, 4);
  eq('LREAL size', VarType.lreal.byteSize, 8);

  print('=== label ===');
  eq('BOOL', VarType.boolean.label, 'BOOL');
  eq('BYTE', VarType.byte.label, 'BYTE');
  eq('WORD', VarType.word.label, 'WORD');
  eq('DWORD', VarType.dword.label, 'DWORD');
  eq('INT', VarType.int16.label, 'INT');
  eq('DINT', VarType.dint.label, 'DINT');
  eq('REAL', VarType.real.label, 'REAL');
  eq('LREAL', VarType.lreal.label, 'LREAL');

  print('=== parseS7Address ===');
  final p1 = parseS7Address('I0.3')!;
  eq('I0.3 area', p1.area, 0x81);
  eq('I0.3 byte', p1.byteIndex, 0);
  eq('I0.3 bit', p1.bitIndex, 3);

  final p2 = parseS7Address('M10.2')!;
  eq('M10.2 area', p2.area, 0x83);
  eq('M10.2 byte', p2.byteIndex, 10);
  eq('M10.2 bit', p2.bitIndex, 2);

  eq('MB10 byte', parseS7Address('MB10')!.byteIndex, 10);
  eq('MW10 byte', parseS7Address('MW10')!.byteIndex, 10);
  eq('MD10 byte', parseS7Address('MD10')!.byteIndex, 10);
  eq('MW10 area', parseS7Address('MW10')!.area, 0x83);
  eq('QW4 byte', parseS7Address('QW4')!.byteIndex, 4);

  final d1 = parseS7Address('DB1.DBX2.5')!;
  eq('DB1.DBX2.5 area', d1.area, 0x84);
  eq('DB1.DBX2.5 db', d1.db, 1);
  eq('DB1.DBX2.5 byte', d1.byteIndex, 2);
  eq('DB1.DBX2.5 bit', d1.bitIndex, 5);

  final d2 = parseS7Address('DB3.DBW4')!;
  eq('DB3.DBW4 db', d2.db, 3);
  eq('DB3.DBW4 byte', d2.byteIndex, 4);
  eq('DB3.DBW4 bit', d2.bitIndex, 0);

  eq('bad addr', parseS7Address('XYZ'), null);
  eq('empty addr', parseS7Address(''), null);
  eq('bad db', parseS7Address('DB1.ZZZ0'), null);

  print('=== formatVarValue ===');
  eq('bool true', formatVarValue(VarType.boolean, true), 'ON');
  eq('bool false', formatVarValue(VarType.boolean, false), 'OFF');
  eq('word', formatVarValue(VarType.word, 1234), '1234');
  eq('int neg', formatVarValue(VarType.int16, -55), '-55');
  eq('real 1.5', formatVarValue(VarType.real, 1.5), '1.5');
  eq('real 2.0', formatVarValue(VarType.real, 2.0), '2');
  eq('real pi', formatVarValue(VarType.real, 3.14159), '3.142');
  eq('null', formatVarValue(VarType.real, null), '--');

  print('=== PointItem 序列化兼容旧数据 ===');
  final old = PointItem.fromJson({
    'id': 'p1',
    'name': '旧点位',
    'address': 'I0.0',
    'type': 'input',
    'visible': true,
  });
  eq('legacy dataType', old.dataType, VarType.boolean);

  final neu = PointItem.fromJson({
    'id': 'p2',
    'name': '新点位',
    'address': 'MW10',
    'type': 'input',
    'dataType': 'real',
    'visible': true,
  });
  eq('new dataType', neu.dataType, VarType.real);
  eq('roundtrip', neu.toJson()['dataType'], 'real');

  print('');
  print('RESULT: passed=$passed  failed=$failed');
  if (failed > 0) {
    throw StateError('$failed check(s) failed');
  }
}
