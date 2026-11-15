// 变量注释一次性导入的自检（纯 Dart，dart run tool/symbol_check.dart）
import 'dart:convert';
import '../lib/symbol_parse.dart';
import '../lib/s7_addr.dart';

int pass = 0, fail = 0;

void ck(String tag, Object? got, Object? want) {
  if ('$got' == '$want') {
    pass++;
  } else {
    fail++;
    print('FAIL  $tag\n   got : $got\n   want: $want');
  }
}

void main() {
  // ---------- 1. 博图带表头 TSV ----------
  final a = <String, String>{};
  final tsv = '名称\t数据类型\t逻辑地址\t注释\n'
      '一层到位\tBool\t%I0.0\t1#提升机上位到位\n'
      '二层到位\tBool\t%I0.1\t2#提升机上位到位\n'
      '速度\tReal\t%MD10\t运行速度 m/s';
  final n1 = importSymbolsInto(a, tsv);
  ck('TSV 条数', n1, 3);
  ck('I0.0', a['I0.0'], '1#提升机上位到位');
  ck('MD10', a['MD10'], '运行速度 m/s');

  // ---------- 2. 无表头 CSV（地址在中间，注释在右） ----------
  final b = <String, String>{};
  final csv = 'Motor1,Bool,I0.5,1#电机运行\n'
      'Motor2,Bool,Q0.5,1#电机启动';
  ck('无表头条数', importSymbolsInto(b, csv), 2);
  ck('I0.5', b['I0.5'], '1#电机运行');

  // ---------- 3. 只有名称 + 地址，没有注释列 → 用名称兜底 ----------
  final c = <String, String>{};
  final noCmt = '名称\t数据类型\t逻辑地址\n'
      '一层到位\tBool\t%I0.0\n'
      'I0.7\tBool\t%I0.7\n'
      'Tag_3\tBool\t%I0.6';
  final n3 = importSymbolsInto(c, noCmt);
  ck('无注释列 条数', n3, 1);
  ck('名称兜底 I0.0', c['I0.0'], '一层到位');
  ck('自动名跳过 I0.7', c.containsKey('I0.7'), false);
  ck('Tag_3 跳过', c.containsKey('I0.6'), false);

  // ---------- 4. JSON 数组 ----------
  final d = <String, String>{};
  final js = jsonEncode([
    {'address': '%I0.0', 'comment': '一层到位', 'dataType': 'Bool'},
    {'logicalAddress': '%Q0.0', 'name': '上升按钮'},
    {'address': 'DB1.DBX0.0', 'comment': '主站通讯心跳'},
  ]);
  ck('JSON 条数', importSymbolsJsonInto(d, js), 3);
  ck('I0.0', d['I0.0'], '一层到位');
  ck('Q0.0 用 name', d['Q0.0'], '上升按钮');
  ck('DB1.DBX0.0', d['DB1.DBX0.0'], '主站通讯心跳');

  // ---------- 5. JSON 纯映射 / 嵌套 ----------
  final e = <String, String>{};
  ck('映射条数', importSymbolsJsonInto(e, '{"%I0.0":"一层到位","%M10.0":"手动模式"}'), 2);
  ck('M10.0', e['M10.0'], '手动模式');
  final f = <String, String>{};
  ck('嵌套条数',
      importSymbolsJsonInto(f, '{"tags":[{"address":"%I0.2","comment":"上升极限"}]}'), 1);
  ck('I0.2', f['I0.2'], '上升极限');

  // ---------- 6. 地址归一化：MD/MW/B 前缀都能对上同一块区域 ----------
  final g = <String, String>{};
  importSymbolsInto(g, '速度\tReal\t%MD10\t运行速度');
  ck('MD10 键', g.containsKey('MD10'), true);
  ck('normalize MD10', normalizeAddr('MD10'), 'MD10');
  ck('normalize %MW10', normalizeAddr('%MW10'), 'MW10');

  // ---------- 7. 异常输入不炸 ----------
  ck('空文本', importSymbolsInto(<String, String>{}, ''), 0);
  ck('垃圾 JSON', importSymbolsJsonInto(<String, String>{}, '{{{{'), 0);
  ck('JSON 空数组', importSymbolsJsonInto(<String, String>{}, '[]'), 0);

  print('\n通过 $pass 项，失败 $fail 项');
  if (fail > 0) throw StateError('有 $fail 项失败');
}
