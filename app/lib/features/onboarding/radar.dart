import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'score.dart';

/// Axes clockwise from top, using raw percentages. Text provides the same data
/// without relying on colour, vision or the size of the chart.
class AssessmentRadar extends StatelessWidget {
  const AssessmentRadar({super.key, required this.percentages});
  final Map<String, double> percentages;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final values = [for (final k in abilities.keys) percentages[k]!];
    return Column(
      children: [
        Text('本次自评', style: Theme.of(context).textTheme.headlineSmall),
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
                style: Theme.of(context).textTheme.labelLarge,
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
                        painter: _Radar(values, c.primary, c.outlineVariant),
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
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('$axis · ${values[i].round()} / 100'),
            subtitle: Text(descriptions[scoreLevel(values[i]) - 1]),
            trailing: Text('L${scoreLevel(values[i])}'),
          ),
      ],
    );
  }
}

class _Radar extends CustomPainter {
  final List<double> values;
  final Color ink, grid;
  _Radar(this.values, this.ink, this.grid);
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
    final shape = polygon(values.map((v) => v / 100).toList());
    canvas.drawPath(shape, Paint()..color = ink.withValues(alpha: .18));
    canvas.drawPath(
      shape,
      pen
        ..color = ink
        ..strokeWidth = 2,
    );
    for (var i = 0; i < 4; i++) {
      canvas.drawCircle(point(i, values[i] / 100), 3, Paint()..color = ink);
    }
  }

  @override
  bool shouldRepaint(_Radar old) =>
      values != old.values || ink != old.ink || grid != old.grid;
}
