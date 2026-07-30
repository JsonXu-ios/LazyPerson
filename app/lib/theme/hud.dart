/// HUD 视觉基元：卡片、发光文字、四角描边、分段进度条、Chip。
/// 新增文件，放在 lib/theme/hud.dart。所有 1d 稿里的“发光/玻璃”效果都从这里来，
/// 业务 widget 只负责组合，不要在各处手写 BoxShadow。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// HUD 卡片：半透明底 + 1px 20% accent 描边 + 可选发光。
/// 对应 1d 稿的自选列表项、副图容器、雷达面板、底部浮层。
class HudPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// 强调色：给一张卡定调（涨=rise、跌=fall、选中=accent）。null 为中性卡。
  final Color? tint;
  final bool active;
  final bool glow;
  final VoidCallback? onTap;

  const HudPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.radius = 12,
    this.tint,
    this.active = false,
    this.glow = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final edge = tint ?? AppColors.accent;
    final panel = Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: active || tint != null
              ? edge.withValues(alpha: active ? 0.50 : 0.35)
              : AppColors.hudBorder,
        ),
        gradient: tint == null
            ? null
            : LinearGradient(
                colors: [edge.withValues(alpha: 0.12), AppColors.hudPanel],
              ),
        color: tint == null ? AppColors.hudPanel : null,
        boxShadow: glow
            ? [
                BoxShadow(
                  color: edge.withValues(alpha: 0.25),
                  blurRadius: 20,
                  spreadRadius: -2,
                ),
              ]
            : null,
      ),
      child: child,
    );
    if (onTap == null) return panel;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: panel,
    );
  }
}

/// 发光数字/标题。只给关键数字用（现价、涨幅、命中数），别满屏发光。
class GlowText extends StatelessWidget {
  final String text;
  final double size;
  final Color color;
  final FontWeight weight;
  final bool mono;
  final double blur;

  const GlowText(
    this.text, {
    super.key,
    this.size = 30,
    this.color = AppColors.rise,
    this.weight = FontWeight.w700,
    this.mono = true,
    this.blur = 22,
  });

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: size,
      height: 1.0,
      color: color,
      fontWeight: weight,
      shadows: [
        Shadow(color: color.withValues(alpha: 0.55), blurRadius: blur),
      ],
    );
    return Text(
      text,
      style: mono
          ? hudMono.copyWith(
              fontSize: base.fontSize,
              height: 1.0,
              color: base.color,
              fontWeight: base.fontWeight,
              shadows: base.shadows,
            )
          : base,
    );
  }
}

/// 图表四角描边（HUD 取景框）。包在 KlineChart 外面即可。
class HudBrackets extends StatelessWidget {
  final Widget child;
  final double length;
  final Color color;

  const HudBrackets({
    super.key,
    required this.child,
    this.length = 14,
    this.color = AppColors.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _BracketPainter(
                length: length,
                color: color.withValues(alpha: 0.65),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BracketPainter extends CustomPainter {
  final double length;
  final Color color;

  _BracketPainter({required this.length, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final l = length;
    final w = size.width;
    final h = size.height;
    void corner(Offset a, Offset b, Offset c) {
      canvas.drawPath(Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy)..lineTo(c.dx, c.dy), paint);
    }

    corner(Offset(0, l), Offset.zero, Offset(l, 0));
    corner(Offset(w - l, 0), Offset(w, 0), Offset(w, l));
    corner(Offset(0, h - l), Offset(0, h), Offset(l, h));
    corner(Offset(w - l, h), Offset(w, h), Offset(w, h - l));
  }

  @override
  bool shouldRepaint(covariant _BracketPainter old) =>
      old.length != length || old.color != color;
}

/// 分段同步进度条（替换 LinearProgressIndicator）：22 格，亮格发光。
class HudSegmentBar extends StatelessWidget {
  final double? ratio;
  final int segments;
  final Color color;

  const HudSegmentBar({
    super.key,
    required this.ratio,
    this.segments = 22,
    this.color = AppColors.warn,
  });

  @override
  Widget build(BuildContext context) {
    final filled = ratio == null ? -1 : (ratio!.clamp(0, 1) * segments).round();
    return Row(
      children: [
        for (var i = 0; i < segments; i++) ...[
          Expanded(
            child: Container(
              height: 5,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(1),
                color: i < filled
                    ? color
                    : AppColors.panelBorder.withValues(alpha: 0.9),
                boxShadow: i < filled
                    ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)]
                    : null,
              ),
            ),
          ),
          if (i != segments - 1) const SizedBox(width: 2),
        ],
      ],
    );
  }
}

/// 胶囊 Chip：市场 Tab、排序、周期切换共用。
class HudChip extends StatelessWidget {
  final String label;
  final String? sub;
  final bool active;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  const HudChip({
    super.key,
    required this.label,
    this.sub,
    this.active = false,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: active ? AppColors.hudFillActive : Colors.transparent,
          border: Border.all(
            color: active ? AppColors.hudBorderActive : AppColors.hudBorder,
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.18),
                    blurRadius: 18,
                    spreadRadius: -4,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: FontSize.secondaryNumber,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? AppColors.text : AppColors.textMuted,
              ),
            ),
            if (sub != null)
              Text(
                sub!,
                style: mono(
                  size: FontSize.capsLabel,
                  color: active ? AppColors.accent : AppColors.textDim,
                  weight: FontWeight.w500,
                  letterSpacing: 0.8,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// LIVE 徽标（顶栏右侧的呼吸点）
class HudLiveBadge extends StatelessWidget {
  final bool live;
  final String label;

  const HudLiveBadge({super.key, required this.live, this.label = 'LIVE'});

  @override
  Widget build(BuildContext context) {
    final color = live ? AppColors.fall : AppColors.textDim;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withValues(alpha: 0.12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [BoxShadow(color: color, blurRadius: 8)],
            ),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: mono(
                  size: FontSize.capsLabel,
                  color: color,
                  weight: FontWeight.w600,
                  letterSpacing: 1.4)),
        ],
      ),
    );
  }
}

/// 画布发光：先用 MaskFilter 画一遍模糊，再叠实心。
/// 用法（_KlinePainter 内）：
///   drawGlowing(canvas, AppColors.rise, (p) => canvas.drawRect(rect, p));
void drawGlowing(
  Canvas canvas,
  Color color,
  void Function(Paint paint) draw, {
  double sigma = 3.0,
  double alpha = 0.55,
  double strokeWidth = 0,
}) {
  final glow = Paint()
    ..color = color.withValues(alpha: alpha)
    ..maskFilter = ui.MaskFilter.blur(BlurStyle.normal, sigma);
  if (strokeWidth > 0) {
    glow
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
  }
  draw(glow);
  final solid = Paint()..color = color;
  if (strokeWidth > 0) {
    solid
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
  }
  draw(solid);
}

/// 档位刻度轨（顶部“档位 ▮▮▯▯▯▯▯▯ +29.4%”）
class HudLevelRail extends StatelessWidget {
  final int total;
  final int activeIndex;

  const HudLevelRail({super.key, this.total = 8, required this.activeIndex});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < total; i++) ...[
          Container(
            width: 4,
            height: i == activeIndex ? 13 : 9,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(1),
              color: i == activeIndex
                  ? AppColors.warn
                  : AppColors.textFaint.withValues(alpha: 0.35),
              boxShadow: i == activeIndex
                  ? [BoxShadow(color: AppColors.warn.withValues(alpha: 0.7), blurRadius: 8)]
                  : null,
            ),
          ),
          if (i != total - 1) const SizedBox(width: 2),
        ],
      ],
    );
  }
}

double hudMaxOf(Iterable<double> values) =>
    values.isEmpty ? 0 : values.reduce(math.max);
