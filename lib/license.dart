/// 授权管理
///
/// 校验全部在 native 层（liblicense.so）完成：Dart 侧拿不到盐值，只能得到
/// 「通过 / 不通过」。v1.6.0 起是一码一机：校验码里掺了本机设备码，
/// 同一个授权码换到别的手机算不出匹配的校验码，直接拒绝。
library license;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------- FFI 绑定

typedef _VerifyNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _VerifyDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _SigNative = Int32 Function(Pointer<Utf8>);
typedef _SigDart = int Function(Pointer<Utf8>);
typedef _VerNative = Int32 Function();
typedef _VerDart = int Function();

/// native 授权库入口。库缺失时 [available] 为 false，界面据此提示而不是崩溃。
class LicenseNative {
  static DynamicLibrary? _lib;
  static bool tried = false;

  static DynamicLibrary? get lib {
    if (tried) return _lib;
    tried = true;
    try {
      _lib = DynamicLibrary.open('liblicense.so');
    } catch (_) {
      _lib = null;
    }
    return _lib;
  }

  static bool get available => lib != null;

  /// 一码一机校验：14 位码 + 本机设备码 → native 内算 MD5(编号+盐+设备码)
  static int verifyDev(String code, String device) {
    final l = lib;
    if (l == null) return 0;
    final fn = l.lookupFunction<_VerifyNative, _VerifyDart>('plc_license_verify_dev');
    final p1 = code.toNativeUtf8();
    final p2 = device.toNativeUtf8();
    try {
      return fn(p1, p2);
    } finally {
      malloc.free(p1);
      malloc.free(p2);
    }
  }

  static int sigOk(String hex) {
    final l = lib;
    if (l == null) return 0;
    final fn = l.lookupFunction<_SigNative, _SigDart>('plc_license_sig_ok');
    final p = hex.toNativeUtf8();
    try {
      return fn(p);
    } finally {
      malloc.free(p);
    }
  }

  static int version() {
    final l = lib;
    if (l == null) return -1;
    final fn = l.lookupFunction<_VerNative, _VerDart>('plc_license_version');
    return fn();
  }
}

// ---------------------------------------------------------------- 状态

class LicenseManager {
  LicenseManager._();
  static final LicenseManager instance = LicenseManager._();

  static const _kCode = 'lic_code';
  static const _kDevice = 'lic_device';
  static const _kAt = 'lic_at';

  /// 本机 ANDROID_ID
  String androidId = '';

  /// 本机安装包签名（SHA-256 大写十六进制）
  String signature = '';

  /// 签名是否与出厂基准一致（二次打包会被识别）
  bool signatureOk = false;

  String? _code;
  String? _boundDevice;
  DateTime? _activatedAt;

  /// 启动时用 native 对存根里的码重验一次（算法升级后旧码自动失效）
  bool _stubVerified = false;

  bool ready = false;

  /// 已激活：有存根 + 绑定设备与当前设备一致 + 签名正常 + 码能通过 native 重验
  bool get activated =>
      _code != null &&
      _boundDevice != null &&
      _boundDevice == androidId &&
      signatureOk &&
      _stubVerified;

  String? get code => _code;
  DateTime? get activatedAt => _activatedAt;

  /// 界面上展示的授权码（中间打码）
  String get maskedCode {
    final c = _code;
    if (c == null || c.length != 14) return '';
    return '${c.substring(0, 4)}****${c.substring(10)}';
  }

  /// 本机设备码：给售后核对用（ANDROID_ID 末 8 位，大写）
  String get deviceTag {
    if (androidId.isEmpty) return '--------';
    final s = androidId.replaceAll('-', '').toUpperCase();
    return s.length <= 8 ? s : s.substring(s.length - 8);
  }

  Future<void> init() async {
    try {
      const ch = MethodChannel('plc/license');
      try {
        androidId = await ch.invokeMethod<String>('androidId') ?? '';
      } catch (_) {
        androidId = '';
      }
      try {
        signature = await ch.invokeMethod<String>('signature') ?? '';
      } catch (_) {
        signature = '';
      }
      if (signature.isNotEmpty && LicenseNative.available) {
        signatureOk = LicenseNative.sigOk(signature) == 1;
      }

      final sp = await SharedPreferences.getInstance();
      _code = sp.getString(_kCode);
      _boundDevice = sp.getString(_kDevice);
      final ts = sp.getInt(_kAt);
      if (ts != null) _activatedAt = DateTime.fromMillisecondsSinceEpoch(ts);

      // 存根重验：码 + 当前设备码再过一遍 native 校验，
      // 老算法的码、被篡改的存根在这里都会被刷掉
      _stubVerified = false;
      final c = _code;
      if (c != null &&
          c.length == 14 &&
          LicenseNative.available &&
          signatureOk &&
          androidId.isNotEmpty &&
          _boundDevice == androidId) {
        _stubVerified = LicenseNative.verifyDev(c, deviceTag) == 1;
      }
    } catch (_) {
      // 任何一步异常都按「未激活」处理，绝不能卡死在加载页
    }
    ready = true;
  }

  /// 激活结果：ok 成功；msg 给用户看的说明
  Future<({bool ok, String msg})> activate(String raw) async {
    final input = raw.trim().toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (input.length != 14) {
      return (ok: false, msg: '授权码应为 14 位（8 位编号 + 6 位校验码），当前 ${input.length} 位');
    }
    if (!LicenseNative.available) {
      return (ok: false, msg: '授权组件加载失败，请重新安装完整版 App');
    }
    if (!signatureOk) {
      return (ok: false, msg: '安装包签名校验未通过，为保护软件授权已拒绝激活');
    }
    if (androidId.isEmpty) {
      return (ok: false, msg: '读不到本机设备标识，请检查系统权限后重试');
    }

    // 校验码：前 8 位 + 盐 + 本机设备码 → MD5 后 6 位（算法在 native 内）
    final pass = LicenseNative.verifyDev(input, deviceTag) == 1;
    if (!pass) {
      return (
        ok: false,
        msg: '校验码与本机设备码不匹配。授权码是按某台设备生成的，'
            '本机设备码是 $deviceTag，请把这个设备码发给供应商重新取码'
      );
    }

    // 已激活在别的设备上：本机首次激活时不做远端校验，但同一存根换了设备会被拦
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kCode, input);
    await sp.setString(_kDevice, androidId);
    final now = DateTime.now();
    await sp.setInt(_kAt, now.millisecondsSinceEpoch);
    _code = input;
    _boundDevice = androidId;
    _activatedAt = now;
    _stubVerified = true;
    return (ok: true, msg: '激活成功，本机已绑定');
  }

  /// 解除本机绑定（换机或返修后用同一个码重新激活）
  Future<void> unbind() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kCode);
    await sp.remove(_kDevice);
    await sp.remove(_kAt);
    _code = null;
    _boundDevice = null;
    _activatedAt = null;
  }

  /// 诊断信息（配置页展示）
  String get diagnostics {
    final buf = StringBuffer();
    buf.writeln('授权状态：${activated ? "已激活" : "未激活"}');
    if (_code != null) buf.writeln('授权码：$maskedCode');
    buf.writeln('本机设备码：$deviceTag');
    buf.writeln('签名校验：${signatureOk ? "通过" : "未通过"}');
    buf.writeln('授权组件：${LicenseNative.available ? "v${LicenseNative.version()}" : "未加载"}');
    if (_activatedAt != null) {
      final t = _activatedAt!;
      buf.writeln('激活时间：${t.year}/${t.month}/${t.day} '
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
    }
    return buf.toString().trimRight();
  }
}
