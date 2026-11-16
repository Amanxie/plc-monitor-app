import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 更新服务地址（Render 静态站）。更换域名只改这一处。
const String kUpdateBaseUrl = 'https://plc-monitor-xie.onrender.com';

/// 线上最新版本信息，对应 server/version.json
class ReleaseInfo {
  final String version;
  final int build;
  final String releasedAt;
  final String notes;
  final String apkUrl;
  final int size;
  final String sha256;
  final bool force;

  const ReleaseInfo({
    required this.version,
    required this.build,
    required this.releasedAt,
    required this.notes,
    required this.apkUrl,
    required this.size,
    required this.sha256,
    required this.force,
  });

  String get sizeText =>
      size <= 0 ? '' : '${(size / 1048576).toStringAsFixed(1)} MB';

  /// 文件名带构建号，避免不同版本互相覆盖
  String get fileName {
    final base = apkUrl.split('/').last;
    return base.isEmpty ? 'plc-monitor-$build.apk' : base;
  }
}

/// 更新结果：要么有新版本，要么无更新，要么出错（带可读原因）
class UpdateCheck {
  final ReleaseInfo? release;
  final String? error;
  const UpdateCheck.ok(this.release) : error = null;
  const UpdateCheck.fail(this.error) : release = null;
  bool get hasUpdate => release != null;
}

class UpdateService {
  static const MethodChannel _ch = MethodChannel('plc/fileio');

  /// 更新时段（北京时间，闭开区间）：10–12、14–16、21–23，每天共 6 小时。
  /// 其余时段 App 不检查、不下载更新，避免现场生产时被升级打断。
  static const List<int> _winStart = [10, 14, 21];
  static const List<int> _winEnd = [12, 16, 23];

  /// 服务器存的是 UTC，这里统一换算成北京时间再判断（不依赖手机时区设置）
  static DateTime beijingNow() =>
      DateTime.now().toUtc().add(const Duration(hours: 8));

  /// 当前是否在允许更新的时段内
  static bool inWindow([DateTime? at]) {
    final h = (at ?? beijingNow()).hour;
    for (var i = 0; i < _winStart.length; i++) {
      if (h >= _winStart[i] && h < _winEnd[i]) return true;
    }
    return false;
  }

  static String get windowLabel =>
      '每天 10:00–12:00、14:00–16:00、21:00–23:00（北京时间）';

  /// 给用户看的「下次什么时候能更新」
  static String nextWindowText([DateTime? at]) {
    final t = at ?? beijingNow();
    if (inWindow(t)) return '当前时段内，可正常检查更新';
    for (final s in _winStart) {
      if (t.hour < s) return '今天 ${s.toString().padLeft(2, '0')}:00 开放';
    }
    return '明天 10:00 开放';
  }

  /// 上次检查时间（节流，避免每次切页面都打服务器）
  static const String _kLastCheck = 'update_last_check_ms';
  static const String _kSkipBuild = 'update_skip_build';

  /// 拉取线上版本；[timeout] 兼顾免费实例冷启动
  static Future<UpdateCheck> check({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final uri = Uri.parse(
        '$kUpdateBaseUrl/version.json?t=${DateTime.now().millisecondsSinceEpoch}');
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) {
        return UpdateCheck.fail('服务器返回 ${resp.statusCode}');
      }
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      final map = jsonDecode(body) as Map<String, dynamic>;
      final rawNotes = map['notes'];
      final notes = rawNotes is List
          ? rawNotes.map((e) => '· $e').join('\n')
          : (rawNotes?.toString() ?? '');
      final apk = (map['apk'] ?? '').toString();
      final info = ReleaseInfo(
        version: (map['version'] ?? '').toString(),
        build: int.tryParse((map['build'] ?? '0').toString()) ?? 0,
        releasedAt: (map['releasedAt'] ?? '').toString(),
        notes: notes,
        apkUrl: apk.startsWith('http') ? apk : '$kUpdateBaseUrl/$apk',
        size: int.tryParse((map['size'] ?? '0').toString()) ?? 0,
        sha256: (map['sha256'] ?? '').toString(),
        force: map['force'] == true,
      );
      if (info.build <= 0) return const UpdateCheck.fail('版本信息格式不对');
      await _markChecked();
      return UpdateCheck.ok(info);
    } on TimeoutException {
      return const UpdateCheck.fail('连接超时（免费服务可能正在唤醒，稍后再试）');
    } on SocketException catch (e) {
      return UpdateCheck.fail('连不上服务器：${e.osError?.message ?? e.message}');
    } on FormatException {
      return const UpdateCheck.fail('版本信息解析失败');
    } catch (e) {
      return UpdateCheck.fail('检查失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  /// 距上次检查是否已超过 [hours] 小时
  static Future<bool> shouldAutoCheck({int hours = 6}) async {
    final sp = await SharedPreferences.getInstance();
    final last = sp.getInt(_kLastCheck) ?? 0;
    if (last == 0) return true;
    final gap = DateTime.now().millisecondsSinceEpoch - last;
    return gap > hours * 3600 * 1000;
  }

  static Future<void> _markChecked() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kLastCheck, DateTime.now().millisecondsSinceEpoch);
  }

  /// 用户选择「跳过此版本」
  static Future<void> skipBuild(int build) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kSkipBuild, build);
  }

  static Future<int> skippedBuild() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getInt(_kSkipBuild) ?? 0;
  }

  /// App 外部私有目录（范围存储下唯一可写且能交给安装器的位置）
  static Future<String> filesDir() async {
    final p = await _ch.invokeMethod<String>('filesDir');
    if (p == null || p.isEmpty) throw const FileSystemException('拿不到 App 文件目录');
    return p;
  }

  /// 下载 APK，返回本地路径。[onProgress] 参数为 0~1
  static Future<String> download(
    ReleaseInfo r, {
    void Function(double progress, int received, int total)? onProgress,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final dir = Directory('${await filesDir()}/update');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final target = File('${dir.path}/${r.fileName}');
    // 之前的版本包（含已装完没删掉的）先清掉，目录里只留本次要下的
    try {
      for (final f in dir.listSync()) {
        if (f is File &&
            f.path != target.path &&
            f.path.toLowerCase().endsWith('.apk')) {
          f.deleteSync();
        }
      }
    } catch (_) {}
    if (target.existsSync()) target.deleteSync();

    final client = HttpClient()..connectionTimeout = timeout;
    IOSink? sink;
    try {
      final req = await client.getUrl(Uri.parse(r.apkUrl)).timeout(timeout);
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) {
        throw HttpException('下载失败：HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength > 0 ? resp.contentLength : r.size;
      var received = 0;
      sink = target.openWrite();
      await for (final chunk in resp.timeout(timeout)) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call(received / total, received, total);
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (total > 0 && received < total) {
        throw const HttpException('下载不完整，请重试');
      }
      onProgress?.call(1, received, total > 0 ? total : received);
      return target.path;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      if (target.existsSync()) target.deleteSync();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// 拉起系统安装器。返回 'OK' 或 'NEED_PERMISSION'（已跳到授权页）
  static Future<String> install(String path) async {
    final r = await _ch.invokeMethod<String>('installApk', {'path': path});
    return r ?? '';
  }

  /// 清掉 update 目录里已经用过的安装包（装完几十 MB 不该留在手机上）。
  /// 返回删掉的个数。App 启动时调一次即可。
  static Future<int> cleanDownloaded() async {
    try {
      return await _ch.invokeMethod<int>('cleanUpdateApk') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 当前是否已有「安装未知应用」权限
  static Future<bool> canInstallApk() async {
    try {
      return await _ch.invokeMethod<bool>('canInstallApk') ?? false;
    } catch (_) {
      return false;
    }
  }
}
