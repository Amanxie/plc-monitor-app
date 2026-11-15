/// 配置文件打包 / 解析 / 合并
///
/// 设计目标：
///   · 导出：把「模板 + 设备 + 变量注释 + 背景图」打成一个 .plccfg（内容仍是 JSON），
///     落到 App 外部文件目录后走系统分享面板发出去（微信/QQ/邮件都行）。
///   · 导入：任意位置的文件都能读（系统选文件走 SAF），也支持外部「用本应用打开」。
///   · 合并 / 覆盖：合并保留本机数据只追加；覆盖用对方配置替换本机（保留内置模板）。
///
/// 文件格式（format 3）：
///   { "app":"plc_monitor", "kind":"bundle", "format":3, "exportedAt":"...",
///     "deviceTag":"8890ADB7", "templates":[...], "devices":[...], "symbols":{...} }
/// 同时兼容：单模板（format 1）、旧快照（templates+devices，format 2）、裸模板对象 / 模板数组。
library config_io;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'models.dart';
import 'store.dart';

/// 兜底默认值：App 外部私有目录（adb 可读写）
const kDefaultFilesDir =
    '/storage/emulated/0/Android/data/com.example.plc_app/files';

/// 实际使用的文件目录：启动时由系统 API 提供（范围存储下硬编码路径可能拒绝创建）
String kAppFilesDir = kDefaultFilesDir;

/// 导出文件落盘目录
String get kConfigExportDir => '$kAppFilesDir/configs';

/// 背景图落地目录（导入别人模板时把内嵌图片写到这里）
String get kTemplateImageDir => '$kAppFilesDir/images';

/// 配置文件扩展名
const kConfigExt = 'plccfg';

// ---------------------------------------------------------------- 平台通道封装

class ConfigFileIo {
  ConfigFileIo._();
  static const _ch = MethodChannel('plc/fileio');
  static void Function(String name, String content)? _onIncoming;

  /// 启动时调用一次：向原生要真实的 App 外部文件目录，
  /// 拿不到就沿用默认硬编码路径
  static Future<void> init() async {
    try {
      final d = await _ch.invokeMethod<String>('filesDir');
      // ignore: avoid_print
      print('FILES init got="$d"');
      if (d != null && d.isNotEmpty) kAppFilesDir = d;
    } catch (e) {
      // ignore: avoid_print
      print('FILES init failed: $e');
    }
  }

  /// 注册「外部用本应用打开文件」的回调（热启动时由原生推过来）
  static void setIncomingHandler(void Function(String name, String content)? cb) {
    _onIncoming = cb;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'incomingFile') {
        final m = (call.arguments as Map?)?.cast<String, dynamic>();
        if (m != null) {
          _onIncoming?.call((m['name'] as String?) ?? '', (m['content'] as String?) ?? '');
        }
      }
      return null;
    });
  }

  /// 冷启动时取一次外部带进来的文件（取完即清）
  static Future<({String name, String content})?> takeIncoming() async {
    try {
      final r = await _ch.invokeMethod<Map>('getIncoming');
      if (r == null) return null;
      return (
        name: (r['name'] as String?) ?? '',
        content: (r['content'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 系统分享面板
  static Future<({bool ok, String msg})> share(String path,
      {String mime = 'application/json', String title = '分享 PLC 配置'}) async {
    try {
      final ok = await _ch.invokeMethod<bool>('shareFile', {
        'path': path,
        'mime': mime,
        'title': title,
      });
      return (ok: ok == true, msg: ok == true ? '已打开分享面板' : '分享未启动');
    } on PlatformException catch (e) {
      return (ok: false, msg: '分享失败：${e.message ?? e.code}');
    } catch (e) {
      return (ok: false, msg: '分享失败：$e');
    }
  }

  /// 系统选文件（能读下载、微信保存目录等任意位置）
  static Future<({String name, String content})?> pick() async {
    try {
      final r = await _ch.invokeMethod<Map>('pickFile', {'mime': 'application/json'});
      if (r == null) return null;
      return (
        name: (r['name'] as String?) ?? '',
        content: (r['content'] as String?) ?? '',
      );
    } on PlatformException catch (e) {
      // 交给上层提示
      throw Exception(e.message ?? e.code);
    }
  }
}

// ---------------------------------------------------------------- 导出选项

class ExportPick {
  /// 要导出的模板 id 集合
  final Set<String> templateIds;
  final bool devices;
  final bool symbols;
  final bool images;

  const ExportPick({
    required this.templateIds,
    this.devices = true,
    this.symbols = true,
    this.images = true,
  });

  bool get isEmpty => templateIds.isEmpty && !devices && !symbols;
}

/// 打包成一个 .plccfg 文本
String buildBundle(ExportPick pick, {String deviceTag = ''}) {
  final st = AppStore.instance;
  final tpls = <Map<String, dynamic>>[];
  for (final t in st.templates) {
    if (!pick.templateIds.contains(t.id)) continue;
    final m = t.toJson();
    if (pick.images && t.imagePath != null && t.imagePath!.isNotEmpty) {
      try {
        final f = File(t.imagePath!);
        if (f.existsSync()) {
          final bytes = f.readAsBytesSync();
          // 单图超过 6MB 不内嵌，避免文件过大发不出去
          if (bytes.length <= 6 * 1024 * 1024) {
            m['imageData'] = base64Encode(bytes);
          }
        }
      } catch (_) {}
    }
    tpls.add(m);
  }
  return const JsonEncoder.withIndent('  ').convert({
    'app': 'plc_monitor',
    'kind': 'bundle',
    'format': 3,
    'exportedAt': DateTime.now().toIso8601String(),
    'deviceTag': deviceTag,
    'templates': tpls,
    'devices': pick.devices ? st.devices.map((d) => d.toJson()).toList() : <dynamic>[],
    'symbols': pick.symbols ? st.symbols : <String, String>{},
  });
}

/// 写入导出目录，返回文件路径
Future<String> writeBundleFile(String content, {String? name}) async {
  final dir = Directory(kConfigExportDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
  final safe = (name ?? 'PLC配置_$stamp')
      .replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
  final f = File('${dir.path}/$safe.$kConfigExt');
  await f.writeAsString(content);
  return f.path;
}

// ---------------------------------------------------------------- 解析

class BundleInfo {
  final String sourceName;

  /// 3 = 完整配置包；1 = 单模板；2 = 旧版快照/导出
  final int format;
  final List<Map<String, dynamic>> rawTemplates;
  final List<Map<String, dynamic>> rawDevices;
  final Map<String, String> symbols;
  final String exportedAt;
  final String deviceTag;

  BundleInfo({
    required this.sourceName,
    required this.format,
    required this.rawTemplates,
    required this.rawDevices,
    required this.symbols,
    this.exportedAt = '',
    this.deviceTag = '',
  });

  int get templateCount => rawTemplates.length;
  int get deviceCount => rawDevices.length;
  int get symbolCount => symbols.length;
  int get imageCount => rawTemplates.where((t) {
        final d = t['imageData'];
        return d is String && d.isNotEmpty;
      }).length;

  /// 点数合计，导入确认框里给个直观量级
  int get pointCount => rawTemplates.fold(0, (a, t) {
        final p = t['points'];
        return a + (p is List ? p.length : 0);
      });

  String get summary {
    final parts = <String>[];
    if (templateCount > 0) parts.add('$templateCount 个模板（$pointCount 点位）');
    if (deviceCount > 0) parts.add('$deviceCount 台设备');
    if (symbolCount > 0) parts.add('$symbolCount 条变量注释');
    if (imageCount > 0) parts.add('$imageCount 张背景图');
    return parts.isEmpty ? '没有可导入的内容' : parts.join(' · ');
  }
}

/// 解析任意配置文件文本，识别不出来返回 null
BundleInfo? parseBundle(String raw, {String sourceName = ''}) {
  try {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final d = jsonDecode(trimmed);

    final rawTpls = <Map<String, dynamic>>[];
    final rawDevs = <Map<String, dynamic>>[];
    var symbols = <String, String>{};
    var format = 3;

    if (d is List) {
      // 裸模板数组
      for (final e in d) {
        if (e is Map) rawTpls.add(Map<String, dynamic>.from(e));
      }
      format = 1;
    } else if (d is Map) {
      final m = Map<String, dynamic>.from(d);
      if (m['template'] is Map) {
        rawTpls.add(Map<String, dynamic>.from(m['template'] as Map));
        format = 1;
      }
      if (m['templates'] is List) {
        for (final e in m['templates'] as List) {
          if (e is Map) rawTpls.add(Map<String, dynamic>.from(e));
        }
      }
      if (m['devices'] is List) {
        for (final e in m['devices'] as List) {
          if (e is Map) rawDevs.add(Map<String, dynamic>.from(e));
        }
      }
      if (m['symbols'] is Map) {
        symbols = (m['symbols'] as Map)
            .map((k, v) => MapEntry(k.toString(), v.toString()));
      }
      // 裸模板对象（有 points 没 templates）
      if (rawTpls.isEmpty && rawDevs.isEmpty && m['points'] is List) {
        rawTpls.add(m);
        format = 1;
      }
      if (m['kind'] == 'bundle') format = 3;
      if (m['kind'] == 'template') format = 1;
      if (m['kind'] == null && rawDevs.isNotEmpty) format = 2;
    } else {
      return null;
    }

    if (rawTpls.isEmpty && rawDevs.isEmpty && symbols.isEmpty) return null;

    return BundleInfo(
      sourceName: sourceName,
      format: format,
      rawTemplates: rawTpls,
      rawDevices: rawDevs,
      symbols: symbols,
      exportedAt: (d is Map ? d['exportedAt'] as String? : null) ?? '',
      deviceTag: (d is Map ? d['deviceTag'] as String? : null) ?? '',
    );
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- 合并 / 覆盖

class ImportResult {
  final int templates;
  final int devices;
  final int symbols;
  final int images;
  final int skipped;
  final String mode;

  const ImportResult({
    this.templates = 0,
    this.devices = 0,
    this.symbols = 0,
    this.images = 0,
    this.skipped = 0,
    this.mode = '合并',
  });

  String get message {
    if (templates == 0 && devices == 0 && symbols == 0) {
      return skipped > 0 ? '内容与本机完全一致，无需导入（跳过 $skipped 项）' : '没有可导入的内容';
    }
    final p = <String>[];
    if (templates > 0) p.add('$templates 个模板');
    if (devices > 0) p.add('$devices 台设备');
    if (symbols > 0) p.add('$symbols 条注释');
    if (images > 0) p.add('$images 张背景图');
    var s = '$mode完成：导入 ${p.join(' · ')}';
    if (skipped > 0) s += '（跳过 $skipped 项重复内容）';
    return s;
  }
}

bool _sameTemplate(Template a, Map<String, dynamic> raw) {
  if (a.name != (raw['name'] as String? ?? '')) return false;
  final pts = raw['points'];
  if (pts is! List || pts.length != a.points.length) return false;
  for (var i = 0; i < a.points.length; i++) {
    final p = pts[i];
    if (p is! Map) return false;
    if (a.points[i].address != (p['address'] as String? ?? '')) return false;
    if (a.points[i].name != (p['name'] as String? ?? '')) return false;
  }
  return true;
}

Future<String?> _saveImage(String tplId, String b64) async {
  try {
    final dir = Directory(kTemplateImageDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}/$tplId.jpg');
    await f.writeAsBytes(base64Decode(b64));
    return f.path;
  } catch (_) {
    return null;
  }
}

Template _templateFromRaw(Map<String, dynamic> raw, String? imagePath) {
  final clean = Map<String, dynamic>.from(raw)..remove('imageData');
  final t = Template.fromJson(clean);
  if (imagePath != null) t.imagePath = imagePath;
  return t;
}

/// 合并：保留本机现有配置，把导入内容追加进去（重复的跳过，冲突的重命名）
Future<ImportResult> applyMerge(BundleInfo b) async {
  final st = AppStore.instance;
  final idMap = <String, String>{};
  final stamp = DateTime.now().millisecondsSinceEpoch;
  var nTpl = 0, nSkip = 0, nImg = 0;

  for (final raw in b.rawTemplates) {
    final probe = _templateFromRaw(raw, null);
    final oldId = probe.id;
    final dup = st.templates.where((x) => x.id == oldId).toList();
    if (dup.isNotEmpty && _sameTemplate(dup.first, raw)) {
      idMap[oldId] = dup.first.id;
      nSkip++;
      continue;
    }
    final imgB64 = raw['imageData'] as String?;
    String? imgPath;
    if (imgB64 != null && imgB64.isNotEmpty) {
      imgPath = await _saveImage('${oldId}_$stamp', imgB64);
      if (imgPath != null) nImg++;
    }
    final t = _templateFromRaw(raw, imgPath);
    if (dup.isNotEmpty) {
      t.id = 'tpl_c_${stamp}_$nTpl';
      t.name = '${t.name}（导入）';
    }
    st.templates.add(t);
    idMap[oldId] = t.id;
    nTpl++;
  }

  var nDev = 0;
  for (final raw in b.rawDevices) {
    final d = Device.fromJson(raw);
    d.templateId = idMap[d.templateId] ?? d.templateId;
    final dup = st.devices.any((x) =>
        x.id == d.id || (x.name == d.name && x.ip == d.ip));
    if (dup) {
      d.id = 'dev_${stamp}_$nDev';
      d.name = '${d.name}（导入）';
    }
    st.devices.add(d);
    nDev++;
  }

  var nSym = 0;
  b.symbols.forEach((k, v) {
    if (st.symbols[k] != v) {
      st.symbols[k] = v;
      nSym++;
    }
  });

  await st.saveAll();
  return ImportResult(
      templates: nTpl, devices: nDev, symbols: nSym, images: nImg,
      skipped: nSkip, mode: '合并');
}

/// 覆盖：用导入配置替换本机（内置模板始终保留，它们属于 App 出厂内容）
Future<ImportResult> applyReplace(BundleInfo b) async {
  final st = AppStore.instance;
  // 覆盖前留一份快照，配置页可回滚
  await st.pushSnapshot();

  var nImg = 0;
  final imported = <Template>[];
  for (final raw in b.rawTemplates) {
    final imgB64 = raw['imageData'] as String?;
    String? imgPath;
    if (imgB64 != null && imgB64.isNotEmpty) {
      imgPath = await _saveImage(
          '${raw['id'] ?? 'tpl'}_${DateTime.now().millisecondsSinceEpoch}', imgB64);
      if (imgPath != null) nImg++;
    }
    imported.add(_templateFromRaw(raw, imgPath));
  }

  // 内置模板保留；导入的同 id 模板覆盖内置内容
  final kept = <Template>[];
  for (final bt in builtinTemplates) {
    final hit = imported.where((x) => x.id == bt.id).toList();
    kept.add(hit.isNotEmpty ? hit.first : bt);
  }
  for (final t in imported) {
    if (!kept.any((x) => x.id == t.id)) kept.add(t);
  }
  st.templates = kept;
  st.devices = b.rawDevices.map((e) => Device.fromJson(e)).toList();
  st.symbols = Map<String, String>.from(b.symbols);
  // 覆盖导入等于换成对方那套，之前删掉的出厂模板不再记着
  st.removedBuiltins.clear();

  await st.saveAll();
  return ImportResult(
      templates: imported.length,
      devices: st.devices.length,
      symbols: st.symbols.length,
      images: nImg,
      mode: '覆盖');
}
