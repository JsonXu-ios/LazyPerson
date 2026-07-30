/// HUD 底部浮层外壳（稿 11 / 稿资产信息共用）：顶部 20 圆角 + accent 上边框
/// + 竖向渐变底 + 40×3 抓手。自选与资产信息两个 sheet 用同一个外壳，
/// 避免两处各写一遍装饰。
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class HudSheet extends StatelessWidget {
  final Widget child;

  /// 占屏高比例（稿 11 是 712/880 ≈ 0.81）
  final double heightFactor;

  const HudSheet({super.key, required this.child, this.heightFactor = 0.81});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * heightFactor,
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: AppColors.accent.withValues(alpha: 0.28)),
        ),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF102142), AppColors.background],
          stops: [0.0, 0.55],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 3,
              margin: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: AppColors.accent.withValues(alpha: 0.45),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
