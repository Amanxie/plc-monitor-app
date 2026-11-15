/// 博图变量表文本解析（纯 Dart，不依赖 Flutter，便于单测）
///
/// 输入：从博图「PLC 变量」表 Ctrl+A / Ctrl+C 复制的文本，或导出的 CSV。
/// 输出：地址 → 注释 的映射。
library;

import 'dart:convert';

import 's7_addr.dart';

/// 把 [text] 里的「地址 + 注释」合并进 [target]，返回成功识别条数。
///
/// 规则：
///   1. 有表头（含「逻辑地址」/「注释」）→ 按列名定位；
///   2. 无表头 → 每行自动找形如 I0.0 / MW10 / DB1.DBX0.0 的字段当地址，
///      取它右边第一个非地址字段当注释；右边没有就取左边。
int importSymbolsInto(Map<String, String> target, String text) {
  final lines = text.split(RegExp(r'\r?\n'));
  if (lines.isEmpty) return 0;

  int? addrCol;
  int? cmtCol;
  int? nameCol;
  for (final l in lines) {
    final f = splitFields(l);
    for (int i = 0; i < f.length; i++) {
      final c = f[i];
      final lc = c.toLowerCase();
      if (c.contains('逻辑地址') || lc == 'address' || lc.contains('logical')) {
        addrCol = i;
      }
      if (c.contains('注释') || lc.contains('comment')) cmtCol = i;
      if (c.trim() == '名称' || lc == 'name' || lc == 'tag' || lc == 'symbol') {
        nameCol = i;
      }
    }
    if (addrCol != null) break;
  }

  var n = 0;
  for (final l in lines) {
    if (l.trim().isEmpty) continue;
    final f = splitFields(l);
    int? ai = addrCol;
    if (ai == null || ai >= f.length || parseAddrSpec(f[ai]) == null) {
      ai = null;
      for (int i = 0; i < f.length; i++) {
        if (parseAddrSpec(f[i]) != null) {
          ai = i;
          break;
        }
      }
    }
    if (ai == null) continue;
    final key = normalizeAddr(f[ai]);
    if (key.isEmpty) continue;

    var cmt = '';
    if (cmtCol != null && cmtCol < f.length && cmtCol != ai) {
      cmt = stripQuotes(f[cmtCol]);
    }
    // 有明确的「名称」列时优先用名称（博图里符号名常就是中文描述）
    if (cmt.isEmpty && nameCol != null && nameCol < f.length && nameCol != ai) {
      final nm = stripQuotes(f[nameCol]);
      if (_isMeaningfulName(nm)) cmt = nm;
    }
    // 没有注释列 / 注释列为空 → 找同行里可读的文字字段
    if (cmt.isEmpty) {
      for (int i = ai + 1; i < f.length; i++) {
        final c = stripQuotes(f[i]);
        if (_isMeaningfulName(c)) {
          cmt = c;
          break;
        }
      }
    }
    if (cmt.isEmpty) {
      for (int i = 0; i < f.length; i++) {
        if (i == ai) continue;
        final c = stripQuotes(f[i]);
        if (_isMeaningfulName(c)) {
          cmt = c;
          break;
        }
      }
    }
    if (cmt.isEmpty) continue;
    target[key] = cmt;
    n++;
  }
  return n;
}

/// 变量名是否值得当注释用：排除地址原文（I0.0）、自动命名（Tag_1）、类型名
bool _isMeaningfulName(String s) {
  if (s.isEmpty) return false;
  if (parseAddrSpec(s) != null) return false;
  if (isTypeWord(s)) return false;
  if (RegExp(r'^(Tag|Variable|Var)_?\d+$', caseSensitive: false).hasMatch(s)) {
    return false;
  }
  // 纯 ASCII 且形似地址/编号的跳过；含中文或多词的可读名保留
  if (RegExp(r'^[A-Za-z]{1,2}\d+(\.\d+)?$').hasMatch(s)) return false;
  return true;
}

/// 解析 JSON 形式的变量表，合并进 [target]，返回导入条数。
///
/// 兼容三种常见结构：
///   · `[{"address":"%I0.0","comment":"一层到位","dataType":"Bool"}, ...]`
///   · `{"tags":[...]}` / `{"variables":[...]}` / `{"symbols":{...}}`
///   · `{"%I0.0":"一层到位"}` 纯映射
int importSymbolsJsonInto(Map<String, String> target, String text) {
  dynamic data;
  try {
    data = jsonDecode(text);
  } catch (_) {
    return 0;
  }
  final rows = <dynamic>[];
  if (data is List) {
    rows.addAll(data);
  } else if (data is Map) {
    final nested = data['tags'] ?? data['variables'] ?? data['symbols'] ?? data['items'];
    if (nested is List) {
      rows.addAll(nested);
    } else if (nested is Map) {
      data = nested;
    }
  }

  var n = 0;

  if (rows.isEmpty && data is Map) {
    // 纯 key-value 映射
    data.forEach((k, v) {
      final key = normalizeAddr('$k');
      final val = '$v'.trim();
      if (key.isNotEmpty && val.isNotEmpty && val != 'null') {
        target[key] = val;
        n++;
      }
    });
    return n;
  }

  for (final r in rows) {
    if (r is! Map) continue;
    final rawAddr = '${r['address'] ?? r['logicalAddress'] ?? r['addr'] ?? r['logical_address'] ?? ''}';
    final rawCmt = '${r['comment'] ?? r['commentZh'] ?? r['description'] ?? ''}'.trim();
    final rawName = '${r['name'] ?? r['tag'] ?? r['symbol'] ?? ''}'.trim();
    final key = normalizeAddr(rawAddr);
    if (key.isEmpty) continue;
    final text2 = rawCmt.isNotEmpty ? rawCmt : (_isMeaningfulName(rawName) ? rawName : '');
    if (text2.isEmpty) continue;
    target[key] = text2;
    n++;
  }
  return n;
}

/// 去博图 CSV 的引号包裹
String stripQuotes(String s) => s.replaceAll(RegExp(r'^"|"$'), '').trim();

/// 是否是数据类型名（用来在「注释在左」的行里跳过 Bool / Real 这类字段）
bool isTypeWord(String s) {
  const types = {
    'bool', 'byte', 'word', 'dword', 'int', 'dint', 'real', 'lreal',
    'char', 'string', 'wstring', 'time', 'date', 'sint', 'usint',
    'uint', 'udint', 'lint', 'ulint', 'timer', 'counter',
  };
  return types.contains(s.trim().toLowerCase());
}

/// 分隔：优先制表符，其次分号，最后逗号（支持 `"a,b"`）
List<String> splitFields(String line) {
  if (line.contains('\t')) return line.split('\t');
  if (line.contains(';')) return line.split(';');
  if (line.contains(',')) {
    final out = <String>[];
    final buf = StringBuffer();
    var quoted = false;
    for (final ch in line.split('')) {
      if (ch == '"') {
        quoted = !quoted;
      } else if (ch == ',' && !quoted) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    out.add(buf.toString());
    return out;
  }
  return [line];
}
