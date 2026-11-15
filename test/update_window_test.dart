// 更新时段边界测试：北京时间 10-12 / 14-16 / 21-23 共 6 小时
import 'package:flutter_test/flutter_test.dart';
import 'package:plc_app/update.dart';

void main() {
  test('更新时段边界', () {
    // (月,日,时,分, 期望)
    final cases = [
      (9, 59, false),   // 09:59 不在
      (10, 0, true),    // 10:00 开
      (10, 30, true),
      (11, 59, true),
      (12, 0, false),   // 12:00 关
      (13, 30, false),
      (14, 0, true),    // 14:00 开
      (15, 30, true),
      (16, 0, false),   // 16:00 关
      (20, 59, false),
      (21, 0, true),    // 21:00 开
      (22, 59, true),
      (23, 0, false),   // 23:00 关
      (3, 0, false),    // 凌晨
    ];
    for (final c in cases) {
      final t = DateTime.utc(2026, 11, 15, c.$1, c.$2);
      expect(UpdateService.inWindow(t), c.$3,
          reason: '${c.$1}:${c.$2} 应为 ${c.$3}');
    }
    // 累计开放时长 = 2+2+2 = 6 小时
    var hours = 0;
    for (var h = 0; h < 24; h++) {
      if (UpdateService.inWindow(DateTime.utc(2026, 11, 15, h, 0))) hours++;
    }
    expect(hours, 6);
  });

  test('下次开放提示', () {
    expect(UpdateService.nextWindowText(DateTime.utc(2026, 11, 15, 9, 0)),
        contains('今天 10:00'));
    expect(UpdateService.nextWindowText(DateTime.utc(2026, 11, 15, 15, 0)),
        contains('当前时段内'));
    expect(UpdateService.nextWindowText(DateTime.utc(2026, 11, 15, 20, 0)),
        contains('今天 21:00'));
    expect(UpdateService.nextWindowText(DateTime.utc(2026, 11, 15, 23, 30)),
        contains('明天 10:00'));
  });
}
