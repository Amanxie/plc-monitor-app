import 'package:flutter_test/flutter_test.dart';
import 'package:plc_app/models.dart';
import 'package:plc_app/s7_client.dart';

void main() {
  group('VarType.decode 大端解码', () {
    test('BOOL', () {
      expect(VarType.boolean.decode([0x01]), true);
      expect(VarType.boolean.decode([0x00]), false);
    });

    test('BYTE 无符号 1 字节', () {
      expect(VarType.byte.decode([0x00]), 0);
      expect(VarType.byte.decode([0xFF]), 255);
      expect(VarType.byte.decode([0x80]), 128);
    });

    test('WORD 无符号 2 字节', () {
      expect(VarType.word.decode([0x00, 0x00]), 0);
      expect(VarType.word.decode([0x12, 0x34]), 0x1234);
      expect(VarType.word.decode([0xFF, 0xFF]), 65535);
    });

    test('INT 有符号 2 字节', () {
      expect(VarType.int16.decode([0x00, 0x01]), 1);
      expect(VarType.int16.decode([0x7F, 0xFF]), 32767);
      expect(VarType.int16.decode([0xFF, 0xFF]), -1);
      expect(VarType.int16.decode([0x80, 0x00]), -32768);
      expect(VarType.int16.decode([0xFF, 0xFE]), -2);
    });

    test('DWORD 无符号 4 字节', () {
      expect(VarType.dword.decode([0x00, 0x00, 0x00, 0x01]), 1);
      expect(VarType.dword.decode([0x12, 0x34, 0x56, 0x78]), 0x12345678);
      expect(VarType.dword.decode([0xFF, 0xFF, 0xFF, 0xFF]), 4294967295);
    });

    test('DINT 有符号 4 字节', () {
      expect(VarType.dint.decode([0x00, 0x00, 0x00, 0x01]), 1);
      expect(VarType.dint.decode([0xFF, 0xFF, 0xFF, 0xFF]), -1);
      expect(VarType.dint.decode([0x80, 0x00, 0x00, 0x00]), -2147483648);
      expect(VarType.dint.decode([0x7F, 0xFF, 0xFF, 0xFF]), 2147483647);
    });

    test('REAL 32 位浮点', () {
      expect(VarType.real.decode([0x3F, 0xC0, 0x00, 0x00]), 1.5);
      expect(VarType.real.decode([0xC0, 0x10, 0x00, 0x00]), -2.25);
      expect(VarType.real.decode([0x00, 0x00, 0x00, 0x00]), 0.0);
      expect(VarType.real.decode([0x40, 0x49, 0x0F, 0xDB]),
          closeTo(3.1415927, 1e-6));
    });

    test('LREAL 64 位浮点', () {
      expect(VarType.lreal.decode([0x3F, 0xF8, 0, 0, 0, 0, 0, 0]), 1.5);
      expect(
          VarType.lreal.decode([0x40, 0x09, 0x21, 0xFB, 0x54, 0x44, 0x2D, 0x18]),
          closeTo(3.141592653589793, 1e-12));
      expect(VarType.lreal.decode([0xC0, 0x00, 0, 0, 0, 0, 0, 0]), -2.0);
    });

    test('字节数定义', () {
      expect(VarType.boolean.byteSize, 1);
      expect(VarType.byte.byteSize, 1);
      expect(VarType.word.byteSize, 2);
      expect(VarType.int16.byteSize, 2);
      expect(VarType.dword.byteSize, 4);
      expect(VarType.dint.byteSize, 4);
      expect(VarType.real.byteSize, 4);
      expect(VarType.lreal.byteSize, 8);
    });
  });

  group('地址解析', () {
    test('位地址', () {
      final p = parseS7Address('I0.3')!;
      expect(p.area, 0x81);
      expect(p.byteIndex, 0);
      expect(p.bitIndex, 3);
    });

    test('M 区位地址', () {
      final p = parseS7Address('M10.2')!;
      expect(p.area, 0x83);
      expect(p.byteIndex, 10);
      expect(p.bitIndex, 2);
    });

    test('尺寸字母写法 MB/MW/MD 起始字节一致', () {
      expect(parseS7Address('MB10')!.byteIndex, 10);
      expect(parseS7Address('MW10')!.byteIndex, 10);
      expect(parseS7Address('MD10')!.byteIndex, 10);
      expect(parseS7Address('MW10')!.area, 0x83);
    });

    test('DB 区多种写法', () {
      final a = parseS7Address('DB1.DBX2.5')!;
      expect(a.area, 0x84);
      expect(a.db, 1);
      expect(a.byteIndex, 2);
      expect(a.bitIndex, 5);

      final b = parseS7Address('DB3.DBW4')!;
      expect(b.db, 3);
      expect(b.byteIndex, 4);
      expect(b.bitIndex, 0);
    });

    test('非法地址返回 null', () {
      expect(parseS7Address('XYZ'), isNull);
      expect(parseS7Address(''), isNull);
      expect(parseS7Address('DB1.ZZZ0'), isNull);
    });
  });

  group('数值格式化', () {
    test('BOOL 显示 ON/OFF', () {
      expect(formatVarValue(VarType.boolean, true), 'ON');
      expect(formatVarValue(VarType.boolean, false), 'OFF');
    });

    test('整数原样', () {
      expect(formatVarValue(VarType.word, 1234), '1234');
      expect(formatVarValue(VarType.int16, -55), '-55');
    });

    test('浮点去掉多余 0', () {
      expect(formatVarValue(VarType.real, 1.5), '1.5');
      expect(formatVarValue(VarType.real, 2.0), '2');
      expect(formatVarValue(VarType.real, 3.14159), '3.142');
    });

    test('空值占位', () {
      expect(formatVarValue(VarType.real, null), '--');
    });
  });
}
