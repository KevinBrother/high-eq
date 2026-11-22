import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'score.dart';

/// Axes clockwise from top, using raw percentages. Text provides the same data
/// without relying on colour, vision or the size of the chart.
///
/// T27 passes [beforePercentages] for a two-assessment comparison. The chart
/// still contains exactly the four WLEIS axes; training behaviour scores must
/// never be added here.
class AssessmentRadar extends StatelessWidget {
  const AssessmentRadar({
    super.key,
    required this.percentages,
    this.beforePercentages,
    this.title = '本次自评',
    this.currentLabel = '本次自评',
    this.beforeLabel = '上次自评',
  });
  final Map<String, double> percentages;
  final Map<String, double>? beforePercentages;
  final String title;
  final String currentLabel;
  final String beforeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final values = [for (final k in abilities.keys) percentages[k]!];
    final before = beforePercentages;
    final hasBefore =
        before != null && abilities.keys.every(before.containsKey);
    final beforeValues = hasBefore
        ? [for (final k in abilities.keys) before[k]!]
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.headlineSmall),
        ),
        if (beforeValues != null) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _Legend(color: c.outline, label: beforeLabel),
              _Legend(color: c.primary, label: currentLabel),
            ],
          ),
        ],
        const SizedBox(height: 12),
        // Names belong next to their axes. The full legend below remains the
        // accessible equivalent, so a screen reader needn't read them twice.
        ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, bounds) {
              final size = math.min(172.0, bounds.maxWidth * .48);
              Widget label(String key) => Text(
                abilities[key]!,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge,
              );
              return Column(
                children: [
                  label('SEA'),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(child: label('ROE')),
                      CustomPaint(
                        size: Size.square(size),
                        painter: _Radar(
                          values,
                          c.primary,
                          c.outlineVariant,
                          before: beforeValues,
                          beforeInk: c.outline,
                        ),
                      ),
                      Expanded(child: label('OEA')),
                    ],
                  ),
                  label('UOE'),
                  const SizedBox(height: 12),
                ],
              );
            },
          ),
        ),
        for (final (i, axis) in abilities.values.indexed)
          Semantics(
            label:
                '$axis，$currentLabel ${values[i].round()} 分，L${scoreLevel(values[i])}'
                '${beforeValues == null ? '' : '，$beforeLabel ${beforeValues[i].round()} 分'}',
            child: ExcludeSemantics(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('$axis · ${values[i].round()} / 100'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(descriptions[scoreLevel(values[i]) - 1]),
                    if (beforeValues != null)
                      Text('$beforeLabel · ${beforeValues[i].round()} / 100'),
                  ],
                ),
                trailing: Text('L${scoreLevel(values[i])}'),
              ),
            ),
          ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ExcludeSemantics(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.labelLarge),
    ],
  );
}

class _Radar extends CustomPainter {
  final List<double> values;
  final Color ink, grid;
  final List<double>? before;
  final Color? beforeInk;
  _Radar(this.values, this.ink, this.grid, {this.before, this.beforeInk});
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * .46;
    Offset point(int i, double f) {
      final a = (i - 1) * math.pi / 2;
      return center + Offset(math.cos(a), math.sin(a)) * radius * f;
    }

    Path polygon(List<double> lengths) => Path()
      ..addPolygon([for (var i = 0; i < 4; i++) point(i, lengths[i])], true);
    final pen = Paint()
      ..color = grid
      ..style = PaintingStyle.stroke;
    for (final r in [.25, .5, .75, 1.0]) {
      canvas.drawPath(polygon(List.filled(4, r)), pen);
    }
    for (var i = 0; i < 4; i++) {
      canvas.drawLine(center, point(i, 1), pen);
    }
    if (before case final previous?) {
      final oldShape = polygon(previous.map((v) => v / 100).toList());
      canvas.drawPath(
        oldShape,
        Paint()..color = (beforeInk ?? ink).withValues(alpha: .10),
      );
      canvas.drawPath(
        oldShape,
        Paint()
          ..color = beforeInk ?? ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final shape = polygon(values.map((v) => v / 100).toList());
    canvas.drawPath(shape, Paint()..color = ink.withValues(alpha: .18));
    canvas.drawPath(
      shape,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (var i = 0; i < 4; i++) {
      canvas.drawCircle(point(i, values[i] / 100), 3, Paint()..color = ink);
    }
  }

  @override
  bool shouldRepaint(_Radar old) =>
      values != old.values ||
      before != old.before ||
      ink != old.ink ||
      grid != old.grid ||
      beforeInk != old.beforeInk;
}
