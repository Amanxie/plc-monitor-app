// 用 App 的真实 S7Client 连仿真 PLC（dart run tool/live_app_read.dart [ip]）
import '../lib/s7_client.dart';
import '../lib/models.dart';

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '192.168.0.1';
  final c = S7Client(host, rack: 0, slot: 1);
  await c.connect();
  print('connect OK');

  final p = <S7Point>[
    const S7Point(0x81, 0, 0, 0),
    const S7Point(0x81, 0, 1, 0),
    const S7Point(0x81, 0, 2, 0),
    const S7Point(0x81, 0, 3, 0),
    const S7Point(0x82, 0, 0, 0),
    const S7Point(0x82, 0, 1, 0),
  ];

  // 场景 A：全 BOOL（readBits 路径）
  try {
    final v = await c.readBits(p);
    print('A readBits all-BOOL: ' + v.join(','));
  } catch (e) {
    print('A FAILED: $e');
  }

  // 场景 B：readValues 全 BOOL
  try {
    final items = p.map((x) => S7ReadItem(x, VarType.boolean)).toList();
    final v = await c.readValues(items);
    print('B readValues all-BOOL: ' + v.join(','));
  } catch (e) {
    print('B FAILED: $e');
  }

  // 场景 C：readValues 混合（4 BOOL + 1 REAL(Q0.0) + 1 BOOL(Q0.1)）
  try {
    final items = <S7ReadItem>[
      S7ReadItem(p[0], VarType.boolean),
      S7ReadItem(p[1], VarType.boolean),
      S7ReadItem(p[2], VarType.boolean),
      S7ReadItem(p[3], VarType.boolean),
      S7ReadItem(p[4], VarType.real),
      S7ReadItem(p[5], VarType.boolean),
    ];
    final v = await c.readValues(items);
    print('C mixed(REAL@4): ' + v.join(','));
  } catch (e) {
    print('C FAILED: $e');
  }

  // 场景 D：readValues 混合（REAL 在中间 I0.2）
  try {
    final items = <S7ReadItem>[
      S7ReadItem(p[0], VarType.boolean),
      S7ReadItem(p[1], VarType.boolean),
      S7ReadItem(p[2], VarType.real),
      S7ReadItem(p[3], VarType.boolean),
      S7ReadItem(p[4], VarType.boolean),
      S7ReadItem(p[5], VarType.boolean),
    ];
    final v = await c.readValues(items);
    print('D mixed(REAL@2): ' + v.join(','));
  } catch (e) {
    print('D FAILED: $e');
  }

  // 场景 E：WORD 混合
  try {
    final items = <S7ReadItem>[
      S7ReadItem(p[0], VarType.boolean),
      S7ReadItem(p[1], VarType.word),
      S7ReadItem(p[2], VarType.boolean),
      S7ReadItem(p[3], VarType.boolean),
      S7ReadItem(p[4], VarType.boolean),
      S7ReadItem(p[5], VarType.boolean),
    ];
    final v = await c.readValues(items);
    print('E mixed(WORD@1): ' + v.join(','));
  } catch (e) {
    print('E FAILED: $e');
  }

  // 场景 F：LREAL
  try {
    final items = <S7ReadItem>[
      S7ReadItem(p[0], VarType.boolean),
      S7ReadItem(p[1], VarType.boolean),
      S7ReadItem(p[2], VarType.boolean),
      S7ReadItem(p[3], VarType.boolean),
      S7ReadItem(p[4], VarType.lreal),
      S7ReadItem(p[5], VarType.boolean),
    ];
    final v = await c.readValues(items);
    print('F LREAL@4: ' + v.join(','));
  } catch (e) {
    print('F FAILED: $e');
  }

  await c.disconnect();
  print('done');
}
