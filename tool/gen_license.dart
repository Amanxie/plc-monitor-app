// 授权码生成 / 校验工具（只在开发机本地使用，不打包进 APK）
//
// v1.6.0 起：授权码与设备绑定（方案 A）
//   授权码 = 前 8 位编号 + MD5(编号 + 盐 + 设备码8位) 的后 6 位（大写十六进制）
//   设备码 = App 激活页显示的 8 位（ANDROID_ID 末 8 位，大写）
//
// 用法：
//   dart run tool/gen_license.dart 12345678 8890ADB7      给某台设备发码
//   dart run tool/gen_license.dart --check <14位码> 8890ADB7   校验
//   dart run tool/gen_license.dart --range 1 20 8890ADB7  批量（同一台设备）
//   dart run tool/gen_license.dart --batch list.csv       批量（每行 编号,设备码）
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 与 native 层（license.cpp）内的盐保持一致
const String kSalt = 'xiegongaigaozidonghua';

/// 设备码规范化：只留字母数字、转大写、取末 8 位（与 C++ normalizeDevice 一致）
String normalizeDevice(String raw) {
  final alnum = raw.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
  if (alnum.length < 8) {
    throw ArgumentError('设备码至少 8 位，当前「$raw」规范化后只有 ${alnum.length} 位');
  }
  return alnum.substring(alnum.length - 8);
}

/// 8 位编号 + 设备码 → MD5 后 6 位校验码
String checkCodeOf(String seed8, String device8) {
  final dev = normalizeDevice(device8);
  final digest = md5
      .convert(utf8.encode('${seed8.toUpperCase()}$kSalt$dev'))
      .toString()
      .toUpperCase();
  return digest.substring(26);
}

/// 生成 14 位授权码
String licenseOf(String seed8, String device8) {
  final s = seed8.trim();
  if (s.length != 8) {
    throw ArgumentError('编号必须是 8 位，当前 ${s.length} 位：$s');
  }
  if (!RegExp(r'^[0-9A-Za-z]{8}$').hasMatch(s)) {
    throw ArgumentError('编号只能包含数字和字母：$s');
  }
  final body = s.toUpperCase();
  return '$body${checkCodeOf(body, device8)}';
}

/// 校验 14 位授权码（等价于 App 内 native 的判断）
bool isValid(String code14, String device8) {
  final c = code14.trim().toUpperCase();
  if (c.length != 14) return false;
  return c == licenseOf(c.substring(0, 8), device8);
}

void _usage() {
  print('授权码生成器（一码一机）—— 谢工爱搞自动化 PLC 监控');
  print('');
  print('  gen_license <8位编号> <设备码8位>            生成单个');
  print('  gen_license --check <14位码> <设备码8位>     校验已有的码');
  print('  gen_license --range <起始> <数量> <设备码>   批量（同一台设备）');
  print('  gen_license --batch <csv文件>                批量（每行：编号,设备码）');
  print('');
  print('设备码在 App「激活页」显示（8 位大写，如 8890ADB7）。');
  print('');
  try {
    print('示例：12345678 + 8890ADB7 → ${licenseOf('12345678', '8890ADB7')}');
  } catch (_) {}
}

void main(List<String> args) {
  if (args.isEmpty) {
    _usage();
    return;
  }

  if (args[0] == '--check') {
    if (args.length < 3) {
      print('用法：--check <14位授权码> <设备码>');
      return;
    }
    final c = args[1].trim().toUpperCase();
    final dev = normalizeDevice(args[2]);
    print('授权码：$c');
    print('设备码：$dev');
    print('长度：${c.length} ${c.length == 14 ? '✓' : '✗（应为 14）'}');
    if (c.length == 14) {
      print('该设备期望校验码：${checkCodeOf(c.substring(0, 8), dev)}');
      print('授权码携带校验码：${c.substring(8)}');
    }
    print(isValid(c, dev) ? '结果：这台设备可以用 ✅' : '结果：这台设备不能用 ❌');
    return;
  }

  if (args[0] == '--range') {
    if (args.length < 4) {
      print('用法：--range <起始序号> <数量> <设备码>');
      return;
    }
    final start = int.tryParse(args[1]);
    final count = int.tryParse(args[2]);
    if (start == null || count == null || count <= 0) {
      print('序号与数量必须是正整数');
      return;
    }
    final dev = normalizeDevice(args[3]);
    print('设备码：$dev');
    print('序号\t编号\t授权码');
    for (var i = 0; i < count; i++) {
      final seed = 'A${(start + i).toString().padLeft(7, '0')}';
      print('${start + i}\t$seed\t${licenseOf(seed, dev)}');
    }
    return;
  }

  if (args[0] == '--batch') {
    if (args.length < 2) {
      print('用法：--batch <csv文件>（每行：8位编号,设备码）');
      return;
    }
    final f = File(args[1]);
    if (!f.existsSync()) {
      print('文件不存在：${args[1]}');
      return;
    }
    print('编号\t设备码\t授权码');
    for (final raw in f.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(RegExp(r'[,;\t ]+'));
      if (parts.length < 2) {
        print('$line\t跳过：需要「编号,设备码」两列');
        continue;
      }
      try {
        final dev = normalizeDevice(parts[1]);
        print('${parts[0]}\t$dev\t${licenseOf(parts[0], dev)}');
      } on ArgumentError catch (e) {
        print('$line\t跳过：${e.message}');
      }
    }
    return;
  }

  if (args.length < 2) {
    print('缺少设备码。一码一机模式必须提供用户 App 激活页显示的 8 位设备码。');
    print('用法：gen_license <8位编号> <设备码8位>');
    return;
  }

  try {
    final dev = normalizeDevice(args[1]);
    print('编号\t设备码\t授权码');
    print('${args[0]}\t$dev\t${licenseOf(args[0], dev)}');
  } on ArgumentError catch (e) {
    print('生成失败：${e.message}');
  }
}
