/// 数据持久化与全局状态
///
/// 客户配置（设备 / 模板 / 变量注释）全部落在 SharedPreferences：
/// 覆盖安装升级时系统会保留同一个 applicationId 的数据，配置不丢。
/// 另外每次保存都会留一份快照（最近 3 份），误改或升级后可回滚。
library store;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';
import 's7_addr.dart';
import 'symbol_parse.dart';

class AppStore {
  AppStore._();
  static final AppStore instance = AppStore._();

  List<Template> templates = [];
  List<Device> devices = [];

  /// 地址（规范化后）→ 变量注释，来源于博图变量表粘贴
  Map<String, String> symbols = {};

  /// 被用户删掉的出厂模板 id —— 出厂模板每次启动都会补回列表，
  /// 靠这份名单记住「已经删过的」，避免删了又回来。
  final Set<String> removedBuiltins = {};

  /// 最近一次保存时间（底部状态用）
  DateTime? lastSavedAt;

  bool loaded = false;

  Future<void> load() async {
    if (loaded) return;
    final sp = await SharedPreferences.getInstance();
    final tRaw = sp.getString('templates');
    final dRaw = sp.getString('devices');
    final rbRaw = sp.getString('removedBuiltins');
    if (rbRaw != null) {
      try {
        removedBuiltins
          ..clear()
          ..addAll((jsonDecode(rbRaw) as List).map((e) => e.toString()));
      } catch (_) {}
    }
    templates = builtinTemplates
        .where((t) => !removedBuiltins.contains(t.id))
        .toList();
    if (tRaw != null) {
      final list = (jsonDecode(tRaw) as List)
          .map((e) => Template.fromJson(e as Map<String, dynamic>))
          .toList();
      // 用持久化的自定义/修改模板按 id 合并，保留内置模板
      for (final t in list) {
        if (removedBuiltins.contains(t.id) && isBuiltinTemplate(t.id)) continue;
        final i = templates.indexWhere((x) => x.id == t.id);
        if (i >= 0) {
          templates[i] = t;
        } else {
          templates.add(t);
        }
      }
    }
    if (dRaw != null) {
      devices = (jsonDecode(dRaw) as List)
          .map((e) => Device.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    final sRaw = sp.getString('symbols');
    if (sRaw != null) {
      symbols = (jsonDecode(sRaw) as Map).map(
          (k, v) => MapEntry(k as String, v as String));
    }
    final ts = sp.getInt('lastSavedAt');
    if (ts != null) lastSavedAt = DateTime.fromMillisecondsSinceEpoch(ts);
    await _migrate();
    loaded = true;
  }

  /// 老存档迁移 + 只读规则纠正。
  ///
  /// 1.8.2 及更早：案例只存「地址覆盖表」，点位挂在共享模板上 —— 改模板会连带改所有案例。
  /// 这里把模板点位深拷贝进案例（地址用当年填的覆盖值），从此彻底解耦：
  /// 删模板、改模板都不再影响已建案例。
  ///
  /// 同时按「I 区 / Q 区只读」规则纠正所有模板与案例的控件性质。
  Future<void> _migrate() async {
    var changed = false;
    for (final d in devices) {
      if (d.points.isEmpty) {
        final tpl = templates.where((t) => t.id == d.templateId).firstOrNull;
        if (tpl != null) {
          d.points = tpl.points.map((p) => p.clone()).toList();
          if (d.sourceTemplate.isEmpty) d.sourceTemplate = tpl.name;
          d.imagePath ??= tpl.imagePath;
          changed = true;
        }
      }
      if (d.legacyAddresses.isNotEmpty) {
        for (final p in d.points) {
          final a = d.legacyAddresses[p.id];
          if (a != null && a.trim().isNotEmpty) p.address = a.trim();
        }
        d.legacyAddresses = {};
        changed = true;
      }
      for (final p in d.points) {
        if (p.enforceReadOnlyRule()) changed = true;
      }
      // 1.9.0 起监控页改画布布局：老点位没有位置尺寸的，自动排布补齐
      if (d.points.any((p) =>
          p.type != PointType.image && (p.w <= 0 || p.x < 0 || p.y < 0))) {
        normalizeLayout(d.points);
        changed = true;
      }
    }
    for (final t in templates) {
      for (final p in t.points) {
        if (p.enforceReadOnlyRule()) changed = true;
      }
      if (t.points.any((p) =>
          p.type != PointType.image && (p.w <= 0 || p.x < 0 || p.y < 0))) {
        normalizeLayout(t.points);
        changed = true;
      }
    }
    if (!changed) return;
    // 启动期迁移不占用户的历史快照名额
    await _persistQuiet('devices', jsonEncode(devices.map((d) => d.toJson()).toList()));
    await _persistQuiet(
        'templates', jsonEncode(templates.map((t) => t.toJson()).toList()));
  }

  Future<void> _persistQuiet(String key, String value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(key, value);
  }

  /// 导入配置 / 回滚快照后手动调一次：给没有点位的案例从模板补副本，并纠正只读规则
  Future<void> normalizeAfterImport() => _migrate();

  Future<void> saveTemplates() async {
    await _persist('templates',
        jsonEncode(templates.map((t) => t.toJson()).toList()));
    await _persist('removedBuiltins', jsonEncode(removedBuiltins.toList()));
  }

  Future<void> saveDevices() =>
      _persist('devices', jsonEncode(devices.map((d) => d.toJson()).toList()));

  Future<void> saveSymbols() => _persist('symbols', jsonEncode(symbols));

  Future<void> saveAll() async {
    await saveTemplates();
    await saveDevices();
    await saveSymbols();
  }

  Future<void> _persist(String key, String value) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(key, value);
    lastSavedAt = DateTime.now();
    await sp.setInt('lastSavedAt', lastSavedAt!.millisecondsSinceEpoch);
    await _pushSnapshot(sp);
  }

  // ------------------------------------------------------------ 配置快照

  /// 完整配置序列化（快照与导出共用）
  String exportJson() => jsonEncode({
        'app': 'plc_monitor',
        'format': 2,
        'savedAt': DateTime.now().toIso8601String(),
        'templates': templates.map((t) => t.toJson()).toList(),
        'devices': devices.map((d) => d.toJson()).toList(),
        'symbols': symbols,
      });

  Future<void> _pushSnapshot(SharedPreferences sp) async {
    final raw = sp.getString('snapshots');
    final list = raw == null ? <dynamic>[] : (jsonDecode(raw) as List);
    list.insert(0, {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'data': exportJson(),
    });
    // 只留最近 3 份，避免无限增长
    while (list.length > 3) {
      list.removeLast();
    }
    await sp.setString('snapshots', jsonEncode(list));
  }

  /// 手动留一份快照（导入覆盖前调用，保证能回滚）
  Future<void> pushSnapshot() async {
    final sp = await SharedPreferences.getInstance();
    await _pushSnapshot(sp);
  }

  /// 可回滚的快照（时间倒序）
  Future<List<({DateTime time, String json})>> snapshots() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('snapshots');
    if (raw == null) return [];
    return (jsonDecode(raw) as List).map((e) {
      final m = e as Map<String, dynamic>;
      return (
        time: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
        json: m['data'] as String,
      );
    }).toList();
  }

  /// 从配置 JSON 恢复（快照回滚 / 导入都走这里）
  Future<bool> importJson(String raw) async {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final t = (j['templates'] as List?)
          ?.map((e) => Template.fromJson(e as Map<String, dynamic>))
          .toList();
      final d = (j['devices'] as List?)
          ?.map((e) => Device.fromJson(e as Map<String, dynamic>))
          .toList();
      final s = (j['symbols'] as Map?)?.map((k, v) => MapEntry(k as String, v as String));
      if (t == null || d == null) return false;
      templates = t;
      devices = d;
      symbols = s ?? {};
      await normalizeAfterImport();
      await saveAll();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 清空全部客户配置（恢复出厂）
  Future<void> resetAll() async {
    templates = List.from(builtinTemplates);
    devices = [];
    symbols = {};
    removedBuiltins.clear();
    await saveAll();
  }

  // ------------------------------------------------------------ 模板管理

  /// 是否出厂内置模板
  bool isBuiltinTemplate(String id) => builtinTemplates.any((t) => t.id == id);

  /// 有多少台设备正在用这个模板
  int devicesUsing(String templateId) =>
      devices.where((d) => d.templateId == templateId).length;

  /// 新建模板：不传 [copyFromId] 是空白模板，传了则复制该模板的全部点位与背景图
  Future<Template> createTemplate({String? copyFromId, String? name}) async {
    final now = DateTime.now();
    final stamp = now.millisecondsSinceEpoch.toString();
    Template t;
    if (copyFromId != null) {
      final src = templates.where((x) => x.id == copyFromId).firstOrNull;
      if (src == null) throw StateError('源模板不存在');
      t = Template(
        id: 'tpl_c_$stamp',
        name: name?.trim().isNotEmpty == true ? name!.trim() : '${src.name} 副本',
        desc: src.desc,
        imagePath: src.imagePath,
        points: src.points
            .map((p) => PointItem(
                  id: 'p_${stamp}_${p.id}',
                  name: p.name,
                  address: p.address,
                  type: p.type,
                  dataType: p.dataType,
                  visible: p.visible,
                  writable: p.writable,
                  comment: p.comment,
                ))
            .toList(),
      );
    } else {
      t = Template(
        id: 'tpl_c_$stamp',
        name: name?.trim().isNotEmpty == true ? name!.trim() : '自定义模板',
        desc: '自定义模板 · 0 点位',
        points: [],
      );
    }
    templates.add(t);
    await saveTemplates();
    return t;
  }

  /// 删除模板。
  ///
  /// 案例自带点位副本，所以删除模板**不会**影响任何已建案例，也不会删设备。
  /// · 出厂模板也允许删（记进 removedBuiltins，可在模板库恢复）
  Future<({bool ok, String msg})> deleteTemplate(String id,
      {bool force = false}) async {
    final t = templates.where((x) => x.id == id).firstOrNull;
    if (t == null) return (ok: false, msg: '模板已不存在');
    final wasBuiltin = isBuiltinTemplate(id);
    final used = devicesUsing(id);
    templates.removeWhere((x) => x.id == id);
    if (wasBuiltin) removedBuiltins.add(id);
    await saveTemplates();
    return (
      ok: true,
      msg: used > 0
          ? '已删除模板「${t.name}」，$used 个案例不受影响'
          : (wasBuiltin
              ? '已删除出厂模板「${t.name}」，可在模板库底部恢复'
              : '已删除模板「${t.name}」')
    );
  }

  /// 被删掉的出厂模板（模板库底部可一键恢复）
  List<Template> get removedBuiltinTemplates =>
      builtinTemplates.where((t) => removedBuiltins.contains(t.id)).toList();

  /// 把删掉的出厂模板恢复回列表（内容按出厂定义）
  Future<bool> restoreRemovedBuiltin(String id) async {
    if (!removedBuiltins.contains(id)) return false;
    removedBuiltins.remove(id);
    final ok = await restoreBuiltin(id);
    return ok;
  }

  /// 把内置模板恢复成出厂内容
  Future<bool> restoreBuiltin(String id) async {
    final src = builtinTemplates.where((t) => t.id == id).firstOrNull;
    if (src == null) return false;
    final i = templates.indexWhere((t) => t.id == id);
    final copy = Template(
      id: src.id,
      name: src.name,
      desc: src.desc,
      points: src.points
          .map((p) => PointItem(
                id: p.id,
                name: p.name,
                address: p.address,
                type: p.type,
                dataType: p.dataType,
                visible: p.visible,
                writable: p.writable,
                comment: p.comment,
              ))
          .toList(),
    );
    if (i >= 0) {
      templates[i] = copy;
    } else {
      templates.add(copy);
    }
    await saveTemplates();
    return true;
  }

  /// 单模板导出（可直接发给同事导入）
  String exportTemplateJson(Template t) => jsonEncode({
        'app': 'plc_monitor',
        'kind': 'template',
        'format': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'template': t.toJson(),
      });

  /// 导入模板：接受「单个模板对象」「模板数组」或带 template 字段的导出文件。
  /// 返回 (成功条数, 说明)
  ({int count, String msg}) _parseTemplateJson(String raw) {
    try {
      final data = jsonDecode(raw);
      final list = <dynamic>[];
      if (data is List) {
        list.addAll(data);
      } else if (data is Map && data['template'] is Map) {
        list.add(data['template']);
      } else if (data is Map && data['templates'] is List) {
        list.addAll(data['templates'] as List);
      } else if (data is Map) {
        list.add(data);
      } else {
        return (count: 0, msg: '文件格式不认识');
      }

      var n = 0;
      for (final e in list) {
        if (e is! Map) continue;
        final t = Template.fromJson(Map<String, dynamic>.from(e));
        // id 冲突时重新编号，避免覆盖已有模板
        if (templates.any((x) => x.id == t.id)) {
          final stamp = DateTime.now().millisecondsSinceEpoch.toString();
          t.id = 'tpl_c_${stamp}_$n';
          t.name = '${t.name}（导入）';
        }
        templates.add(t);
        n++;
      }
      if (n == 0) return (count: 0, msg: '没有解析到可用的模板');
      return (count: n, msg: '已导入 $n 个模板');
    } catch (e) {
      return (count: 0, msg: '解析失败：$e');
    }
  }

  /// 导入模板并落盘
  Future<({int count, String msg})> importTemplateJson(String raw) async {
    final r = _parseTemplateJson(raw);
    if (r.count > 0) await saveTemplates();
    return r;
  }

  // ------------------------------------------------------------ 查询

  /// 案例的来源模板（可能已被删除，返回 null 也不影响案例使用）
  Template? templateOf(Device d) {
    try {
      return templates.firstWhere((t) => t.id == d.templateId);
    } catch (_) {
      return null;
    }
  }

  /// 案例自己的点位
  List<PointItem> pointsOf(Device d) => d.points;

  /// 点位地址（案例自带地址；1.8.3 之后不再有「模板地址 + 设备覆盖」两层）
  String addrOf(Device d, PointItem p) => p.address;

  /// 从模板生成一份「案例草稿」（深拷贝，改草稿不影响模板）
  Template draftFromTemplate(Template t) => Template(
        id: t.id,
        name: t.name,
        desc: t.desc,
        imagePath: t.imagePath,
        points: t.points.map((p) => p.clone()).toList(),
      );

  /// 从已建案例生成草稿（编辑案例时用）
  Template draftFromDevice(Device d) => Template(
        id: d.templateId,
        name: d.sourceTemplate.isNotEmpty ? d.sourceTemplate : d.name,
        desc: '案例点位',
        imagePath: d.imagePath,
        points: d.points.map((p) => p.clone()).toList(),
      );

  /// 点位注释：先看点位自己填的，再查符号表映射
  String commentOf(PointItem p, {String? deviceAddress}) {
    if (p.comment.trim().isNotEmpty) return p.comment.trim();
    final key = normalizeAddr(deviceAddress ?? p.address);
    return symbols[key] ?? '';
  }

  // ------------------------------------------------------------ 符号表导入

  /// 解析从博图变量表粘贴过来的文本，返回成功识别的条数。
  /// 具体规则见 symbol_parse.dart（纯 Dart 实现，有单元测试覆盖）。
  int importSymbols(String text) => importSymbolsInto(symbols, text);

  /// 解析 JSON 变量表（address / name / comment），返回导入条数
  int importSymbolsJson(String text) => importSymbolsJsonInto(symbols, text);

  /// 自动识别：内容是 JSON 就走 JSON，否则按表格文本解析
  int importSymbolsAuto(String text) {
    final t = text.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) {
      final n = importSymbolsJson(text);
      if (n > 0) return n;
    }
    return importSymbols(text);
  }

  /// 统计：所有案例的点位里，已经能显示注释的个数 / 总数
  ({int matched, int total}) commentCoverage() {
    var matched = 0;
    var total = 0;
    for (final d in devices) {
      for (final p in d.points) {
        total++;
        if (commentOf(p, deviceAddress: p.address).isNotEmpty) matched++;
      }
    }
    return (matched: matched, total: total);
  }
}
