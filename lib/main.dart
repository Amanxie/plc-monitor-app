import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'license.dart';
import 'models.dart';
import 'plc_scan.dart';
import 's7_addr.dart';
import 'store.dart';
import 'comm_manager.dart';
import 'config_io.dart';
import 'update.dart';

/// 软件版本（底部展示，同时写入构建号）
const kAppVersion = '1.7.2';
const kAppBuild = '12';
const kBrand = '谢工爱搞自动化';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ConfigFileIo.init();
  runApp(const PlcApp());
}

// ------- 设计令牌（与设计稿一致） -------
const cBg = Color(0xFF141719);
const cCard = Color(0xFF1E2225);
const cCardDark = Color(0xFF101418);
const cLine = Color(0xFF2B3135);
const cAccent = Color(0xFF9EFF00);
const cAccentText = Color(0xFF11150F);
const cData = Color(0xFF22D3EE);
const cGreen = Color(0xFF4ADE80);
const cGreenDot = Color(0xFF22C55E);
const cAmber = Color(0xFFF5B841);
const cRed = Color(0xFFEF4444);
const cText = Color(0xFFF2F5F7);
const cSub = Color(0xFF8A949B);
const cDim = Color(0xFF6C767D);

class PlcApp extends StatelessWidget {
  const PlcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PLC 监控',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: cBg,
        colorScheme: const ColorScheme.dark(
          primary: cAccent,
          surface: cCard,
          onSurface: cText,
        ),
        fontFamily: 'Roboto',
      ),
      home: const LicenseGate(),
    );
  }
}

// ================== 授权闸门 ==================
/// 启动时先加载配置与授权状态：未激活先走激活页，激活后直接进首页。
class LicenseGate extends StatefulWidget {
  const LicenseGate({super.key});
  @override
  State<LicenseGate> createState() => _LicenseGateState();
}

class _LicenseGateState extends State<LicenseGate> {
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await LicenseManager.instance.init();
      await AppStore.instance.load();
    } catch (_) {
      // 出错也放行到激活页，由激活流程再拦
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2, color: cAccent)),
            SizedBox(height: 14),
            Text('正在校验授权…', style: TextStyle(fontSize: 11, color: cDim)),
          ]),
        ),
      );
    }
    if (!LicenseManager.instance.activated) {
      return ActivationScreen(onActivated: () => setState(() {}));
    }
    return const HomeScreen();
  }
}

// ================== 激活页 ==================
class ActivationScreen extends StatefulWidget {
  final VoidCallback? onActivated;
  const ActivationScreen({super.key, this.onActivated});
  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final codeC = TextEditingController();
  bool busy = false;
  String? err;
  String? okMsg;

  @override
  void dispose() {
    codeC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lm = LicenseManager.instance;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: cAccent.withValues(alpha: 0.10),
                  border: Border.all(color: cAccent.withValues(alpha: 0.35)),
                ),
                child: const Icon(Icons.verified_user_outlined, color: cAccent, size: 28),
              ),
              const SizedBox(height: 18),
              const Text('PLC 监控 · 授权激活',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: cText)),
              const SizedBox(height: 6),
              const Text('输入 14 位授权码完成本机激活',
                  style: TextStyle(fontSize: 12, color: cSub)),
              const SizedBox(height: 4),
              const Text('授权码按本机设备码生成，换机无效',
                  style: TextStyle(fontSize: 10.5, color: cDim)),
              const SizedBox(height: 22),
              TextField(
                controller: codeC,
                maxLength: 14,
                textAlign: TextAlign.center,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z]')),
                ],
                style: const TextStyle(
                    fontSize: 21, letterSpacing: 3, color: cText, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '00000000AAAAAA',
                  hintStyle: TextStyle(
                      fontSize: 18, letterSpacing: 3, color: cDim.withValues(alpha: 0.5)),
                  filled: true,
                  fillColor: cCardDark,
                  enabledBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: cLine),
                      borderRadius: BorderRadius.zero),
                  focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: cAccent), borderRadius: BorderRadius.zero),
                ),
                onChanged: (_) {
                  if (err != null) setState(() => err = null);
                },
              ),
              const SizedBox(height: 4),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('前 8 位编号 + 后 6 位校验码',
                    style: TextStyle(fontSize: 10.5, color: cDim)),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: busy ? null : _submit,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: cAccent,
                      foregroundColor: cAccentText,
                      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero)),
                  child: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: cAccentText))
                      : const Text('激 活',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ),
              if (err != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                      color: cRed.withValues(alpha: 0.10),
                      border: Border.all(color: cRed.withValues(alpha: 0.35))),
                  child: Text(err!, style: const TextStyle(fontSize: 11.5, color: cRed)),
                ),
              ],
              if (okMsg != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                      color: cGreen.withValues(alpha: 0.10),
                      border: Border.all(color: cGreen.withValues(alpha: 0.35))),
                  child: Text(okMsg!, style: const TextStyle(fontSize: 11.5, color: cGreen)),
                ),
              ],
              const SizedBox(height: 26),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(13),
                decoration: _box(cCard),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.smartphone, size: 14, color: cData),
                    const SizedBox(width: 8),
                    const Text('本机设备码',
                        style: TextStyle(fontSize: 11.5, color: cSub)),
                    const Spacer(),
                    Text(lm.deviceTag,
                        style: const TextStyle(
                            fontSize: 13,
                            color: cData,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.5)),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () async {
                        await Clipboard.setData(ClipboardData(text: lm.deviceTag));
                        if (!mounted) return;
                        setState(() => okMsg = '设备码已复制，发给管理员核对');
                      },
                      child: const Icon(Icons.copy, size: 13, color: cDim),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  const Text('一码一机：把上面的设备码发给供应商取码，换机需重新取码。',
                      style: TextStyle(fontSize: 10, color: cDim)),
                  if (!lm.signatureOk) ...[
                    const SizedBox(height: 6),
                    Text(
                        lm.signature.isEmpty
                            ? '未能读取签名信息'
                            : '安装包签名与官方基准不一致，激活将被拒绝',
                        style: const TextStyle(fontSize: 10, color: cAmber)),
                  ],
                ]),
              ),
              const SizedBox(height: 18),
              const _AppFooter(),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    setState(() => busy = true);
    final r = await LicenseManager.instance.activate(codeC.text);
    if (!mounted) return;
    setState(() {
      busy = false;
      if (r.ok) {
        okMsg = r.msg;
        err = null;
      } else {
        err = r.msg;
      }
    });
    if (r.ok) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      widget.onActivated?.call();
    }
  }
}

// ================== 首页：设备总览 ==================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _init();
    // 连接状态变化（含离开监控页自动断开）→ 立即刷新设备卡片
    CommManager.instance.onAnyChange(() {
      if (mounted) setState(() {});
    });
  }

  Future<void> _init() async {
    await AppStore.instance.load();
    if (mounted) setState(() {});
    _wireIncoming();
    _autoCheckUpdate();
  }

  /// 启动后静默检查一次更新（6 小时内不重复打服务器），有新版才弹提示
  Future<void> _autoCheckUpdate() async {
    try {
      if (!await UpdateService.shouldAutoCheck()) return;
      final res = await UpdateService.check();
      if (!mounted || !res.hasUpdate) return;
      final r = res.release!;
      final current = int.tryParse(kAppBuild) ?? 0;
      if (r.build <= current) return;
      if (r.build == await UpdateService.skippedBuild()) return;
      if (!mounted) return;
      await openUpdateSheet(context, preset: r, auto: true);
    } catch (_) {
      // 自动检查失败不打扰用户（无网络、服务器休眠等）
    }
  }

  /// 外部「用本应用打开」配置文件时，弹导入确认（合并 / 覆盖）
  Future<void> _wireIncoming() async {
    ConfigFileIo.setIncomingHandler((name, content) {
      if (mounted) _maybeImport(name, content);
    });
    final first = await ConfigFileIo.takeIncoming();
    if (first != null && mounted) {
      await _maybeImport(first.name, first.content);
    }
  }

  Future<void> _maybeImport(String name, String content) async {
    if (content.trim().isEmpty) return;
    final done = await showImportDialog(context, name, content);
    if (done && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final devices = AppStore.instance.devices;
    final online = devices
        .where((d) => CommManager.instance.st(d.id).state == ConnState.connected)
        .length;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('设备', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: cText)),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  tooltip: '检查更新',
                  icon: const Icon(Icons.system_update_alt, size: 18, color: cSub),
                  onPressed: () => openUpdateSheet(context),
                ),
                const SizedBox(width: 6),
                Text('$online/${devices.length} 在线',
                    style: const TextStyle(fontSize: 12, color: cDim)),
              ],
            ),
            const SizedBox(height: 14),
            _buildDeviceCards(devices),
            const SizedBox(height: 14),
            _AddDeviceTile(onTap: () => _openWizard(context)),
            const SizedBox(height: 20),
            Row(children: [
              const Text('模板管理',
                  style: TextStyle(fontSize: 12, color: cDim, letterSpacing: 1)),
              const Spacer(),
              Text('${AppStore.instance.templates.length} 个模板',
                  style: const TextStyle(fontSize: 10.5, color: cDim)),
            ]),
            const SizedBox(height: 10),
            _buildTemplateEntry(context),
            const SizedBox(height: 6),
            _buildConfigTile(context),
            const SizedBox(height: 18),
            const _AppFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCards(List<Device> devices) {
    if (devices.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: _box(cCard),
        child: const Center(
          child: Text('还没有设备，点击下方「新建设备」开始',
              style: TextStyle(fontSize: 12, color: cSub)),
        ),
      );
    }
    return Column(
      children: devices.map((d) => _buildDeviceCard(d)).toList(),
    );
  }

  Widget _buildDeviceCard(Device d) {
    final tpl = AppStore.instance.templateOf(d);
    final s = CommManager.instance.st(d.id);
    final (stText, stColor) = switch (s.state) {
      ConnState.connected => ('通讯正常', cGreen),
      ConnState.connecting => ('连接中', cAmber),
      ConnState.error => ('异常', cRed),
      _ => ('未连接', cDim),
    };
    final inputs = tpl?.points.where((p) => p.type == PointType.input && p.visible).toList() ?? [];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => _openMonitor(context, d),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: _box(cCard),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(d.name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cText))),
              _pill(stText, stColor),
              const SizedBox(width: 8),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '编辑设备',
                onPressed: () => _editDevice(context, d),
                icon: const Icon(Icons.tune, size: 18, color: cSub),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: '删除设备',
                onPressed: () => _deleteDevice(d),
                icon: const Icon(Icons.delete_outline, size: 18, color: cRed),
              ),
            ]),
            const SizedBox(height: 4),
            Text('${tpl?.name ?? '未知模板'} · ${_protoName(d.protocol)} · ${d.ip} · ${s.latencyMs}ms',
                style: const TextStyle(fontSize: 11, color: cDim)),
            const SizedBox(height: 10),
            if (inputs.isNotEmpty)
              Wrap(
                spacing: 6, runSpacing: 6,
                children: inputs.take(4).map((p) {
                  final on = s.isOn(p.id);
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                        color: cCardDark, borderRadius: BorderRadius.circular(4)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5),
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: on ? cGreenDot : const Color(0xFF3D464C))),
                      Text(p.name, style: TextStyle(
                          fontSize: 11, color: on ? cText : cSub)),
                    ]),
                  );
                }).toList(),
              ),
            if (s.state == ConnState.error)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(s.message, style: const TextStyle(fontSize: 11, color: cRed)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _buildTemplateEntry(BuildContext context) {
    final st = AppStore.instance;
    final builtin = st.templates.where((t) => st.isBuiltinTemplate(t.id)).length;
    final custom = st.templates.length - builtin;
    return InkWell(
      onTap: () {
        Navigator.push(context,
                MaterialPageRoute(builder: (_) => const TemplateLibraryScreen()))
            .then((_) {
          if (mounted) setState(() {});
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: _box(cCard),
        child: Row(children: [
          const Icon(Icons.dashboard_customize_outlined, size: 16, color: cAccent),
          const SizedBox(width: 10),
          const Expanded(
              child: Text('模板库 · 新建 / 复制 / 定制',
                  style: TextStyle(fontSize: 14, color: cText))),
          Text('内 $builtin · 自 $custom',
              style: const TextStyle(fontSize: 10.5, color: cDim)),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 16, color: cDim),
        ]),
      ),
    );
  }

  Widget _buildConfigTile(BuildContext context) {
    final st = AppStore.instance;
    final saved = st.lastSavedAt;
    final savedText = saved == null
        ? '尚未保存'
        : '已保存 ${saved.hour.toString().padLeft(2, '0')}:${saved.minute.toString().padLeft(2, '0')}';
    return InkWell(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const ConfigScreen()))
            .then((_) { if (mounted) setState(() {}); });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: _box(cCard),
        child: Row(children: [
          const Icon(Icons.tune, size: 16, color: cData),
          const SizedBox(width: 10),
          const Expanded(child: Text('客户配置 · 注释读取',
              style: TextStyle(fontSize: 14, color: cText))),
          Text('$savedText', style: const TextStyle(fontSize: 10.5, color: cDim)),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 16, color: cDim),
        ]),
      ),
    );
  }

  void _openWizard(BuildContext context) {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const WizardScreen()))
        .then((_) { if (mounted) setState(() {}); });
  }

  void _openMonitor(BuildContext context, Device d) {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => MonitorScreen(deviceId: d.id)))
        .then((_) { if (mounted) setState(() {}); });
  }

  Future<void> _editDevice(BuildContext context, Device d) async {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => WizardScreen(editDeviceId: d.id)))
        .then((_) { if (mounted) setState(() {}); });
  }

  /// 删除设备：先断通讯 → 删配置 → 底部提示（5 秒内可撤销）
  Future<void> _deleteDevice(Device d) async {
    final store = AppStore.instance;
    final idx = store.devices.indexWhere((x) => x.id == d.id);
    if (idx < 0) return;

    // 1. 断开该设备的连接与轮询，避免删了配置还在后台跑
    await CommManager.instance.disconnect(d);
    CommManager.instance.forget(d.id);

    // 2. 从配置里移除并落盘
    store.devices.removeAt(idx);
    await store.saveDevices();
    if (!mounted) return;
    setState(() {});

    // 3. 底部提示 + 撤销（防止误触，配置可原样恢复）
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      content: Text('已删除设备「${d.name}」'),
      duration: const Duration(seconds: 5),
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(
        label: '撤销',
        onPressed: () async {
          final pos = idx.clamp(0, store.devices.length);
          store.devices.insert(pos, d);
          await store.saveDevices();
          if (mounted) setState(() {});
        },
      ),
    ));
  }
}

// ================== 新建/编辑设备 向导 ==================
class WizardScreen extends StatefulWidget {
  final String? editDeviceId;
  const WizardScreen({super.key, this.editDeviceId});
  @override
  State<WizardScreen> createState() => _WizardScreenState();
}

class _WizardScreenState extends State<WizardScreen> {
  int step = 0;
  Template? selected;
  final nameCtrl = TextEditingController();
  final ipCtrl = TextEditingController(text: '192.168.0.1');
  final rackCtrl = TextEditingController(text: '0');
  final slotCtrl = TextEditingController(text: '1');
  /// pointId -> 地址文本（由地址编辑器生成，如 DB1.DBX0.3）
  final addrText = <String, String>{};
  /// pointId -> 变量注释
  final cmtText = <String, String>{};
  /// 向导内暂存的类型选择（点「完成」时才写回模板）
  final typeSel = <String, VarType>{};
  String plcType = 'S7-1200';
  Protocol protocol = Protocol.s7;
  Device? editing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await AppStore.instance.load();
    if (widget.editDeviceId != null) {
      editing = AppStore.instance.devices
          .where((d) => d.id == widget.editDeviceId)
          .firstOrNull;
      if (editing != null) {
        selected = AppStore.instance.templateOf(editing!);
        if (selected != null) {
          for (final p in selected!.points) {
            // 编辑设备时优先显示该设备已保存的地址，而不是模板默认地址
            addrText.putIfAbsent(p.id, () => editing!.addresses[p.id] ?? p.address);
            cmtText.putIfAbsent(p.id, () => p.comment);
            typeSel.putIfAbsent(p.id, () => p.dataType);
          }
        }
        nameCtrl.text = editing!.name;
        ipCtrl.text = editing!.ip;
        rackCtrl.text = editing!.rack.toString();
        slotCtrl.text = editing!.slot.toString();
        plcType = editing!.plcType;
        protocol = editing!.protocol;
        // 编辑已有案例：模板已定，直接进地址步，不再让用户重选模板
        step = 1;
      }
    }
    if (mounted) setState(() {});
  }

  /// 编辑模式：2 步（地址 → 通讯），新建模式：3 步（模板 → 地址 → 通讯）
  bool get isEdit => editing != null;
  int get pageCount => isEdit ? 2 : 3;
  int get pageIndex => (isEdit ? step - 1 : step).clamp(0, pageCount - 1);

  @override
  Widget build(BuildContext context) {
    final pages = isEdit
        ? [_stepAddress(), _stepComm()]
        : [_stepTemplate(), _stepAddress(), _stepComm()];
    final idx = pageIndex;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cBg,
        foregroundColor: cText,
        elevation: 0,
        title: Text(isEdit ? '编辑设备' : '新建监控',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          Center(child: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text('步骤 ${idx + 1} / $pageCount',
                style: const TextStyle(fontSize: 12, color: cDim)),
          )),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(children: [
              for (int i = 0; i < pageCount; i++)
                Expanded(child: Container(height: 3, margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(color: i <= idx ? cAccent : cLine, borderRadius: BorderRadius.circular(2)))),
            ]),
          ),
          Expanded(child: pages[idx]),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Row(children: [
              if (idx > 0)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: cLine),
                      minimumSize: const Size(96, 52),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
                  onPressed: () => setState(() => step--),
                  child: const Text('上一步', style: TextStyle(color: cSub)),
                ),
              const SizedBox(width: 10),
              Expanded(child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: cAccent, foregroundColor: cAccentText,
                    minimumSize: const Size(0, 52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
                onPressed: _next,
                child: Text(
                    isEdit
                        ? (idx == pageCount - 1 ? '保存修改' : '下一步')
                        : (step < 2 ? '下一步' : '完成并进入监控'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              )),
            ]),
          ),
        ]),
      ),
    );
  }

  // ---- 步骤 1：选模板 ----
  Widget _stepTemplate() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('选择设备模板', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: cText)),
        const SizedBox(height: 6),
        const Text('模板内置点位定义与控件布局，下一步可编辑 PLC 地址',
            style: TextStyle(fontSize: 12, color: cSub)),
        const SizedBox(height: 16),
        ...AppStore.instance.templates.map((t) {
          final sel = selected?.id == t.id;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: () => setState(() {
                selected = t;
                for (final p in t.points) {
                  addrText.putIfAbsent(p.id, () => p.address);
                  cmtText.putIfAbsent(p.id, () => p.comment);
                  typeSel.putIfAbsent(p.id, () => p.dataType);
                }
              }),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: sel ? const Color(0xFF1C241A) : cCard,
                  border: Border.all(color: sel ? cAccent : cLine, width: sel ? 1.5 : 1),
                ),
                child: Row(children: [
                  Icon(sel ? Icons.settings_input_component : Icons.grid_view,
                      color: sel ? cAccent : cSub, size: 22),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cText)),
                    const SizedBox(height: 3),
                    Text('${t.desc} · ${t.points.length} 点位',
                        style: const TextStyle(fontSize: 11, color: cSub)),
                  ])),
                  Icon(sel ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: sel ? cAccent : const Color(0xFF3D464C), size: 20),
                ]),
              ),
            ),
          );
        }),
      ],
    );
  }

  // ---- 步骤 2：编辑地址 ----
  Widget _stepAddress() {
    if (selected == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('该设备的模板已不存在，请重新选择模板',
              style: TextStyle(fontSize: 13, color: cSub)),
          const SizedBox(height: 10),
          OutlinedButton(
            style: OutlinedButton.styleFrom(side: const BorderSide(color: cLine)),
            onPressed: _pickTemplate,
            child: const Text('选择模板', style: TextStyle(color: cData)),
          ),
        ]),
      );
    }
    final pts = selected!.points.where((p) => p.type != PointType.image).toList();
    final inputs = pts.where((p) => !p.isOutput).toList();
    final outputs = pts.where((p) => p.isOutput).toList();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(children: [
          const Expanded(child: Text('编辑点位地址',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: cText))),
          if (isEdit)
            TextButton.icon(
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 34)),
              onPressed: _pickTemplate,
              icon: const Icon(Icons.swap_horiz, size: 15, color: cSub),
              label: const Text('更换模板',
                  style: TextStyle(fontSize: 11.5, color: cSub)),
            ),
        ]),
        const SizedBox(height: 6),
        Text('${selected!.name} · ${pts.length} 个点位 · 先选区域与类型，再在方框里填编号',
            style: const TextStyle(fontSize: 12, color: cSub)),
        const SizedBox(height: 16),
        _addrGroup('输入信号 · 状态显示（BOOL 可在操作栏写入 0/1）', inputs),
        const SizedBox(height: 14),
        _addrGroup('输出按钮 · 按下运行 松开停止', outputs),
      ],
    );
  }

  /// 编辑模式下更换模板：地址能对上的沿用，对不上的用新模板默认地址
  Future<void> _pickTemplate() async {
    final picked = await showModalBottomSheet<Template>(
      context: context,
      backgroundColor: cCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(10))),
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: const BoxConstraints(maxHeight: 460),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Text('更换模板',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cText)),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消', style: TextStyle(fontSize: 12, color: cSub)),
              ),
            ]),
            const SizedBox(height: 4),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: AppStore.instance.templates.map((t) {
                  final sel = selected?.id == t.id;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () => Navigator.pop(ctx, t),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: sel ? const Color(0xFF1C241A) : cBg,
                          border: Border.all(color: sel ? cAccent : cLine),
                        ),
                        child: Row(children: [
                          Icon(sel ? Icons.check_circle : Icons.grid_view,
                              color: sel ? cAccent : cSub, size: 18),
                          const SizedBox(width: 10),
                          Expanded(child: Text('${t.name} · ${t.points.length} 点位',
                              style: const TextStyle(fontSize: 13, color: cText))),
                        ]),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ]),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      selected = picked;
      for (final p in picked.points) {
        if (p.type == PointType.image) continue;
        // 同一 id 的点位沿用设备已保存地址，其余用新模板默认值
        addrText[p.id] = editing?.addresses[p.id] ?? p.address;
        cmtText.putIfAbsent(p.id, () => p.comment);
        typeSel[p.id] = p.dataType;
      }
    });
  }

  Widget _addrGroup(String title, List<PointItem> pts) {
    if (pts.isEmpty) return const SizedBox();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
      const SizedBox(height: 8),
      ...pts.map((p) {
        final addr = addrText.putIfAbsent(p.id, () => p.address);
        final cmt = cmtText.putIfAbsent(p.id, () => p.comment);
        final t = typeSel[p.id] ?? p.dataType;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: _box(cCard),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                        color: Color(0xFFD9E0E4)))),
                const SizedBox(width: 6),
                _TypeButton(
                  value: t,
                  width: 74,
                  onChanged: (nt) => setState(() {
                    typeSel[p.id] = nt;
                    addrText[p.id] = addrFromText(addrText[p.id] ?? p.address, nt);
                  }),
                ),
              ]),
              const SizedBox(height: 8),
              AddressField(
                key: ValueKey('${selected!.id}_${p.id}_${t.name}'),
                initial: addr,
                type: t,
                onChanged: (a) => addrText[p.id] = a,
              ),
              const SizedBox(height: 8),
              _CommentField(
                initial: cmt,
                hint: (AppStore.instance.symbols[normalizeAddr(addr)] ?? '').isEmpty
                    ? '变量注释（选填，显示在地址后）'
                    : '留空则用符号表：${AppStore.instance.symbols[normalizeAddr(addr)]}',
                onChanged: (v) => cmtText[p.id] = v,
              ),
            ]),
          ),
        );
      }),
    ]);
  }

  // ---- 步骤 3：通讯配置 ----
  Widget _stepComm() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('选择 PLC 与通讯协议', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: cText)),
        const SizedBox(height: 16),
        const Text('设备名称', style: TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
        const SizedBox(height: 8),
        TextField(
          controller: nameCtrl,
          style: const TextStyle(fontSize: 14, color: cText),
          decoration: _inputDeco('如：1# 升降机'),
        ),
        const SizedBox(height: 16),
        const Text('PLC 类型（可扩展）', style: TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
        const SizedBox(height: 8),
        Wrap(spacing: 7, runSpacing: 7, children: ['S7-1200', 'S7-1500', 'S7-300', '其他'].map((t) {
          final sel = plcType == t;
          return InkWell(onTap: () => setState(() => plcType = t), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
                color: sel ? cAccent : cCard,
                border: Border.all(color: sel ? cAccent : cLine),
                borderRadius: BorderRadius.circular(4)),
            child: Text(t, style: TextStyle(
                fontSize: 12, color: sel ? cAccentText : cSub,
                fontWeight: sel ? FontWeight.w600 : FontWeight.w400)),
          ));
        }).toList()),
        const SizedBox(height: 16),
        const Text('通讯协议', style: TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8, crossAxisSpacing: 8,
          childAspectRatio: 2.6,
          children: [
            _protoCard(Protocol.s7, 'S7', '推荐 · 西门子以太网'),
            _protoCard(Protocol.modbusTcp, 'Modbus TCP', '第三方设备通用'),
            _protoCard(Protocol.plcsim, 'PLCSIM', '博图仿真环境'),
            _protoCard(Protocol.opcua, 'OPC UA', '后续版本支持'),
          ],
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('IP 地址', style: TextStyle(fontSize: 11, color: cDim)),
            const SizedBox(height: 6),
            TextField(controller: ipCtrl, style: const TextStyle(fontSize: 13, color: cData),
                keyboardType: TextInputType.number, decoration: _inputDeco('')),
          ])),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('机架 / 槽位', style: TextStyle(fontSize: 11, color: cDim)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: TextField(controller: rackCtrl, keyboardType: TextInputType.number,
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: cData),
                  decoration: _inputDeco(''))),
              const SizedBox(width: 6),
              Expanded(child: TextField(controller: slotCtrl, keyboardType: TextInputType.number,
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: cData),
                  decoration: _inputDeco(''))),
            ]),
          ])),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              final prefix = subnetPrefix(ipCtrl.text.trim());
              if (prefix.isEmpty) {
                _toast('先填一个完整 IP，如 192.168.0.1');
                return;
              }
              final hit = await showPlcScanner(context, prefix: prefix);
              if (hit == null || !mounted) return;
              setState(() {
                ipCtrl.text = hit.ip;
                if (hit.tsap == 0x0301) {
                  rackCtrl.text = '0';
                  slotCtrl.text = '1';
                }
              });
            },
            icon: const Icon(Icons.radar, size: 15, color: cData),
            label: const Text('扫描同网段的 PLC，自动填地址',
                style: TextStyle(fontSize: 11.5, color: cData)),
          ),
        ),
        if (protocol == Protocol.plcsim)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: _box(const Color(0xFF241F14), borderColor: const Color(0xFF453B22)),
              child: const Text('PLCSIM 提示：需使用 PLCSIM Advanced（虚拟以太网），经典 PLCSIM 不开放 TCP 102 端口。',
                  style: TextStyle(fontSize: 11, color: cAmber)),
            ),
          ),
        if (protocol == Protocol.opcua)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: _box(const Color(0xFF241F14), borderColor: const Color(0xFF453B22)),
              child: const Text('OPC UA 驱动将在后续版本提供，当前请选择 S7 / Modbus TCP / PLCSIM。',
                  style: TextStyle(fontSize: 11, color: cAmber)),
            ),
          ),
      ],
    );
  }

  Widget _protoCard(Protocol p, String name, String desc) {
    final sel = protocol == p;
    return InkWell(
      onTap: () => setState(() => protocol = p),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: sel ? const Color(0xFF1C241A) : cCard,
            border: Border.all(color: sel ? cAccent : cLine, width: sel ? 1.5 : 1)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(name, style: TextStyle(fontSize: 14,
              fontWeight: FontWeight.w600, color: sel ? cText : const Color(0xFFD9E0E4))),
          const SizedBox(height: 3),
          Text(desc, style: TextStyle(fontSize: 10,
              color: sel ? cAccent : cDim)),
        ]),
      ),
    );
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
        hintText: hint, hintStyle: const TextStyle(fontSize: 12, color: cDim),
        isDense: true, filled: true, fillColor: cCardDark,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: cLine)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: cAccent)),
      );

  Future<void> _next() async {
    if (step == 0) {
      if (selected == null) {
        _toast('请先选择一个模板');
        return;
      }
      for (final p in selected!.points.where((x) => x.type != PointType.image)) {
        addrText.putIfAbsent(p.id, () => p.address);
        cmtText.putIfAbsent(p.id, () => p.comment);
        typeSel.putIfAbsent(p.id, () => p.dataType);
      }
      setState(() => step = 1);
      return;
    }
    if (step == 1) {
      setState(() => step = 2);
      return;
    }
    // step 2：保存设备
    if (nameCtrl.text.trim().isEmpty) { _toast('请填写设备名称'); return; }
    if (selected == null) { _toast('该设备没有绑定模板，请先选择模板'); return; }
    final messenger = ScaffoldMessenger.of(context);
    final d = editing ??
        Device(id: 'dev_${DateTime.now().millisecondsSinceEpoch}',
            name: '', templateId: '');
    d.name = nameCtrl.text.trim();
    d.templateId = selected!.id;
    d.plcType = plcType;
    d.protocol = protocol;
    d.ip = ipCtrl.text.trim();
    d.rack = int.tryParse(rackCtrl.text) ?? 0;
    d.slot = int.tryParse(slotCtrl.text) ?? 1;
    d.addresses = {};
    for (final p in selected!.points) {
      final a = addrText[p.id];
      if (a != null && a.trim().isNotEmpty) {
        d.addresses[p.id] = a.trim();
      }
      // 注释：点位自己填的写进模板，符号表来的不覆盖
      final cm = cmtText[p.id];
      if (cm != null) p.comment = cm.trim();
      // 类型写回模板（类型是模板属性，同模板的设备共用）
      final t = typeSel[p.id];
      if (t != null) p.dataType = t;
    }
    if (editing == null) {
      AppStore.instance.devices.add(d);
    }
    await AppStore.instance.saveDevices();
    await AppStore.instance.saveTemplates();
    CommManager.instance.st(d.id).state = ConnState.disconnected;
    if (!mounted) return;
    if (isEdit) {
      // 编辑已有案例：保存后回到设备列表，不强制进监控页
      messenger.showSnackBar(SnackBar(
          content: Text('已保存「${d.name}」的修改'),
          backgroundColor: cCard,
          duration: const Duration(seconds: 2)));
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => MonitorScreen(deviceId: d.id)));
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: cCard, duration: const Duration(seconds: 2)));
  }
}

// ================== 监控操作界面 ==================
class MonitorScreen extends StatefulWidget {
  final String deviceId;
  const MonitorScreen({super.key, required this.deviceId});
  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  Device? d;
  Template? tpl;
  bool connecting = false;

  @override
  void initState() {
    super.initState();
    _load();
    CommManager.instance.onChange(widget.deviceId, _refresh);
  }

  void _refresh() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    // 离开监控页（返回设备列表等）：停止该案例的通讯，不再后台轮询
    final dd = d;
    if (dd != null) CommManager.instance.disconnect(dd);
    super.dispose();
  }

  Future<void> _load() async {
    await AppStore.instance.load();
    d = AppStore.instance.devices.where((x) => x.id == widget.deviceId).firstOrNull;
    tpl = d == null ? null : AppStore.instance.templateOf(d!);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (d == null || tpl == null) {
      return const Scaffold(body: Center(child: Text('设备不存在', style: TextStyle(color: cSub))));
    }
    final s = CommManager.instance.st(d!.id);
    final visible = tpl!.points.where((p) => p.visible).toList();
    // 状态信号栏：输入点位，只读显示
    final inputs = visible.where((p) => p.type == PointType.input).toList();
    // 操作栏·点动：按钮属性（输出）且 BOOL —— 按下置 1、松开置 0
    final jogs = visible
        .where((p) => p.type == PointType.output && p.dataType.isBit)
        .toList();
    // 操作栏·写入：非按钮的 BOOL 输入域（自行写 0/1）+ 所有数值类型点位
    final writes = visible
        .where((p) =>
            (p.type == PointType.input && p.dataType.isBit) ||
            p.dataType.isNumeric)
        .toList();
    final connected = s.state == ConnState.connected;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: cBg, foregroundColor: cText, elevation: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(d!.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          Text('${d!.plcType} · ${_protoName(d!.protocol)} · ${d!.ip}',
              style: const TextStyle(fontSize: 10, color: cDim)),
        ]),
        actions: [
          if (s.state == ConnState.connected || s.state == ConnState.connecting)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: TextButton.icon(
                onPressed: () => CommManager.instance.disconnect(d!),
                icon: const Icon(Icons.link_off, size: 15, color: cDim),
                label: const Text('断开连接',
                    style: TextStyle(fontSize: 12, color: cDim)),
              ),
            ),
          Padding(padding: const EdgeInsets.only(right: 16),
            child: Center(child: _pill(connected ? '通讯正常' : (s.state == ConnState.connecting ? '连接中' : (s.state == ConnState.error ? '异常' : '未连接')),
                connected ? cGreen : (s.state == ConnState.error ? cRed : (s.state == ConnState.connecting ? cAmber : cDim))))),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (s.state != ConnState.connected && s.message != '未连接')
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(s.message, style: const TextStyle(fontSize: 12, color: cAmber)),
              ),
            if (tpl!.imagePath != null && File(tpl!.imagePath!).existsSync())
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: Image.file(File(tpl!.imagePath!), fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (_, __, ___) => const SizedBox()),
                  ),
                ),
              ),
            if (connected) ...[
              if (inputs.isNotEmpty) ...[
                const Text('状态信号 · 只读显示，实时刷新',
                    style: TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
                const SizedBox(height: 8),
                GridView.count(
                  crossAxisCount: 2, shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 2.5,
                  children: inputs.map((p) {
                    final on = s.isOn(p.id);
                    final addr = AppStore.instance.addrOf(d!, p);
                    final val = formatVarValue(p.dataType, s.values[p.id]);
                    return Container(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      decoration: _box(cCard),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(children: [
                            Container(width: 6, height: 6,
                                decoration: BoxDecoration(shape: BoxShape.circle,
                                    color: on ? cGreenDot : const Color(0xFF3D464C))),
                            const SizedBox(width: 6),
                            Expanded(child: Text(p.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12,
                                    color: on ? cText : cSub))),
                            const SizedBox(width: 4),
                            Text(val,
                                style: TextStyle(
                                    fontSize: p.dataType.isBit ? 13 : 12,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                    color: p.dataType.isBit
                                        ? (on ? cGreen : const Color(0xFF5C6A72))
                                        : cData)),
                          ]),
                          const SizedBox(height: 3),
                          Text(
                              _addrLine(addr, p.dataType,
                                  AppStore.instance.commentOf(p, deviceAddress: addr)),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 9,
                                  fontFamily: 'monospace', color: cDim)),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],
              if (jogs.isNotEmpty) ...[
                const Text('点动操作 · 按下置 1，松开置 0',
                    style: TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
                const SizedBox(height: 8),
                GridView.count(
                  crossAxisCount: 2, shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 2.8,
                  children: jogs.map((p) => JogButton(device: d!, point: p)).toList(),
                ),
                const SizedBox(height: 16),
              ],
              if (writes.isNotEmpty) ...[
                const Text('点位写入 · BOOL 点 0/1，数值点输数值',
                    style: TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
                const SizedBox(height: 8),
                ...writes.map((p) => WriteTile(
                      device: d!,
                      point: p,
                      current: s.values[p.id],
                    )),
                const SizedBox(height: 2),
                const Text('提示：I 区是过程映像输入，多数 PLC 不允许写入；M / DB 区可写。',
                    style: TextStyle(fontSize: 9.5, color: cDim)),
              ],
            ] else
              _buildConnectPanel(s),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: _box(const Color(0xFF171B1E), borderColor: const Color(0xFF262C30)),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded, size: 16, color: cAmber),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  '安全提示：松开按钮立即向 PLC 写入 OFF，设备即刻停止。正反转按钮请勿同时按住，同一时刻仅允许一个方向输出。',
                  style: const TextStyle(fontSize: 10.5, color: cSub),
                )),
              ]),
            ),
            const SizedBox(height: 14),
            const _AppFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectPanel(DeviceStatus s) {
    final failed = s.state == ConnState.error;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _box(cCard),
      child: Column(children: [
        Icon(failed ? Icons.link_off : Icons.link,
            size: 36, color: failed ? cRed : cDim),
        const SizedBox(height: 10),
        Text(s.state == ConnState.connecting ? '正在连接 ${d!.ip} …' : s.message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: cSub)),
        const SizedBox(height: 6),
        Text('当前地址 ${d!.ip}:${d!.port} · 机架 ${d!.rack} / 槽位 ${d!.slot}',
            style: const TextStyle(fontSize: 10, color: cDim)),
        const SizedBox(height: 16),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: cAccent, foregroundColor: cAccentText,
              minimumSize: const Size(200, 46),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
          onPressed: connecting ? null : () async {
            setState(() => connecting = true);
            await CommManager.instance.connect(d!);
            if (mounted) setState(() => connecting = false);
          },
          child: Text(failed ? '重新连接' : '连接设备',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: connecting ? null : _scanAndApply,
          icon: const Icon(Icons.radar, size: 16, color: cData),
          label: const Text('连不上？自动扫描同网段的 PLC',
              style: TextStyle(fontSize: 12, color: cData)),
        ),
      ]),
    );
  }

  /// 扫描当前网段，找到 S7 设备就直接改地址并重连
  Future<void> _scanAndApply() async {
    final prefix = subnetPrefix(d!.ip);
    if (prefix.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('当前 IP 格式不对，先手动改成 192.168.0.10 这样的完整地址')));
      return;
    }
    final hit = await showPlcScanner(context, prefix: prefix);
    if (hit == null || !mounted) return;
    setState(() => connecting = true);
    d!.ip = hit.ip;
    d!.port = 102;
    final rs = hit.rackSlot.split(' / ');
    int? rack = int.tryParse(rs[0]);
    int? slot = int.tryParse(rs[1]);
    // 只有当扫描到的 TSAP 是标准的机架槽位编码时才覆盖用户设置
    if (hit.tsap == 0x0301) {
      rack = 0;
      slot = 1;
    }
    if (rack != null && slot != null && slot > 0) {
      d!.rack = rack;
      d!.slot = slot;
    }
    await AppStore.instance.saveDevices();
    await CommManager.instance.connect(d!);
    if (mounted) setState(() => connecting = false);
  }
}

/// 长按点动按钮：按住写 ON，松开写 OFF
class JogButton extends StatefulWidget {
  final Device device;
  final PointItem point;
  const JogButton({super.key, required this.device, required this.point});
  @override
  State<JogButton> createState() => _JogButtonState();
}

class _JogButtonState extends State<JogButton> {
  bool pressed = false;
  bool active = false; // 当前正在输出

  Future<void> _set(bool v) async {
    final ok = await CommManager.instance.writeBit(widget.device, widget.point, v);
    if (!mounted) return;
    setState(() => active = ok && v);
    if (!ok) {
      final msg = CommManager.instance.st(widget.device.id).writeError ?? '写入失败';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('「${widget.point.name}」$msg'),
        duration: const Duration(seconds: 3),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final addr = AppStore.instance.addrOf(widget.device, widget.point);
    return GestureDetector(
      // 点动语义：按下即写 1，松开（含手指移出/取消）立即写 0
      onTapDown: (_) { setState(() => pressed = true); _set(true); },
      onTapUp: (_) { setState(() => pressed = false); _set(false); },
      onTapCancel: () { setState(() => pressed = false); _set(false); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1A3A22) : (pressed ? const Color(0xFF22281C) : cCard),
          border: Border.all(
              color: active ? cGreen : (pressed ? cAccent : cLine), width: active || pressed ? 1.5 : 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(widget.point.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cText)),
          const SizedBox(height: 2),
          Text(
            active
                ? '输出中'
                : _addrLine(addr, widget.point.dataType,
                    AppStore.instance.commentOf(widget.point, deviceAddress: addr)),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 9,
                fontFamily: 'monospace',
                color: active ? cGreen : const Color(0xFF7C878E)),
          ),
        ]),
      ),
    );
  }
}

// ================== 点位写入控件 ==================

/// 写入控件：
///   · BOOL 点位 → 直接给「0 / 1」两个按钮，点哪个写哪个（非按钮属性的输入域用）
///   · 数值点位 → 「写入」按钮弹输入框，按数据类型校验范围后下发
class WriteTile extends StatefulWidget {
  final Device device;
  final PointItem point;
  final Object? current;
  const WriteTile({super.key, required this.device, required this.point, this.current});
  @override
  State<WriteTile> createState() => _WriteTileState();
}

class _WriteTileState extends State<WriteTile> {
  bool busy = false;

  void _toast(String msg, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: Duration(seconds: ok ? 2 : 3),
      backgroundColor: ok ? null : const Color(0xFF3A1F1F),
    ));
  }

  Future<void> _writeBool(bool v) async {
    if (busy) return;
    setState(() => busy = true);
    final ok = await CommManager.instance.writeBit(widget.device, widget.point, v);
    if (!mounted) return;
    setState(() => busy = false);
    if (ok) {
      _toast('「${widget.point.name}」已写入 ${v ? 1 : 0}');
    } else {
      final err = CommManager.instance.st(widget.device.id).writeError ?? '写入失败';
      _toast('「${widget.point.name}」$err', ok: false);
    }
  }

  Future<void> _writeNum() async {
    final p = widget.point;
    final ctrl = TextEditingController(
        text: widget.current == null ? '' : formatVarValue(p.dataType, widget.current));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: Text('写入「${p.name}」',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cText)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              p.dataType.isFloat
                  ? '${p.dataType.label} · 可输入小数'
                  : '${p.dataType.label} · 整数 ${p.dataType.minValue} ~ ${p.dataType.maxValue}',
              style: const TextStyle(fontSize: 10.5, color: cDim)),
          const SizedBox(height: 10),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.numberWithOptions(
                decimal: p.dataType.isFloat, signed: p.dataType.isSigned),
            style: const TextStyle(fontSize: 16, fontFamily: 'monospace', color: cText),
            decoration: InputDecoration(
              hintText: p.dataType.isFloat ? '如 12.5' : '如 100',
              hintStyle: const TextStyle(fontSize: 13, color: cDim),
              filled: true,
              fillColor: cCardDark,
              isDense: true,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: const BorderSide(color: cLine)),
            ),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(fontSize: 13, color: cSub))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('写入', style: TextStyle(fontSize: 13, color: cAccent))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final v = p.dataType.parseNum(ctrl.text);
    if (v == null) {
      _toast(p.dataType.isFloat
          ? '数值格式不对（${p.dataType.label} 只接受小数）'
          : '数值格式不对或超出 ${p.dataType.label} 范围', ok: false);
      return;
    }
    setState(() => busy = true);
    final ok = await CommManager.instance.writeValue(widget.device, p, v);
    if (!mounted) return;
    setState(() => busy = false);
    if (ok) {
      _toast('「${p.name}」已写入 ${formatVarValue(p.dataType, v)}');
    } else {
      final err = CommManager.instance.st(widget.device.id).writeError ?? '写入失败';
      _toast('「${p.name}」$err', ok: false);
    }
  }

  Widget _bitBtn(String label, bool v) {
    final p = widget.point;
    final sel = widget.current == v;
    return InkWell(
      onTap: busy ? null : () => _writeBool(v),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 34, height: 28, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel
              ? (v ? const Color(0xFF1A3A22) : const Color(0xFF2A2F33))
              : cCardDark,
          border: Border.all(color: sel ? (v ? cGreen : cSub) : cLine),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                color: sel ? (v ? cGreen : cText) : cSub)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.point;
    final addr = AppStore.instance.addrOf(widget.device, p);
    final isBit = p.dataType.isBit;
    final on = isBit && widget.current == true;
    final txt = isBit
        ? (on ? 'ON' : 'OFF')
        : formatVarValue(p.dataType, widget.current);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: _box(cCard),
      child: Row(children: [
        Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isBit ? (on ? cGreenDot : const Color(0xFF3D464C)) : cData)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: on || !isBit ? cText : cSub)),
            const SizedBox(height: 2),
            Text(
                _addrLine(addr, p.dataType,
                    AppStore.instance.commentOf(p, deviceAddress: addr)),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9, fontFamily: 'monospace', color: cDim)),
          ]),
        ),
        const SizedBox(width: 8),
        if (!isBit)
          Text(txt,
              style: const TextStyle(
                  fontSize: 12, fontFamily: 'monospace', color: cData)),
        const SizedBox(width: 8),
        if (isBit) ...[
          _bitBtn('0', false),
          const SizedBox(width: 6),
          _bitBtn('1', true),
        ] else
          TextButton(
            onPressed: busy ? null : _writeNum,
            style: TextButton.styleFrom(
                minimumSize: const Size(48, 28),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                backgroundColor: cCardDark,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                    side: const BorderSide(color: cLine))),
            child: const Text('写入',
                style: TextStyle(fontSize: 12, color: cAccent)),
          ),
      ]),
    );
  }
}

// ================== 模板编辑 ==================
class TemplateEditScreen extends StatefulWidget {
  final String templateId;
  const TemplateEditScreen({super.key, required this.templateId});
  @override
  State<TemplateEditScreen> createState() => _TemplateEditScreenState();
}

class _TemplateEditScreenState extends State<TemplateEditScreen> {
  Template? tpl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await AppStore.instance.load();
    tpl = AppStore.instance.templates
        .where((t) => t.id == widget.templateId)
        .firstOrNull;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (tpl == null) {
      return const Scaffold(body: Center(child: Text('模板不存在', style: TextStyle(color: cSub))));
    }
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cBg, foregroundColor: cText, elevation: 0,
        title: Text('编辑模板 · ${tpl!.name}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            onPressed: _editMeta,
            tooltip: '模板名称与描述',
            icon: const Icon(Icons.drive_file_rename_outline, size: 18, color: cSub),
          ),
          TextButton(
            onPressed: () async {
              await AppStore.instance.saveTemplates();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存', style: TextStyle(color: cAccent)),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _imageSection(),
            const SizedBox(height: 16),
            const Text('界面控件 · 点按编辑', style: TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
            const SizedBox(height: 8),
            ...tpl!.points.asMap().entries.map((e) => _pointRow(e.key, e.value)),
            const SizedBox(height: 10),
            InkWell(
              onTap: _addPoint,
              child: Container(
                height: 46,
                decoration: BoxDecoration(
                    color: const Color(0xFF161A1D),
                    border: Border.all(color: const Color(0xFF333B40))),
                child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.add, size: 15, color: cSub),
                  SizedBox(width: 6),
                  Text('添加控件（信号 / 按钮）', style: TextStyle(fontSize: 12, color: cSub)),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: _box(const Color(0xFF171B1E), borderColor: const Color(0xFF262C30)),
              child: const Text('修改保存后，所有使用该模板的设备界面即时同步。地址可在各设备的向导里单独覆盖。',
                  style: TextStyle(fontSize: 10.5, color: cSub)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageSection() {
    final has = tpl!.imagePath != null && File(tpl!.imagePath!).existsSync();
    return InkWell(
      onTap: _pickImage,
      child: Container(
        height: 160,
        decoration: _box(cCardDark),
        child: has
            ? Stack(fit: StackFit.expand, children: [
                Image.file(File(tpl!.imagePath!), fit: BoxFit.cover),
                Positioned(right: 8, bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    color: Colors.black54,
                    child: const Text('更换背景图（点按）', style: TextStyle(fontSize: 11, color: Colors.white)),
                  )),
                Positioned(right: 8, top: 8,
                  child: InkWell(
                    onTap: () { setState(() => tpl!.imagePath = null); },
                    child: Container(padding: const EdgeInsets.all(4),
                        color: Colors.black54,
                        child: const Icon(Icons.close, size: 14, color: Colors.white)),
                  )),
              ])
            : const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.image, size: 28, color: cDim),
                SizedBox(height: 6),
                Text('导入背景图（现场照片）', style: TextStyle(fontSize: 12, color: cSub)),
              ])),
      ),
    );
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1920);
    if (x != null) {
      setState(() => tpl!.imagePath = x.path);
    }
  }

  /// 改模板名称与描述（内置模板也可以改名，改内容后可用模板库的「恢复出厂内容」还原）
  Future<void> _editMeta() async {
    final nameC = TextEditingController(text: tpl!.name);
    final descC = TextEditingController(text: tpl!.desc);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('模板信息', style: TextStyle(fontSize: 16, color: cText)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: nameC,
              style: const TextStyle(fontSize: 14, color: cText),
              decoration: const InputDecoration(
                  labelText: '名称', labelStyle: TextStyle(color: cDim))),
          const SizedBox(height: 12),
          TextField(
              controller: descC,
              style: const TextStyle(fontSize: 13, color: cText),
              decoration: const InputDecoration(
                  labelText: '描述', labelStyle: TextStyle(color: cDim))),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: cDim))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: cAccent, foregroundColor: cAccentText),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      if (nameC.text.trim().isNotEmpty) tpl!.name = nameC.text.trim();
      tpl!.desc = descC.text.trim();
    });
  }

  Widget _pointRow(int index, PointItem p) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: _box(cCard),
        child: Row(children: [
          Expanded(child: InkWell(
            onTap: () => _editPoint(index),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: const TextStyle(fontSize: 13, color: Color(0xFFD9E0E4))),
              const SizedBox(height: 2),
              Text(
                  '${p.address} · ${p.dataType.label}'
                  '${AppStore.instance.commentOf(p).isEmpty ? '' : ' · ${AppStore.instance.commentOf(p)}'}'
                  ' · ${p.isOutput ? "按钮(长按点动)" : "指示灯"}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: cDim)),
            ]),
          )),
          IconButton(
            onPressed: () { setState(() => p.visible = !p.visible); },
            icon: Icon(p.visible ? Icons.visibility : Icons.visibility_off,
                size: 16, color: p.visible ? cAccent : cDim),
          ),
          IconButton(
            onPressed: () { setState(() => tpl!.points.removeAt(index)); },
            icon: const Icon(Icons.delete_outline, size: 16, color: cDim),
          ),
        ]),
      ),
    );
  }

  Future<void> _editPoint(int index) async {
    final p = tpl!.points[index];
    final nameC = TextEditingController(text: p.name);
    final cmtC = TextEditingController(text: p.comment);
    bool isOut = p.isOutput;
    VarType dtype = p.dataType;
    String addr = p.address;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('编辑控件', style: TextStyle(fontSize: 16, color: cText)),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameC,
                style: const TextStyle(fontSize: 14, color: cText),
                decoration: const InputDecoration(labelText: '名称', labelStyle: TextStyle(color: cDim))),
            const SizedBox(height: 12),
            Row(children: [
              const Text('变量类型', style: TextStyle(fontSize: 11, color: cDim)),
              const Spacer(),
              _TypeButton(
                value: dtype,
                width: 78,
                onChanged: (t) => setD(() {
                  dtype = t;
                  addr = addrFromText(addr, t);
                }),
              ),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: AddressField(
                key: ValueKey('dlg_${p.id}_${dtype.name}'),
                initial: addr,
                type: dtype,
                onChanged: (a) => addr = a,
              ),
            ),
            const SizedBox(height: 10),
            TextField(controller: cmtC,
                style: const TextStyle(fontSize: 13, color: cText),
                decoration: const InputDecoration(
                    labelText: '变量注释（显示在地址后）',
                    labelStyle: TextStyle(color: cDim))),
            const SizedBox(height: 12),
            Row(children: [
              ChoiceChip(label: const Text('指示灯'), selected: !isOut,
                  onSelected: (_) => setD(() => isOut = false),
                  selectedColor: cAccent, backgroundColor: cCardDark),
              const SizedBox(width: 8),
              ChoiceChip(label: const Text('点动按钮'), selected: isOut,
                  onSelected: (_) => setD(() => isOut = true),
                  selectedColor: cAccent, backgroundColor: cCardDark),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: cDim))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: cAccent, foregroundColor: cAccentText),
              child: const Text('确定')),
        ],
      )),
    );
    if (ok == true) {
      setState(() {
        p.name = nameC.text.trim().isEmpty ? p.name : nameC.text.trim();
        p.address = addr.trim();
        p.comment = cmtC.text.trim();
        p.type = isOut ? PointType.output : PointType.input;
        p.dataType = dtype;
      });
    }
  }

  Future<void> _addPoint() async {
    setState(() {
      tpl!.points.add(PointItem(
          id: 'p_${DateTime.now().millisecondsSinceEpoch}',
          name: '新点位', address: 'I0.0', type: PointType.input));
    });
    _editPoint(tpl!.points.length - 1);
  }
}

// ================== 模板库（定制模板） ==================
class TemplateLibraryScreen extends StatefulWidget {
  const TemplateLibraryScreen({super.key});
  @override
  State<TemplateLibraryScreen> createState() => _TemplateLibraryScreenState();
}

class _TemplateLibraryScreenState extends State<TemplateLibraryScreen> {
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    await AppStore.instance.load();
    if (mounted) setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 12)),
        backgroundColor: cCard,
        duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    final st = AppStore.instance;
    final builtins = st.templates.where((t) => st.isBuiltinTemplate(t.id)).toList();
    final customs = st.templates.where((t) => !st.isBuiltinTemplate(t.id)).toList();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cBg,
        foregroundColor: cText,
        elevation: 0,
        title: const Text('模板库',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          TextButton.icon(
            onPressed: _batchExport,
            icon: const Icon(Icons.ios_share, size: 15, color: cSub),
            label: const Text('导出', style: TextStyle(fontSize: 13, color: cSub)),
          ),
          TextButton.icon(
            onPressed: _newTemplate,
            icon: const Icon(Icons.add, size: 16, color: cAccent),
            label: const Text('新建', style: TextStyle(fontSize: 13, color: cAccent)),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            _sectionTitle('内置模板', '${builtins.length}'),
            const SizedBox(height: 8),
            ...builtins.map(_tile),
            const SizedBox(height: 18),
            _sectionTitle('自定义模板', '${customs.length}'),
            const SizedBox(height: 8),
            if (customs.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: _box(cCard),
                child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('还没有自定义模板', style: TextStyle(fontSize: 12, color: cText)),
                  SizedBox(height: 4),
                  Text('点右上角「新建」：可以从空白做，也可以复制一个现有模板再改。',
                      style: TextStyle(fontSize: 10.5, color: cSub)),
                ]),
              )
            else
              ...customs.map(_tile),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: InkWell(
                  onTap: _importFromFile,
                  child: Container(
                    height: 46,
                    decoration: BoxDecoration(
                        color: const Color(0xFF161A1D),
                        border: Border.all(color: const Color(0xFF333B40))),
                    child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.file_open_outlined, size: 15, color: cSub),
                          SizedBox(width: 6),
                          Text('导入配置', style: TextStyle(fontSize: 12, color: cSub)),
                        ]),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  onTap: _batchExport,
                  child: Container(
                    height: 46,
                    decoration: BoxDecoration(
                        color: cAccent.withValues(alpha: 0.12),
                        border: Border.all(color: cAccent.withValues(alpha: 0.45))),
                    child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.ios_share, size: 15, color: cAccent),
                          SizedBox(width: 6),
                          Text('导出并分享', style: TextStyle(fontSize: 12, color: cAccent)),
                        ]),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration:
                  _box(const Color(0xFF171B1E), borderColor: const Color(0xFF262C30)),
              child: const Text(
                  '配置文件（.plccfg）里装着模板、设备地址和变量注释，导出后可直接用微信/QQ 发给别人；'
                  '对方在聊天里点开文件选「用 PLC监控 打开」即可导入，也可以在「模板库 → 导入配置」里选文件。\n'
                  '导入时可选择「合并」（保留本机配置再追加）或「覆盖」（用对方配置替换本机）。',
                  style: TextStyle(fontSize: 10.5, color: cSub)),
            ),
            const SizedBox(height: 18),
            const _AppFooter(),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String t, String n) => Row(children: [
        Text(t, style: const TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
        const Spacer(),
        Text(n, style: const TextStyle(fontSize: 10.5, color: cDim)),
      ]);

  Widget _tile(Template t) {
    final st = AppStore.instance;
    final builtin = st.isBuiltinTemplate(t.id);
    final used = st.devicesUsing(t.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: _box(cCard),
        child: Row(children: [
          Expanded(
            child: InkWell(
              onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => TemplateEditScreen(templateId: t.id)))
                  .then((_) => _refresh()),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                      child: Text(t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5, color: cText))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: (builtin ? cDim : cData).withValues(alpha: 0.12),
                        border: Border.all(
                            color: (builtin ? cDim : cData).withValues(alpha: 0.35))),
                    child: Text(builtin ? '内置' : '自定义',
                        style: TextStyle(fontSize: 9, color: builtin ? cDim : cData)),
                  ),
                ]),
                const SizedBox(height: 3),
                Text(
                    '${t.points.length} 点位'
                    '${t.desc.isEmpty ? '' : ' · ${t.desc}'}'
                    '${used > 0 ? ' · $used 台设备在用' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: cDim)),
              ]),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 16, color: cSub),
            color: cCard,
            padding: EdgeInsets.zero,
            onSelected: (v) => _onMenu(v, t),
            itemBuilder: (_) => [
              _menuItem('edit', Icons.edit_outlined, '编辑点位'),
              _menuItem('meta', Icons.drive_file_rename_outline, '改名称 / 描述'),
              _menuItem('copy', Icons.copy_all_outlined, '复制为新模板'),
              _menuItem('export', Icons.ios_share, '导出并分享'),
              if (builtin) _menuItem('restore', Icons.restore, '恢复出厂内容'),
              if (!builtin) _menuItem('delete', Icons.delete_outline, '删除模板', danger: true),
            ],
          ),
        ]),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(String v, IconData icon, String label,
          {bool danger = false}) =>
      PopupMenuItem(
        value: v,
        height: 40,
        child: Row(children: [
          Icon(icon, size: 14, color: danger ? cRed : cSub),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(fontSize: 12, color: danger ? cRed : cText)),
        ]),
      );

  Future<void> _onMenu(String v, Template t) async {
    switch (v) {
      case 'edit':
        await Navigator.push(context,
            MaterialPageRoute(builder: (_) => TemplateEditScreen(templateId: t.id)));
        await _refresh();
        break;
      case 'meta':
        await _editMeta(t);
        break;
      case 'copy':
        final copy =
            await AppStore.instance.createTemplate(copyFromId: t.id, name: '${t.name} 副本');
        await _refresh();
        _toast('已复制为「${copy.name}」');
        break;
      case 'export':
        await _export(t);
        break;
      case 'restore':
        final ok = await AppStore.instance.restoreBuiltin(t.id);
        await _refresh();
        _toast(ok ? '已恢复「${t.name}」出厂内容' : '恢复失败');
        break;
      case 'delete':
        final r = await AppStore.instance.deleteTemplate(t.id);
        await _refresh();
        _toast(r.msg);
        break;
    }
  }

  Future<void> _newTemplate() async {
    final nameC = TextEditingController();
    String? copyFrom;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: cCard,
          title: const Text('新建模板', style: TextStyle(fontSize: 16, color: cText)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameC,
              style: const TextStyle(fontSize: 14, color: cText),
              decoration: const InputDecoration(
                  labelText: '模板名称',
                  hintText: '例如：三工位转台',
                  labelStyle: TextStyle(color: cDim)),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String?>(
              initialValue: copyFrom,
              dropdownColor: cCard,
              style: const TextStyle(fontSize: 13, color: cText),
              decoration: const InputDecoration(
                  labelText: '起点', labelStyle: TextStyle(color: cDim)),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('空白模板')),
                ...AppStore.instance.templates.map((t) => DropdownMenuItem<String?>(
                    value: t.id, child: Text('复制：${t.name}'))),
              ],
              onChanged: (v) => setD(() => copyFrom = v),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消', style: TextStyle(color: cDim))),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: cAccent, foregroundColor: cAccentText),
                child: const Text('创建')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final t = await AppStore.instance
        .createTemplate(copyFromId: copyFrom, name: nameC.text.trim());
    await _refresh();
    if (!mounted) return;
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => TemplateEditScreen(templateId: t.id)));
    await _refresh();
  }

  Future<void> _editMeta(Template t) async {
    final nameC = TextEditingController(text: t.name);
    final descC = TextEditingController(text: t.desc);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('模板信息', style: TextStyle(fontSize: 16, color: cText)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: nameC,
              style: const TextStyle(fontSize: 14, color: cText),
              decoration: const InputDecoration(
                  labelText: '名称', labelStyle: TextStyle(color: cDim))),
          const SizedBox(height: 12),
          TextField(
              controller: descC,
              style: const TextStyle(fontSize: 13, color: cText),
              decoration: const InputDecoration(
                  labelText: '描述（显示在模板卡片上）',
                  labelStyle: TextStyle(color: cDim))),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: cDim))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: cAccent, foregroundColor: cAccentText),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      if (nameC.text.trim().isNotEmpty) t.name = nameC.text.trim();
      t.desc = descC.text.trim();
    });
    await AppStore.instance.saveTemplates();
    await _refresh();
  }

  /// 导出单个模板：写文件后直接拉起系统分享面板
  Future<void> _export(Template t) async {
    try {
      final content = buildBundle(
        ExportPick(templateIds: {t.id}, devices: false, symbols: false),
        deviceTag: LicenseManager.instance.deviceTag,
      );
      final path = await writeBundleFile(content, name: '模板_${t.name}');
      final r = await ConfigFileIo.share(path, title: '分享模板「${t.name}」');
      _toast(r.ok ? '已生成 ${path.split('/').last}，请选择要发到哪个 App' : r.msg);
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  /// 从任意位置选文件导入（下载目录、微信保存的文件都能选）
  Future<void> _importFromFile() async {
    try {
      final picked = await ConfigFileIo.pick();
      if (picked == null) return;
      final ok = await showImportDialog(context, picked.name, picked.content);
      if (ok) await _refresh();
    } catch (e) {
      _toast('选文件失败：$e');
    }
  }

  /// 批量导出：勾选模板 / 设备 / 变量注释，打成一个配置文件分享出去
  Future<void> _batchExport() async {
    final st = AppStore.instance;
    final sel = <String>{...st.templates.map((t) => t.id)};
    var withDevices = st.devices.isNotEmpty;
    var withSymbols = st.symbols.isNotEmpty;
    var withImages = true;
    final nameC = TextEditingController(text: 'PLC配置');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: cCard,
          title: const Text('批量导出配置',
              style: TextStyle(fontSize: 16, color: cText)),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: nameC,
                  style: const TextStyle(fontSize: 13.5, color: cText),
                  decoration: const InputDecoration(
                      labelText: '文件名',
                      labelStyle: TextStyle(color: cDim)),
                ),
                const SizedBox(height: 4),
                _checkRow('包含设备（${st.devices.length} 台）', withDevices,
                    (v) => setD(() => withDevices = v)),
                _checkRow('包含变量注释（${st.symbols.length} 条）', withSymbols,
                    (v) => setD(() => withSymbols = v)),
                _checkRow('内嵌背景图（文件会大一些）', withImages,
                    (v) => setD(() => withImages = v)),
                const Divider(height: 18, color: Color(0xFF2A3136)),
                Row(children: [
                  Text('模板 ${sel.length}/${st.templates.length}',
                      style: const TextStyle(fontSize: 11, color: cDim)),
                  const Spacer(),
                  TextButton(
                      onPressed: () => setD(() {
                            if (sel.length == st.templates.length) {
                              sel.clear();
                            } else {
                              sel.addAll(st.templates.map((t) => t.id));
                            }
                          }),
                      child: Text(sel.length == st.templates.length ? '全不选' : '全选',
                          style: const TextStyle(fontSize: 11, color: cAccent))),
                ]),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 176),
                  child: ListView(
                    shrinkWrap: true,
                    children: st.templates
                        .map((t) => CheckboxListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              contentPadding: EdgeInsets.zero,
                              activeColor: cAccent,
                              value: sel.contains(t.id),
                              onChanged: (v) => setD(() {
                                if (v == true) {
                                  sel.add(t.id);
                                } else {
                                  sel.remove(t.id);
                                }
                              }),
                              title: Text(t.name,
                                  style: const TextStyle(fontSize: 12.5, color: cText)),
                              subtitle: Text('${t.points.length} 点位',
                                  style: const TextStyle(fontSize: 10, color: cDim)),
                            ))
                        .toList(),
                  ),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消', style: TextStyle(color: cDim))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child:
                    const Text('导出并分享', style: TextStyle(color: cAccent))),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    // ignore: avoid_print
    print('EXPORT step1 ok=$ok sel=${sel.length}');
    if (sel.isEmpty && !withDevices && !withSymbols) {
      _toast('没有勾选任何内容');
      return;
    }
    try {
      final content = buildBundle(
        ExportPick(
            templateIds: sel,
            devices: withDevices,
            symbols: withSymbols,
            images: withImages),
        deviceTag: LicenseManager.instance.deviceTag,
      );
      // ignore: avoid_print
      print('EXPORT step2 built ${content.length} chars');
      final nm = nameC.text.trim();
      final path = await writeBundleFile(content, name: nm.isEmpty ? 'PLC配置' : nm);
      // ignore: avoid_print
      print('EXPORT step3 file=$path');
      final r = await ConfigFileIo.share(path, title: '分享 PLC 配置');
      // ignore: avoid_print
      print('EXPORT step4 share=${r.ok} ${r.msg}');
      _toast(r.ok
          ? '已生成 ${path.split('/').last}（${sel.length} 模板），请选择发送目标'
          : r.msg);
    } catch (e) {
      // ignore: avoid_print
      print('EXPORT ERR $e');
      _toast('导出失败：$e');
    }
  }

  Widget _checkRow(String label, bool value, ValueChanged<bool> onChanged) =>
      CheckboxListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: EdgeInsets.zero,
        activeColor: cAccent,
        value: value,
        onChanged: (v) => onChanged(v == true),
        title: Text(label, style: const TextStyle(fontSize: 12.5, color: cText)),
      );
}

/// 导入确认（合并 / 覆盖）
///
/// 本机选文件和外部「用本应用打开」共用这一处，保证两条路径行为一致。
Future<bool> showImportDialog(
    BuildContext context, String fileName, String content) async {
  final b = parseBundle(content, sourceName: fileName);
  if (b == null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('这个文件不是 PLC 配置文件，或内容已损坏',
            style: TextStyle(fontSize: 12)),
        backgroundColor: cCard));
    return false;
  }

  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: cCard,
      title: const Text('导入配置', style: TextStyle(fontSize: 16, color: cText)),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fileName.isEmpty ? '配置文件' : fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: cText)),
                const SizedBox(height: 6),
                Text(b.summary,
                    style: const TextStyle(fontSize: 11.5, color: cSub)),
                if (b.deviceTag.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('来自设备 ${b.deviceTag}',
                      style: const TextStyle(fontSize: 10.5, color: cDim)),
                ],
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: const Color(0xFF171B1E),
                      border: Border.all(color: const Color(0xFF262C30))),
                  child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('合并：保留本机现有配置，把文件内容追加进来（重复的自动跳过）',
                            style: TextStyle(fontSize: 10.5, color: cSub)),
                        SizedBox(height: 6),
                        Text('覆盖：用文件内容替换本机的模板与设备（内置模板保留；覆盖前自动存快照，可回滚）',
                            style: TextStyle(fontSize: 10.5, color: cSub)),
                      ]),
                ),
              ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: cDim))),
        TextButton(
            onPressed: () => Navigator.pop(ctx, 'merge'),
            child: const Text('合并', style: TextStyle(color: cAccent))),
        TextButton(
            onPressed: () => Navigator.pop(ctx, 'replace'),
            child: const Text('覆盖', style: TextStyle(color: cAmber))),
      ],
    ),
  );
  if (choice == null) return false;

  final r = choice == 'replace' ? await applyReplace(b) : await applyMerge(b);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r.message, style: const TextStyle(fontSize: 12)),
        backgroundColor: cCard,
        duration: const Duration(seconds: 4)));
  }
  return true;
}

// ================== 通用小组件 ==================
BoxDecoration _box(Color color, {Color? borderColor}) => BoxDecoration(
      color: color,
      border: Border.all(color: borderColor ?? cLine),
    );

Widget _pill(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(100),
          border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 5, height: 5, margin: const EdgeInsets.only(right: 5),
            decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        Text(text, style: TextStyle(fontSize: 10, color: color)),
      ]),
    );

/// 变量类型选择按钮（下拉菜单）
class _TypeButton extends StatelessWidget {
  final VarType value;
  final double width;
  final ValueChanged<VarType> onChanged;
  const _TypeButton({required this.value, required this.onChanged, this.width = 70});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<VarType>(
      tooltip: '选择变量类型',
      color: cCard,
      onSelected: onChanged,
      itemBuilder: (_) => VarType.values
          .map((t) => PopupMenuItem<VarType>(
                value: t,
                height: 38,
                child: Row(children: [
                  SizedBox(
                    width: 56,
                    child: Text(t.label,
                        style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: t == value ? cAccent : cText)),
                  ),
                  Text(t.isBit ? '位' : '${t.byteSize} 字节',
                      style: const TextStyle(fontSize: 10, color: cDim)),
                ]),
              ))
          .toList(),
      child: Container(
        width: width,
        height: 32,
        decoration: BoxDecoration(
            color: cCardDark,
            border: Border.all(color: cLine),
            borderRadius: BorderRadius.circular(4)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(value.label,
              style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: value.isBit ? cSub : cData)),
          const Icon(Icons.arrow_drop_down, size: 15, color: cDim),
        ]),
      ),
    );
  }
}

String _protoName(Protocol p) => switch (p) {
      Protocol.s7 => 'S7',
      Protocol.modbusTcp => 'Modbus TCP',
      Protocol.plcsim => 'PLCSIM',
      Protocol.opcua => 'OPC UA',
    };

class _AddDeviceTile extends StatelessWidget {
  final VoidCallback onTap;
  const _AddDeviceTile({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 62,
        decoration: BoxDecoration(
            color: const Color(0xFF161A1D),
            border: Border.all(color: const Color(0xFF333B40))),
        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.add, size: 16, color: cSub),
          SizedBox(width: 8),
          Text('新建设备 · 使用向导', style: TextStyle(fontSize: 12.5, color: cSub)),
        ]),
      ),
    );
  }
}

// ================== 地址编辑器：区域 + 类型 + 方框 ==================
/// 选 I/Q/M/DB 区 → 按类型给出地址模板 → 只在方框里填编号。
///
/// 生成规则见 s7_addr.dart：BOOL 带 `.位`，BYTE/WORD/DWORD 带 B/W/D 尺寸字母，
/// DB 区统一 `DBn.DBX/DBB/DBW/DBD` 写法。
class AddressField extends StatefulWidget {
  final String initial;
  final VarType type;
  final ValueChanged<String> onChanged;
  const AddressField({
    super.key,
    required this.initial,
    required this.type,
    required this.onChanged,
  });

  @override
  State<AddressField> createState() => _AddressFieldState();
}

class _AddressFieldState extends State<AddressField> {
  late VarArea area;
  late int db;
  late int byteIdx;
  late int bitIdx;
  late final TextEditingController dbC;
  late final TextEditingController byteC;
  late final TextEditingController bitC;

  @override
  void initState() {
    super.initState();
    final s = parseAddrSpec(widget.initial) ?? AddrSpec();
    area = s.area;
    db = s.db;
    byteIdx = s.byteIndex;
    bitIdx = s.bitIndex;
    dbC = TextEditingController(text: '$db');
    byteC = TextEditingController(text: '$byteIdx');
    bitC = TextEditingController(text: '$bitIdx');
  }

  @override
  void dispose() {
    dbC.dispose();
    byteC.dispose();
    bitC.dispose();
    super.dispose();
  }

  AddrSpec get _spec =>
      AddrSpec(area: area, db: db, byteIndex: byteIdx, bitIndex: bitIdx);

  void _emit() => widget.onChanged(_spec.text(widget.type));

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 5,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _areaChip(VarArea.input),
        _areaChip(VarArea.output),
        _areaChip(VarArea.memory),
        _areaChip(VarArea.db),
        const SizedBox(width: 3),
        ..._addrParts(),
      ],
    );
  }

  Widget _areaChip(VarArea a) {
    final sel = area == a;
    return InkWell(
      onTap: () {
        setState(() => area = a);
        _emit();
      },
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: a == VarArea.db ? 36 : 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel ? cAccent : cCardDark,
          border: Border.all(color: sel ? cAccent : const Color(0xFF39424A)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(a.letter,
            style: TextStyle(
                fontSize: 10.5,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                color: sel ? cAccentText : cSub)),
      ),
    );
  }

  List<Widget> _addrParts() {
    final t = widget.type;
    final tag = sizeTag(t);
    final parts = <Widget>[];
    if (area == VarArea.db) {
      parts.add(_lbl('DB'));
      parts.add(_num(dbC, 30, (v) => db = v < 1 ? 1 : v));
      parts.add(_lbl('.DB${tag.isEmpty ? 'X' : tag}'));
      parts.add(_num(byteC, 36, (v) => byteIdx = v));
    } else {
      parts.add(_lbl(area.letter));
      if (tag.isNotEmpty) parts.add(_lbl(tag));
      parts.add(_num(byteC, 36, (v) => byteIdx = v));
    }
    if (t.isBit) {
      parts.add(_lbl('.'));
      parts.add(_num(bitC, 24, (v) => bitIdx = v.clamp(0, 7)));
    }
    return parts;
  }

  Widget _lbl(String s) => Text(s,
      style: const TextStyle(
          fontSize: 12.5, fontFamily: 'monospace', color: cSub));

  /// 一个「方框」输入格
  Widget _num(TextEditingController c, double w, void Function(int) setVal) {
    return SizedBox(
      width: w,
      height: 30,
      child: TextField(
        controller: c,
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(3),
        ],
        style: const TextStyle(
            fontSize: 13, color: cData, fontFamily: 'monospace'),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.zero,
          filled: true,
          fillColor: cCardDark,
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(3),
              borderSide: const BorderSide(color: Color(0xFF39424A))),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(3),
              borderSide: const BorderSide(color: cAccent, width: 1.4)),
        ),
        onChanged: (s) {
          setVal(int.tryParse(s) ?? 0);
          _emit();
        },
      ),
    );
  }
}

/// 变量注释输入（自带控制器，避免每次父级 setState 掉焦点）
class _CommentField extends StatefulWidget {
  final String initial;
  final String hint;
  final ValueChanged<String> onChanged;
  const _CommentField({
    required this.initial,
    required this.hint,
    required this.onChanged,
  });

  @override
  State<_CommentField> createState() => _CommentFieldState();
}

class _CommentFieldState extends State<_CommentField> {
  late final TextEditingController c =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: TextField(
        controller: c,
        style: const TextStyle(fontSize: 11.5, color: Color(0xFFD9E0E4)),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          hintText: widget.hint,
          hintStyle: const TextStyle(fontSize: 10.5, color: Color(0xFF5B666D)),
          filled: true,
          fillColor: cCardDark,
          prefixIcon: const Padding(
            padding: EdgeInsets.only(left: 8, right: 4),
            child: Icon(Icons.notes, size: 12, color: cDim),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: cLine)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(color: cAccent)),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

/// 地址 · 类型 · 注释
String _addrLine(String addr, VarType t, String cmt) {
  final c = cmt.trim();
  return c.isEmpty ? '$addr · ${t.label}' : '$addr · ${t.label} · $c';
}

/// 底部：版本号 + 品牌，同一行
class _AppFooter extends StatelessWidget {
  const _AppFooter();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 8, bottom: 6),
      child: Center(
        child: Text(
          '版本$kAppVersion BY $kBrand',
          style: TextStyle(
              fontSize: 10.5,
              color: Color(0xFF5F6B72),
              letterSpacing: 0.4),
        ),
      ),
    );
  }
}

/// 弹出扫描窗口，返回用户选中的设备（null = 取消）
Future<ScanHit?> showPlcScanner(BuildContext context, {required String prefix}) {
  return showDialog<ScanHit>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ScanDialog(prefix: prefix),
  );
}

class _ScanDialog extends StatefulWidget {
  final String prefix;
  const _ScanDialog({required this.prefix});
  @override
  State<_ScanDialog> createState() => _ScanDialogState();
}

class _ScanDialogState extends State<_ScanDialog> {
  List<ScanHit> hits = [];
  int done = 0;
  int total = 254;
  bool running = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final r = await scanS7Subnet(
      widget.prefix,
      onProgress: (d, t) {
        if (mounted) setState(() { done = d; total = t; });
      },
    );
    if (mounted) setState(() { hits = r; running = false; });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: cCard,
      title: const Text('扫描 S7 设备',
          style: TextStyle(fontSize: 16, color: cText)),
      content: SizedBox(
        width: 340,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('网段 ${widget.prefix}.1 ~ 254 · 端口 102',
              style: const TextStyle(fontSize: 11, color: cSub)),
          const SizedBox(height: 12),
          if (running) ...[
            LinearProgressIndicator(
              value: total == 0 ? null : done / total,
              backgroundColor: cCardDark,
              valueColor: const AlwaysStoppedAnimation(cAccent),
              minHeight: 4,
            ),
            const SizedBox(height: 8),
            Text('已扫描 $done / $total${hits.isEmpty ? '' : ' · 发现 ${hits.length} 台'}',
                style: const TextStyle(fontSize: 11, color: cDim)),
          ] else if (hits.isEmpty) ...[
            const Text('没扫到能握手的 S7 设备',
                style: TextStyle(fontSize: 12.5, color: cAmber)),
            const SizedBox(height: 6),
            const Text(
                '可能原因：\n'
                '· 仿真实例没启动（PLCSIM 要 Start 到 RUN）\n'
                '· PLC 与手机不在同一网段\n'
                '· 该 CPU 不允许 PUT/GET 通讯',
                style: TextStyle(fontSize: 10.5, color: cSub, height: 1.7)),
          ] else ...[
            const Text('点一下直接套用地址并重连：',
                style: TextStyle(fontSize: 11, color: cSub)),
            const SizedBox(height: 8),
            ...hits.map((h) => InkWell(
                  onTap: () => Navigator.pop(context, h),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    decoration: _box(cCardDark),
                    child: Row(children: [
                      const Icon(Icons.memory, size: 14, color: cGreen),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(h.ip,
                              style: const TextStyle(
                                  fontSize: 13, fontFamily: 'monospace', color: cText)),
                          Text('TSAP 0x${h.tsap.toRadixString(16).padLeft(4, '0')} · '
                              '机架/槽位 ${h.rackSlot} · ${h.rttMs}ms',
                              style: const TextStyle(fontSize: 9.5, color: cDim)),
                        ]),
                      ),
                      const Icon(Icons.chevron_right, size: 16, color: cDim),
                    ]),
                  ),
                )),
          ],
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(running ? '取消' : '关闭', style: const TextStyle(color: cDim)),
        ),
      ],
    );
  }
}

// ================== 客户配置 ==================
class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});
  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  List<({DateTime time, String json})> snaps = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await AppStore.instance.load();
    final s = await AppStore.instance.snapshots();
    if (mounted) setState(() => snaps = s);
  }

  String _fmt(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final st = AppStore.instance;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cBg,
        foregroundColor: cText,
        elevation: 0,
        title: const Text('客户配置',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: _box(cCard),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.save_outlined, size: 16, color: cGreen),
                  const SizedBox(width: 8),
                  const Text('配置自动保存',
                      style: TextStyle(fontSize: 13, color: cText)),
                  const Spacer(),
                  Text(st.lastSavedAt == null ? '尚未保存' : _fmt(st.lastSavedAt!),
                      style: const TextStyle(fontSize: 10, color: cDim)),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  _stat('${st.devices.length}', '设备'),
                  _stat('${st.templates.length}', '模板'),
                  _stat('${st.symbols.length}', '注释'),
                ]),
                const SizedBox(height: 8),
                const Text('配置存在应用私有数据里，覆盖安装升级不会丢失；卸载 App 才会清空。',
                    style: TextStyle(fontSize: 10, color: cSub)),
              ]),
            ),
            const SizedBox(height: 16),
            const Text('变量注释', style: TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
            const SizedBox(height: 8),
            InkWell(
              onTap: () {
                Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const SymbolImportScreen()))
                    .then((_) => _load());
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: _box(cCard),
                child: Row(children: [
                  const Icon(Icons.article_outlined, size: 16, color: cData),
                  const SizedBox(width: 10),
                  const Expanded(
                      child: Text('读取变量注释（粘贴博图变量表）',
                          style: TextStyle(fontSize: 13, color: cText))),
                  Text('${st.symbols.length} 条',
                      style: const TextStyle(fontSize: 10.5, color: cDim)),
                  const Icon(Icons.chevron_right, size: 16, color: cDim),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            const Text('授权', style: TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
            const SizedBox(height: 8),
            _licenseCard(),
            const SizedBox(height: 16),
            const Text('配置快照 · 点按可回滚',
                style: TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
            const SizedBox(height: 8),
            if (snaps.isEmpty)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: _box(cCard),
                child: const Text('还没有快照，保存一次配置后自动生成（保留最近 3 份）',
                    style: TextStyle(fontSize: 11, color: cSub)),
              )
            else
              ...snaps.asMap().entries.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      onTap: () => _restore(e.value),
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: _box(cCard),
                        child: Row(children: [
                          const Icon(Icons.history, size: 15, color: cAmber),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Text(_fmt(e.value.time),
                                  style: const TextStyle(
                                      fontSize: 12, color: cText))),
                          Text(e.key == 0 ? '最新 · 恢复' : '恢复',
                              style: const TextStyle(fontSize: 11, color: cData)),
                        ]),
                      ),
                    ),
                  )),
            const SizedBox(height: 16),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF5A3030)),
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6))),
              onPressed: _reset,
              child: const Text('恢复出厂配置（清空全部设备与注释）',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFFE08282))),
            ),
            const SizedBox(height: 20),
            const _AppFooter(),
          ],
        ),
      ),
    );
  }

  Widget _licenseCard() {
    final lm = LicenseManager.instance;
    final ok = lm.activated;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _box(cCard),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.verified_outlined : Icons.gpp_bad_outlined,
              size: 16, color: ok ? cGreen : cRed),
          const SizedBox(width: 8),
          Text(ok ? '本机已授权' : '本机未授权',
              style: TextStyle(fontSize: 13, color: ok ? cText : cRed)),
          const Spacer(),
          Text('v$kAppVersion ($kAppBuild)',
              style: const TextStyle(fontSize: 10, color: cDim)),
        ]),
        const SizedBox(height: 10),
        Text(lm.diagnostics,
            style: const TextStyle(fontSize: 10.5, color: cSub, height: 1.6)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF3A4348)),
                  minimumSize: const Size(0, 40),
                  shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(4)))),
              onPressed: _unbind,
              child: const Text('解除本机绑定（换机用）',
                  style: TextStyle(fontSize: 11.5, color: cSub)),
            ),
          ),
        ]),
      ]),
    );
  }

  Future<void> _unbind() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('解除本机绑定？', style: TextStyle(fontSize: 16, color: cText)),
        content: const Text('解除后需要重新输入授权码才能使用。设备与模板配置不受影响。',
            style: TextStyle(fontSize: 12, color: cSub)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: cDim))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7A2E2E), foregroundColor: Colors.white),
              child: const Text('解除')),
        ],
      ),
    );
    if (ok != true) return;
    await LicenseManager.instance.unbind();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LicenseGate()), (_) => false);
  }

  Widget _stat(String v, String label) => Expanded(
        child: Column(children: [
          Text(v,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: cData)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 10, color: cDim)),
        ]),
      );

  Future<void> _restore(({DateTime time, String json}) s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('恢复此快照？', style: TextStyle(fontSize: 16, color: cText)),
        content: Text('将把设备、模板、注释恢复为 ${_fmt(s.time)} 的状态。',
            style: const TextStyle(fontSize: 12, color: cSub)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: cDim))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: cAccent, foregroundColor: cAccentText),
              child: const Text('恢复')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await AppStore.instance.importJson(s.json);
    if (!mounted) return;
    _toast(done ? '已恢复到 ${_fmt(s.time)}' : '快照损坏，恢复失败');
    await _load();
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cCard,
        title: const Text('恢复出厂？', style: TextStyle(fontSize: 16, color: cText)),
        content: const Text('全部设备、模板改动、变量注释都会被清空，此操作可在快照里回滚。',
            style: TextStyle(fontSize: 12, color: cSub)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: cDim))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7A2E2E), foregroundColor: Colors.white),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    await AppStore.instance.resetAll();
    if (!mounted) return;
    _toast('已恢复出厂配置');
    await _load();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: cCard,
          duration: const Duration(seconds: 2)));
}

// ================== 变量注释导入 ==================
class SymbolImportScreen extends StatefulWidget {
  const SymbolImportScreen({super.key});
  @override
  State<SymbolImportScreen> createState() => _SymbolImportScreenState();
}

class _SymbolImportScreenState extends State<SymbolImportScreen> {
  final textC = TextEditingController();

  /// App 可无权限读写的外部目录：用 adb push 或文件管理器放进去即可
  List<String> get _scanDirs => <String>[
        kAppFilesDir,
        kDefaultFilesDir,
        '/storage/emulated/0/Download',
        '/sdcard/Download',
      ];

  @override
  void dispose() {
    textC.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final st = AppStore.instance;
    final n = st.importSymbolsAuto(textC.text);
    if (n > 0) await st.saveSymbols();
    if (!mounted) return;
    setState(() {});
    _toast(n == 0
        ? '没识别到「地址 + 注释」行，请检查粘贴内容'
        : '已导入 $n 条变量注释');
  }

  /// 从手机里的文件一次性导入（csv / txt / json）
  Future<void> _importFromFile() async {
    final files = <File>[];
    for (final p in _scanDirs) {
      final dir = Directory(p);
      if (!await dir.exists()) continue;
      try {
        await for (final e in dir.list()) {
          if (e is! File) continue;
          final n = e.path.toLowerCase();
          if (n.endsWith('.json') || n.endsWith('.csv') || n.endsWith('.txt')) {
            files.add(e);
          }
        }
      } catch (_) {}
    }
    if (files.isEmpty) {
      _toast('没找到变量表文件。把文件命名为 plc_symbols.csv / .txt / .json 放到 '
          'Android/data/com.example.plc_app/files/ 再点这里');
      return;
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

    File? pick = files.first;
    if (files.length > 1) {
      pick = await showDialog<File>(
        context: context,
        builder: (ctx) => SimpleDialog(
          backgroundColor: cCard,
          title: const Text('选择变量表文件',
              style: TextStyle(fontSize: 15, color: cText)),
          children: files
              .take(20)
              .map((f) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, f),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(f.uri.pathSegments.last,
                          style: const TextStyle(fontSize: 12.5, color: cText)),
                      Text(_sizeOf(f),
                          style: const TextStyle(fontSize: 9.5, color: cDim)),
                    ]),
                  ))
              .toList(),
        ),
      );
    }
    if (pick == null || !mounted) return;

    try {
      final text = await pick.readAsString();
      final st = AppStore.instance;
      final n = st.importSymbolsAuto(text);
      if (n > 0) await st.saveSymbols();
      if (!mounted) return;
      setState(() {});
      _toast(n == 0
          ? '${pick.uri.pathSegments.last} 里没解析出变量'
          : '已从 ${pick.uri.pathSegments.last} 导入 $n 条');
    } catch (e) {
      _toast('读文件失败：$e');
    }
  }

  String _sizeOf(File f) {
    try {
      final b = f.lengthSync();
      return b < 1024 ? '$b B' : '${(b / 1024).toStringAsFixed(1)} KB';
    } catch (_) {
      return '';
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg), backgroundColor: cCard, duration: const Duration(seconds: 3)));

  @override
  Widget build(BuildContext context) {
    final st = AppStore.instance;
    final cov = st.commentCoverage();
    final entries = st.symbols.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cBg,
        foregroundColor: cText,
        elevation: 0,
        title: const Text('变量注释',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          if (st.symbols.isNotEmpty)
            TextButton(
              onPressed: () async {
                setState(() => st.symbols.clear());
                await st.saveSymbols();
              },
              child: const Text('清空', style: TextStyle(color: cDim)),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: _box(const Color(0xFF171B1E), borderColor: const Color(0xFF262C30)),
              child: const Text(
                '一次性导入全部变量注释，导入后所有设备的点位按地址自动匹配显示。\n\n'
                '方式一（最快）：博图打开「PLC 变量」表 → Ctrl+A / Ctrl+C → 粘贴到下面。\n'
                '方式二：把导出的变量表存成 plc_symbols.csv / .txt / .json，'
                '放到 Android/data/com.example.plc_app/files/ 后点「从文件导入」。\n'
                '方式三：直接粘贴 JSON，如 [{"address":"%I0.0","comment":"一层到位"}]。',
                style: TextStyle(fontSize: 10.5, color: cSub, height: 1.65),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: _box(cCard),
              child: Row(children: [
                const Icon(Icons.rule, size: 14, color: cData),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '已覆盖 ${cov.matched} / ${cov.total} 个点位 · 符号表 ${st.symbols.length} 条',
                    style: const TextStyle(fontSize: 11.5, color: cSub),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: _box(cCardDark),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: TextField(
                controller: textC,
                maxLines: 9,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFFD9E0E4), fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: '名称\t数据类型\t逻辑地址\t注释\n'
                      '一层到位\tBool\t%I0.0\t1#提升机上位到位\n'
                      '或直接粘贴 {"%I0.0":"一层到位"}',
                  hintStyle: TextStyle(fontSize: 11, color: Color(0xFF4E5A61)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                flex: 3,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: cAccent,
                      foregroundColor: cAccentText,
                      minimumSize: const Size(0, 48),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6))),
                  onPressed: _apply,
                  child: const Text('解析并应用',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: cData,
                      minimumSize: const Size(0, 48),
                      side: const BorderSide(color: cLine),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6))),
                  onPressed: _importFromFile,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('从文件导入', style: TextStyle(fontSize: 12.5)),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Text('已识别 ${entries.length} 条',
                style: const TextStyle(fontSize: 11, color: cDim, letterSpacing: 1)),
            const SizedBox(height: 8),
            ...entries.take(60).map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    SizedBox(
                      width: 118,
                      child: Text(e.key,
                          style: const TextStyle(
                              fontSize: 11, fontFamily: 'monospace', color: cData)),
                    ),
                    Expanded(
                        child: Text(e.value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: cSub))),
                  ]),
                )),
            if (entries.length > 60)
              Text('…还有 ${entries.length - 60} 条',
                  style: const TextStyle(fontSize: 10, color: cDim)),
            const SizedBox(height: 16),
            const _AppFooter(),
          ],
        ),
      ),
    );
  }
}

// ================== 软件更新 ==================

Future<void> openUpdateSheet(BuildContext context, {ReleaseInfo? preset, bool auto = false}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: cCard,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
    builder: (_) => _UpdateSheet(preset: preset, auto: auto),
  );
}

enum _UpPhase { idle, checking, uptodate, available, downloading, ready, needPermission, error }

class _UpdateSheet extends StatefulWidget {
  final ReleaseInfo? preset;
  final bool auto;
  const _UpdateSheet({this.preset, required this.auto});
  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  _UpPhase phase = _UpPhase.idle;
  ReleaseInfo? release;
  String? error;
  String? apkPath;
  double progress = 0;
  int received = 0;
  int total = 0;
  final int currentBuild = int.tryParse(kAppBuild) ?? 0;

  @override
  void initState() {
    super.initState();
    if (widget.preset != null) {
      release = widget.preset;
      phase = _UpPhase.available;
    } else {
      _check();
    }
  }

  Future<void> _check() async {
    setState(() {
      phase = _UpPhase.checking;
      error = null;
    });
    final res = await UpdateService.check();
    if (!mounted) return;
    if (res.error != null) {
      setState(() {
        phase = _UpPhase.error;
        error = res.error;
      });
      return;
    }
    final r = res.release!;
    setState(() {
      release = r;
      phase = r.build > currentBuild ? _UpPhase.available : _UpPhase.uptodate;
    });
  }

  Future<void> _download() async {
    final r = release;
    if (r == null) return;
    setState(() {
      phase = _UpPhase.downloading;
      progress = 0;
      received = 0;
      total = r.size;
      error = null;
    });
    try {
      final path = await UpdateService.download(r, onProgress: (p, rec, tot) {
        if (!mounted) return;
        setState(() {
          progress = p.clamp(0, 1).toDouble();
          received = rec;
          total = tot;
        });
      });
      if (!mounted) return;
      setState(() {
        apkPath = path;
        phase = _UpPhase.ready;
      });
      // 下载完直接尝试拉起安装器，少一次点击
      await _install();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        phase = _UpPhase.error;
        error = '下载失败：$e';
      });
    }
  }

  Future<void> _install() async {
    final path = apkPath;
    if (path == null) return;
    try {
      final r = await UpdateService.install(path);
      if (!mounted) return;
      if (r == 'NEED_PERMISSION') {
        setState(() => phase = _UpPhase.needPermission);
      } else if (r == 'OK') {
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        phase = _UpPhase.error;
        error = '拉起安装器失败：$e';
      });
    }
  }

  String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final r = release;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('软件更新',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: cText)),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18, color: cDim),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              _tag('当前版本', 'v$kAppVersion（$kAppBuild）', cSub),
              const SizedBox(width: 8),
              if (r != null && phase != _UpPhase.checking)
                _tag('线上版本', 'v${r.version}（${r.build}）',
                    r.build > currentBuild ? cAccent : cGreen),
            ]),
            const SizedBox(height: 16),
            ..._body(r),
            const SizedBox(height: 14),
            Text('更新服务：$kUpdateBaseUrl',
                style: const TextStyle(fontSize: 10, color: cDim)),
          ]),
        ),
      ),
    );
  }

  Widget _tag(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: cBg, border: Border.all(color: cLine), borderRadius: BorderRadius.circular(4)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label ', style: const TextStyle(fontSize: 10.5, color: cDim)),
        Text(value, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  List<Widget> _body(ReleaseInfo? r) {
    switch (phase) {
      case _UpPhase.checking:
        return [
          Row(children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cAccent)),
            const SizedBox(width: 10),
            Text('正在检查…', style: TextStyle(fontSize: 13, color: cSub)),
          ]),
        ];
      case _UpPhase.idle:
        return [
          Text('点下面的按钮向服务器查询最新版本。', style: const TextStyle(fontSize: 12.5, color: cSub)),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: _primary('检查更新', _check)),
        ];
      case _UpPhase.uptodate:
        return [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: _box(cBg, borderColor: cLine),
            child: Row(children: [
              const Icon(Icons.check_circle, size: 18, color: cGreen),
              const SizedBox(width: 10),
              Text('已是最新版本', style: TextStyle(fontSize: 13, color: cText)),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: _ghost('再检查一次', _check)),
        ];
      case _UpPhase.available:
        return [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: _box(cBg, borderColor: cLine),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.system_update_alt, size: 16, color: cAccent),
                const SizedBox(width: 8),
                Text('发现新版本 v${r?.version ?? ''}',
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: cText)),
                const Spacer(),
                if ((r?.sizeText ?? '').isNotEmpty)
                  Text(r!.sizeText, style: const TextStyle(fontSize: 11, color: cDim)),
              ]),
              if ((r?.notes ?? '').isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(r!.notes, style: const TextStyle(fontSize: 12, height: 1.6, color: cSub)),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: _primary('立即更新（${r?.sizeText ?? '下载'}）', _download)),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: _ghost('稍后再说', () => Navigator.of(context).maybePop())),
            const SizedBox(width: 8),
            Expanded(
              child: _ghost('跳过此版本', () async {
                if (r != null) await UpdateService.skipBuild(r.build);
                if (mounted) Navigator.of(context).maybePop();
              }),
            ),
          ]),
        ];
      case _UpPhase.downloading:
        final pct = (progress * 100).toStringAsFixed(0);
        return [
          LinearProgressIndicator(
            value: progress <= 0 ? null : progress,
            minHeight: 6,
            backgroundColor: cLine,
            valueColor: const AlwaysStoppedAnimation(cAccent),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Text('下载中 $pct%', style: const TextStyle(fontSize: 12.5, color: cText)),
            const Spacer(),
            Text(total > 0 ? '${_mb(received)} / ${_mb(total)}' : _mb(received),
                style: const TextStyle(fontSize: 11, color: cDim)),
          ]),
          const SizedBox(height: 8),
          const Text('下载期间请保持网络通畅，包体约 50 MB。',
              style: TextStyle(fontSize: 11, color: cDim)),
        ];
      case _UpPhase.ready:
        return [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: _box(cBg, borderColor: cLine),
            child: Row(children: [
              const Icon(Icons.download_done, size: 18, color: cGreen),
              const SizedBox(width: 10),
              const Text('安装包已下载', style: TextStyle(fontSize: 13, color: cText)),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: _primary('安装新版本', _install)),
        ];
      case _UpPhase.needPermission:
        return [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: _box(const Color(0xFF241F14), borderColor: const Color(0xFF453B22)),
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('需要允许安装应用',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cAmber)),
              SizedBox(height: 6),
              Text('系统已打开设置页，请找到「PLC监控」并打开「允许安装未知应用」，然后返回点下面的按钮继续。',
                  style: TextStyle(fontSize: 12, height: 1.6, color: cSub)),
            ]),
          ),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: _primary('已授权，继续安装', _install)),
        ];
      case _UpPhase.error:
        return [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: _box(const Color(0xFF241416), borderColor: const Color(0xFF47232A)),
            child: Text(error ?? '未知错误',
                style: const TextStyle(fontSize: 12.5, height: 1.6, color: cRed)),
          ),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: _primary('重试', apkPath == null ? _check : _install)),
        ];
    }
  }

  Widget _primary(String text, VoidCallback onTap) => ElevatedButton(
        style: ElevatedButton.styleFrom(
            backgroundColor: cAccent,
            foregroundColor: cAccentText,
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
        onPressed: onTap,
        child: Text(text, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
      );

  Widget _ghost(String text, VoidCallback onTap) => OutlinedButton(
        style: OutlinedButton.styleFrom(
            side: const BorderSide(color: cLine),
            minimumSize: const Size(0, 44),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
        onPressed: onTap,
        child: Text(text, style: const TextStyle(fontSize: 13, color: cSub)),
      );
}
