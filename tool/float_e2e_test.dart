/// 浮点数与多类型读取的端到端自测
///
/// 不只看 decode()，而是让真实的 S7Client 通过 TCP 跑完整链路：
///   COTP 握手 → Setup → 批量读（BOOL/BYTE/WORD/INT/DWORD/DINT/REAL/LREAL）
/// 服务端故意用 4 种「数据项写法」回包，覆盖不同固件的差异：
///   · ts=0x04 长度按字节        · ts=0x07 长度按位（规范写法）
///   · ts=0x07 长度按字节（部分网关）  · 有/无填充字节
///
/// 用法：dart run tool/float_e2e_test.dart
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lib/models.dart';
import '../lib/s7_addr.dart';
import '../lib/s7_client.dart';
import '../lib/symbol_parse.dart';

/// 服务端把「4/8 字节数据」当成什么类型回包
enum TsMode {
  byte04,      // ts=0x04，长度=字节（S7-1200 常见）
  real07bits,  // ts=0x07，长度=位（规范）
  real07bytes, // ts=0x07，长度=字节（部分网关）
}

class MockPlc {
  TsMode mode;
  bool pad;
  final Map<String, List<int>> bank = {
    'I': List<int>.filled(64, 0),
    'Q': List<int>.filled(64, 0),
    'M': List<int>.filled(64, 0),
    'DB1': List<int>.filled(64, 0),
  };
  ServerSocket? _srv;
  final List<String> log = [];

  MockPlc({this.mode = TsMode.byte04, this.pad = true});

  int get port => _srv!.port;

  Future<void> start() async {
    _srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _srv!.listen(_handle);
  }

  Future<void> stop() async => _srv?.close();

  void _handle(Socket s) {
    final buf = <int>[];
    s.listen((d) {
      buf.addAll(d);
      while (true) {
        if (buf.length < 4) return;
        final total = (buf[2] << 8) | buf[3];
        if (total < 7 || buf.length < total) return;
        final frame = Uint8List.fromList(buf.sublist(0, total));
        buf.removeRange(0, total);
        final resp = _onFrame(frame);
        if (resp != null) s.add(resp);
      }
    }, onError: (_) {}, onDone: () => s.destroy());
  }

  Uint8List _tpkt(List<int> body) {
    final t = body.length + 4;
    return Uint8List.fromList([0x03, 0x00, (t >> 8) & 0xFF, t & 0xFF, ...body]);
  }

  String _key(int area, int db) => switch (area) {
        0x81 => 'I',
        0x82 => 'Q',
        0x83 => 'M',
        _ => 'DB$db',
      };

  Uint8List? _onFrame(Uint8List f) {
    if ((f[5] & 0xF0) == 0xE0) {
      return _tpkt([
        0x11, 0xD0, 0x00, 0x01, 0x00, 0x01, 0x00,
        0xC0, 0x01, 0x0A, 0xC1, 0x02, 0x01, 0x00, 0xC2, 0x02, 0x01, 0x01,
      ]);
    }
    final s7 = f.sublist(7);
    final ref = [s7[4], s7[5]];
    final plen = (s7[6] << 8) | s7[7];
    final param = s7.sublist(10, 10 + plen);
    final func = param[0];

    Uint8List header(int pLen, int dLen) => Uint8List.fromList([
          0x32, 0x03, 0x00, 0x00,
          ref[0], ref[1],
          (pLen >> 8) & 0xFF, pLen & 0xFF,
          (dLen >> 8) & 0xFF, dLen & 0xFF,
          0x00, 0x00,
        ]);

    if (func == 0xF0) {
      return _tpkt([0x02, 0xF0, 0x80, ...header(8, 0),
        0xF0, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 240]);
    }

    if (func == 0x04) {
      final cnt = param[1];
      final out = <int>[];
      for (int i = 0; i < cnt; i++) {
        final it = param.sublist(2 + i * 12, 2 + i * 12 + 12);
        final tsReq = it[3];
        final lenReq = (it[4] << 8) | it[5];
        final db = (it[6] << 8) | it[7];
        final area = it[8];
        final bitAddr = (it[9] << 16) | (it[10] << 8) | it[11];
        final isBit = tsReq == 0x01;
        final size = isBit ? 1 : lenReq;
        final byteOff = bitAddr >> 3;

        final b = bank[_key(area, db)] ?? List<int>.filled(64, 0);
        final data = <int>[];
        for (int k = 0; k < size; k++) {
          data.add((byteOff + k) < b.length ? b[byteOff + k] : 0);
        }

        int rts;
        int rlen;
        if (isBit) {
          rts = 0x03;
          rlen = 1;
        } else if ((size == 4 || size == 8) && mode != TsMode.byte04) {
          rts = 0x07;
          rlen = mode == TsMode.real07bits ? size * 8 : size;
        } else {
          rts = 0x04;
          rlen = size;
        }
        out.addAll([0xFF, rts, (rlen >> 8) & 0xFF, rlen & 0xFF, ...data]);
        if (pad && data.length.isOdd) out.add(0x00);
      }
      return _tpkt([0x02, 0xF0, 0x80, ...header(2, out.length), 0x04, cnt, ...out]);
    }

    log.add('未实现功能 0x${func.toRadixString(16)}');
    return null;
  }
}

// ---------------------------------------------------------------- 字节工具

Uint8List f32(double v) {
  final b = ByteData(4);
  b.setFloat32(0, v, Endian.big);
  return b.buffer.asUint8List();
}

Uint8List f64(double v) {
  final b = ByteData(8);
  b.setFloat64(0, v, Endian.big);
  return b.buffer.asUint8List();
}

Uint8List i32(int v) {
  final b = ByteData(4);
  b.setInt32(0, v, Endian.big);
  return b.buffer.asUint8List();
}

Uint8List u16(int v) {
  final b = ByteData(2);
  b.setUint16(0, v, Endian.big);
  return b.buffer.asUint8List();
}

void put(List<int> dst, int off, List<int> src) {
  for (int i = 0; i < src.length; i++) {
    dst[off + i] = src[i];
  }
}

var _failed = 0;
var _passed = 0;

void check(String name, bool ok, [String extra = '']) {
  if (ok) {
    _passed++;
  } else {
    _failed++;
    stdout.writeln('FAIL  $name${extra.isEmpty ? '' : '   →  $extra'}');
  }
}

void checkEq(String name, Object? got, Object? want) =>
    check(name, got == want, 'got=$got want=$want');

// ---------------------------------------------------------------- 预置数据

MockPlc buildPlc(TsMode mode, bool pad) {
  final srv = MockPlc(mode: mode, pad: pad);
  final db = srv.bank['DB1']!;
  put(db, 0, f32(3.14159));
  put(db, 4, f32(-1234.5678));
  put(db, 8, f32(1.5e-7));
  put(db, 12, f32(0));
  put(db, 16, f64(2.718281828459045));
  final m = srv.bank['M']!;
  put(m, 10, u16(0x8000)); // MW10 = 32768 / INT = -32768
  put(m, 20, i32(-2147483648)); // MD20 = DINT 最小值
  m[30] = 0x08; // M30.3 = 1
  return srv;
}

Future<void> runScenario(TsMode mode, bool pad) async {
  final srv = buildPlc(mode, pad);
  await srv.start();
  final c = S7Client('127.0.0.1', port: srv.port);
  final tag = '[${mode.name}${pad ? '+pad' : ''}]';
  try {
    await c.connect();

    final items = <S7ReadItem>[
      S7ReadItem(parseS7Address('DB1.DBD0')!, VarType.real),
      S7ReadItem(parseS7Address('DB1.DBD4')!, VarType.real),
      S7ReadItem(parseS7Address('DB1.DBD8')!, VarType.real),
      S7ReadItem(parseS7Address('DB1.DBD12')!, VarType.real),
      S7ReadItem(parseS7Address('DB1.DBD16')!, VarType.lreal),
      S7ReadItem(parseS7Address('MW10')!, VarType.word),
      S7ReadItem(parseS7Address('MW10')!, VarType.int16),
      S7ReadItem(parseS7Address('MD20')!, VarType.dint),
      S7ReadItem(parseS7Address('DB1.DBB0')!, VarType.byte),
      S7ReadItem(parseS7Address('DB1.DBW0')!, VarType.word),
      S7ReadItem(parseS7Address('M30.3')!, VarType.boolean),
      S7ReadItem(parseS7Address('DB1.DBD0')!, VarType.dword),
    ];
    final v = await c.readValues(items);

    // ---- 数值正确性 ----
    double d(int i) => (v[i] as double);
    check('$tag REAL 3.14159', (d(0) - 3.14159).abs() < 1e-5, '${v[0]}');
    check('$tag REAL -1234.5678', (d(1) + 1234.5678).abs() < 1e-3, '${v[1]}');
    check('$tag REAL 1.5e-7', (d(2) - 1.5e-7).abs() < 1e-12, '${v[2]}');
    checkEq('$tag REAL 0', d(3), 0.0);
    check('$tag LREAL e', (d(4) - 2.718281828459045).abs() < 1e-15, '${v[4]}');
    checkEq('$tag WORD 0x8000', v[5], 32768);
    checkEq('$tag INT 0x8000', v[6], -32768);
    checkEq('$tag DINT 最小值', v[7], -2147483648);
    checkEq('$tag BYTE 0x40', v[8], 64);
    checkEq('$tag DBW0 0x4049', v[9], 0x4049);
    checkEq('$tag BOOL M30.3', v[10], true);
    checkEq('$tag DWORD 0x40490FD0', v[11], 0x40490FD0);

    // ---- 显示文本 ----
    checkEq('$tag 显示 REAL 3.14159', formatVarValue(VarType.real, v[0]), '3.14159');
    checkEq('$tag 显示 REAL 负值', formatVarValue(VarType.real, v[1]), '-1234.568');
    checkEq('$tag 显示 REAL 极小值', formatVarValue(VarType.real, v[2]), '1.5e-7');
    checkEq('$tag 显示 REAL 0', formatVarValue(VarType.real, v[3]), '0');
    check('$tag 显示 LREAL 精度',
        formatVarValue(VarType.lreal, v[4]).startsWith('2.7182818284590'),
        formatVarValue(VarType.lreal, v[4]));
    checkEq('$tag 显示 INT', formatVarValue(VarType.int16, v[6]), '-32768');
    checkEq('$tag 显示 BOOL', formatVarValue(VarType.boolean, v[10]), 'ON');
  } catch (e) {
    check('$tag 读取链路', false, e.toString());
  } finally {
    await c.disconnect();
    await srv.stop();
  }
}

// ---------------------------------------------------------------- 地址规则

void testAddressRules() {
  // 需求第 8 条里列出的 9 种组合
  final cases = <(VarArea, VarType, String)>[
    (VarArea.input, VarType.boolean, 'I0.0'),
    (VarArea.input, VarType.word, 'IW0'),
    (VarArea.input, VarType.dword, 'ID0'),
    (VarArea.memory, VarType.dword, 'MD0'),
    (VarArea.db, VarType.boolean, 'DB1.DBX0.0'),
    (VarArea.db, VarType.byte, 'DB1.DBB0'),
    (VarArea.db, VarType.dint, 'DB1.DBD0'),
    (VarArea.db, VarType.real, 'DB1.DBD0'),
    (VarArea.memory, VarType.boolean, 'M0.0'),
    // 补全其余组合
    (VarArea.output, VarType.boolean, 'Q0.0'),
    (VarArea.output, VarType.byte, 'QB0'),
    (VarArea.memory, VarType.byte, 'MB0'),
    (VarArea.memory, VarType.int16, 'MW0'),
    (VarArea.input, VarType.int16, 'IW0'),
    (VarArea.input, VarType.lreal, 'ID0'),
    (VarArea.db, VarType.word, 'DB1.DBW0'),
    (VarArea.db, VarType.lreal, 'DB1.DBD0'),
  ];
  for (final (area, t, want) in cases) {
    final got = AddrSpec(area: area, db: 1, byteIndex: 0, bitIndex: 0).text(t);
    checkEq('地址生成 ${area.letter}+${t.label}', got, want);
    // 反解析必须能还原
    final back = parseAddrSpec(got);
    check('地址反解析 $got', back != null && back.area == area, '$back');
  }

  // 带编号的情况
  checkEq('M 区 BOOL 第 12 字节第 3 位',
      AddrSpec(area: VarArea.memory, byteIndex: 12, bitIndex: 3).text(VarType.boolean),
      'M12.3');
  checkEq('DB 区 REAL，DB 5 偏移 24',
      AddrSpec(area: VarArea.db, db: 5, byteIndex: 24).text(VarType.real),
      'DB5.DBD24');

  // 类型切换后地址自动换尺寸字母
  checkEq('BOOL→WORD', addrFromText('M10.2', VarType.word), 'MW10');
  checkEq('REAL→BOOL', addrFromText('DB1.DBD16', VarType.boolean), 'DB1.DBX16.0');
  checkEq('旧写法 %I0.0', normalizeAddr('%I0.0'), 'I0.0');
  checkEq('旧写法 DB1.0.3', parseAddrSpec('DB1.0.3')?.text(VarType.boolean), 'DB1.DBX0.3');
}

// ---------------------------------------------------------------- 注释解析

void testSymbolParse() {
  final m = <String, String>{};

  // 带表头的 TSV（博图变量表直接复制）
  final tsv = '名称\t数据类型\t逻辑地址\t注释\n'
      '一层到位\tBool\t%I0.0\t1#提升机上位到位\n'
      '液压压力\tReal\t%DB1.DBD0\t液压站压力\n'
      '运行中\tBool\t%M30.3\t设备运行中\n';
  checkEq('TSV 导入条数', importSymbolsInto(m, tsv), 3);
  checkEq('I0.0 注释', m['I0.0'], '1#提升机上位到位');
  checkEq('DB1.DBD0 注释', m['DB1.DBD0'], '液压站压力');
  checkEq('M30.3 注释', m['M30.3'], '设备运行中');

  // 无表头，地址在中间
  final plain = <String, String>{};
  checkEq('无表头条数', importSymbolsInto(plain, '二层到位\tBool\tI0.1\t2#提升机到位'), 1);
  checkEq('无表头注释', plain['I0.1'], '2#提升机到位');

  // CSV + 引号
  final csv = <String, String>{};
  checkEq('CSV 条数',
      importSymbolsInto(csv, '"压力","Real","DB1.DBD4","系统压力，含逗号"'), 1);
  checkEq('CSV 注释', csv['DB1.DBD4'], '系统压力，含逗号');

  // 地址在最后一列（注释在左）
  final last = <String, String>{};
  checkEq('地址在末列', importSymbolsInto(last, '减速信号,Real,M20'), 1);
  checkEq('地址在末列注释', last['M20'], '减速信号');

  // 垃圾行不应污染
  final junk = <String, String>{};
  importSymbolsInto(junk, '序号\t说明\n1\t空行\n\n');
  checkEq('垃圾行被忽略', junk.length, 0);
}

// ---------------------------------------------------------------- main

Future<void> main() async {
  stdout.writeln('=== 1. 地址规则（需求第 8 条） ===');
  testAddressRules();
  stdout.writeln('  通过 $_passed 项');

  stdout.writeln('=== 2. 变量注释解析（需求第 11 条） ===');
  testSymbolParse();

  stdout.writeln('=== 3. 浮点/多类型端到端读取（需求第 7 条） ===');
  for (final mode in TsMode.values) {
    for (final pad in [true, false]) {
      await runScenario(mode, pad);
    }
  }

  // 单独校验格式化边界
  checkEq('格式化 整数型浮点', formatFloat(100.0, 7), '100');
  checkEq('格式化 大数转科学', formatFloat(1234567890.0, 7), '1.234568e+9');
  checkEq('格式化 负数', formatFloat(-0.5, 7), '-0.5');
  checkEq('格式化 NaN', formatFloat(double.nan, 7), 'NaN');
  checkEq('格式化 正无穷', formatFloat(double.infinity, 7), '∞');
  checkEq('格式化 WORD 值', formatVarValue(VarType.word, 65535), '65535');
  checkEq('格式化 null', formatVarValue(VarType.real, null), '--');
  checkEq('格式化 LREAL 15 位', formatFloat(0.1 + 0.2, 15), '0.3');

  stdout.writeln('');
  stdout.writeln('通过 $_passed 项，失败 $_failed 项');
  exit(_failed == 0 ? 0 : 1);
}
