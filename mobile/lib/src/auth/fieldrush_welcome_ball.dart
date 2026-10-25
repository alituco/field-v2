import 'dart:math' as math;
import 'dart:ui';

/// Paints the original welcome ball in the HTML artwork's 372px coordinate space.
///
/// Reuses the 21 inline SVG panels in the original `Fieldrush App(9).html`
/// welcome artwork. Panel
/// coordinates, order, fills, and seams below are preserved from that source.
/// The surrounding CSS supplies the circle, shadow, and two radial gradients.
void paintFieldrushWelcomeBall(Canvas canvas) {
  // CSS box-shadow: -11px 14px 18px rgba(0, 0, 0, .3). CSS blur radius is
  // twice the Gaussian standard deviation used by MaskFilter.blur.
  canvas.drawCircle(
    _ballCenter + const Offset(-11, 14),
    _ballRadius,
    Paint()
      ..color = const Color.fromRGBO(0, 0, 0, .3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
  );

  canvas.save();
  canvas.clipPath(Path()..addOval(_ballBounds));
  canvas.drawCircle(
    _ballCenter,
    _ballRadius,
    Paint()..color = const Color(0xFFF8F7F2),
  );

  canvas.save();
  canvas.translate(_ballCenter.dx, _ballCenter.dy);
  canvas.scale(_ballRadius);
  for (final panel in _ballPanels) {
    canvas.drawPath(panel.path, Paint()..color = panel.fill);
    canvas.drawPath(
      panel.path,
      Paint()
        ..color = panel.seam
        ..strokeWidth = panel.seamWidth
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }
  canvas.restore();

  // CSS lists the white highlight first, above the black shading layer.
  _paintCssCircleGradient(
    canvas,
    centerFraction: const Offset(.4, .36),
    colors: const [
      Color.fromRGBO(0, 0, 0, 0),
      Color.fromRGBO(0, 0, 0, .14),
      Color.fromRGBO(0, 0, 0, .4),
    ],
    stops: const [.46, .72, 1],
  );
  _paintCssCircleGradient(
    canvas,
    centerFraction: const Offset(.32, .26),
    colors: const [
      Color.fromRGBO(255, 255, 255, .55),
      Color.fromRGBO(255, 255, 255, .12),
      Color.fromRGBO(255, 255, 255, 0),
    ],
    stops: const [0, .22, .4],
  );
  canvas.restore();
}

const _ballCenter = Offset(240.2, 312.3);
const _ballRadius = 39.0;
const _ballBounds = Rect.fromLTWH(201.2, 273.3, 78, 78);

void _paintCssCircleGradient(
  Canvas canvas, {
  required Offset centerFraction,
  required List<Color> colors,
  required List<double> stops,
}) {
  final x = _ballBounds.width * centerFraction.dx;
  final y = _ballBounds.height * centerFraction.dy;
  final farthestX = math.max(x, _ballBounds.width - x);
  final farthestY = math.max(y, _ballBounds.height - y);
  // An unqualified CSS `circle` uses farthest-corner sizing: each stop's
  // percentage is measured against the distance to the farthest box corner.
  final radius = math.sqrt(farthestX * farthestX + farthestY * farthestY);
  canvas.drawRect(
    _ballBounds,
    Paint()
      ..shader = Gradient.radial(
        _ballBounds.topLeft + Offset(x, y),
        radius,
        colors,
        stops,
      ),
  );
}

class _BallPanel {
  _BallPanel(List<Offset> points, this.fill, this.seam, this.seamWidth)
    : path = (Path()..addPolygon(points, true));

  final Path path;
  final Color fill;
  final Color seam;
  final double seamWidth;
}

// Every M/L/Z vertex is retained in SVG draw order. Paths are constructed once
// and painted at the original 39px scale, including normalized seam widths.
final _ballPanels = <_BallPanel>[
  _BallPanel(
    const [
      Offset(-0.507, -0.862),
      Offset(-0.431, -0.902),
      Offset(-0.354, -0.935),
      Offset(-0.276, -0.960),
      Offset(-0.150, -0.989),
      Offset(-0.019, -1.000),
      Offset(0.110, -0.994),
      Offset(0.124, -0.992),
      Offset(0.139, -0.990),
      Offset(0.155, -0.988),
      Offset(0.018, -1.000),
      Offset(-0.132, -0.991),
      Offset(-0.284, -0.959),
      Offset(-0.369, -0.929),
      Offset(-0.443, -0.896),
    ],
    const Color(0xFFD9B04F),
    const Color.fromRGBO(20, 20, 20, .35),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(0.564, -0.826),
      Offset(0.429, -0.903),
      Offset(0.289, -0.957),
      Offset(0.155, -0.988),
      Offset(0.139, -0.990),
      Offset(0.124, -0.992),
      Offset(0.110, -0.994),
      Offset(0.212, -0.977),
      Offset(0.311, -0.944),
      Offset(0.404, -0.894),
      Offset(0.520, -0.840),
      Offset(0.629, -0.769),
      Offset(0.725, -0.686),
      Offset(0.749, -0.662),
      Offset(0.772, -0.636),
      Offset(0.795, -0.607),
      Offset(0.733, -0.680),
      Offset(0.656, -0.754),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(-0.885, -0.440),
      Offset(-0.870, -0.493),
      Offset(-0.842, -0.539),
      Offset(-0.812, -0.584),
      Offset(-0.866, -0.500),
      Offset(-0.915, -0.404),
      Offset(-0.955, -0.297),
      Offset(-0.985, -0.173),
      Offset(-0.999, -0.052),
      Offset(-0.998, 0.061),
      Offset(-1.000, 0.023),
      Offset(-1.000, -0.015),
      Offset(-0.991, -0.052),
      Offset(-0.973, -0.185),
      Offset(-0.937, -0.317),
    ],
    const Color(0xFF22406F),
    const Color.fromRGBO(20, 20, 20, .35),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(0.792, 0.570),
      Offset(0.703, 0.669),
      Offset(0.600, 0.757),
      Offset(0.487, 0.830),
      Offset(0.425, 0.889),
      Offset(0.353, 0.934),
      Offset(0.277, 0.961),
      Offset(0.318, 0.948),
      Offset(0.361, 0.932),
      Offset(0.407, 0.914),
      Offset(0.535, 0.845),
      Offset(0.657, 0.754),
      Offset(0.763, 0.646),
      Offset(0.816, 0.578),
      Offset(0.860, 0.511),
      Offset(0.895, 0.446),
      Offset(0.870, 0.493),
      Offset(0.838, 0.536),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(0.999, 0.052),
      Offset(0.999, -0.036),
      Offset(0.992, -0.129),
      Offset(0.974, -0.227),
      Offset(0.931, -0.364),
      Offset(0.870, -0.493),
      Offset(0.795, -0.607),
      Offset(0.772, -0.636),
      Offset(0.749, -0.662),
      Offset(0.725, -0.686),
      Offset(0.774, -0.611),
      Offset(0.810, -0.523),
      Offset(0.830, -0.428),
      Offset(0.891, -0.310),
      Offset(0.936, -0.185),
      Offset(0.963, -0.059),
      Offset(0.990, -0.022),
      Offset(1.000, 0.015),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(-0.998, 0.061),
      Offset(-0.981, 0.194),
      Offset(-0.944, 0.329),
      Offset(-0.889, 0.458),
      Offset(-0.840, 0.543),
      Offset(-0.785, 0.620),
      Offset(-0.726, 0.687),
      Offset(-0.748, 0.661),
      Offset(-0.757, 0.623),
      Offset(-0.753, 0.575),
      Offset(-0.812, 0.461),
      Offset(-0.857, 0.335),
      Offset(-0.886, 0.206),
      Offset(-0.938, 0.122),
      Offset(-0.974, 0.035),
      Offset(-0.991, -0.052),
      Offset(-1.000, -0.015),
      Offset(-1.000, 0.023),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(-0.885, -0.440),
      Offset(-0.830, -0.493),
      Offset(-0.758, -0.537),
      Offset(-0.674, -0.571),
      Offset(-0.583, -0.670),
      Offset(-0.480, -0.758),
      Offset(-0.370, -0.831),
      Offset(-0.345, -0.890),
      Offset(-0.313, -0.934),
      Offset(-0.276, -0.960),
      Offset(-0.354, -0.935),
      Offset(-0.431, -0.902),
      Offset(-0.507, -0.862),
      Offset(-0.621, -0.784),
      Offset(-0.725, -0.689),
      Offset(-0.812, -0.584),
      Offset(-0.842, -0.539),
      Offset(-0.870, -0.493),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(0.999, 0.052),
      Offset(1.000, 0.015),
      Offset(0.990, -0.022),
      Offset(0.963, -0.059),
      Offset(0.939, 0.049),
      Offset(0.897, 0.157),
      Offset(0.840, 0.261),
      Offset(0.839, 0.371),
      Offset(0.823, 0.476),
      Offset(0.792, 0.570),
      Offset(0.838, 0.536),
      Offset(0.870, 0.493),
      Offset(0.895, 0.446),
      Offset(0.947, 0.320),
      Offset(0.982, 0.187),
    ],
    const Color(0xFF1A1915),
    const Color(0xFFD9B25C),
    0.045,
  ),
  _BallPanel(
    const [
      Offset(-0.753, 0.575),
      Offset(-0.757, 0.623),
      Offset(-0.748, 0.661),
      Offset(-0.726, 0.687),
      Offset(-0.633, 0.774),
      Offset(-0.526, 0.850),
      Offset(-0.411, 0.911),
      Offset(-0.313, 0.950),
      Offset(-0.212, 0.977),
      Offset(-0.110, 0.992),
      Offset(-0.122, 0.973),
      Offset(-0.131, 0.935),
      Offset(-0.138, 0.881),
      Offset(-0.250, 0.827),
      Offset(-0.359, 0.756),
      Offset(-0.459, 0.673),
      Offset(-0.567, 0.652),
      Offset(-0.667, 0.619),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(0.231, 0.781),
      Offset(0.110, 0.829),
      Offset(-0.015, 0.863),
      Offset(-0.138, 0.881),
      Offset(-0.131, 0.935),
      Offset(-0.122, 0.973),
      Offset(-0.110, 0.992),
      Offset(0.019, 0.999),
      Offset(0.150, 0.989),
      Offset(0.277, 0.961),
      Offset(0.353, 0.934),
      Offset(0.425, 0.889),
      Offset(0.487, 0.830),
      Offset(0.409, 0.828),
      Offset(0.322, 0.812),
    ],
    const Color(0xFF8E5A33),
    const Color.fromRGBO(20, 20, 20, .35),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(-0.076, -0.733),
      Offset(0.053, -0.757),
      Offset(0.185, -0.768),
      Offset(0.310, -0.765),
      Offset(0.348, -0.823),
      Offset(0.379, -0.867),
      Offset(0.404, -0.894),
      Offset(0.311, -0.944),
      Offset(0.212, -0.977),
      Offset(0.110, -0.994),
      Offset(-0.019, -1.000),
      Offset(-0.150, -0.989),
      Offset(-0.276, -0.960),
      Offset(-0.313, -0.934),
      Offset(-0.345, -0.890),
      Offset(-0.370, -0.831),
      Offset(-0.277, -0.813),
      Offset(-0.177, -0.780),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(0.830, -0.428),
      Offset(0.810, -0.523),
      Offset(0.774, -0.611),
      Offset(0.725, -0.686),
      Offset(0.629, -0.769),
      Offset(0.520, -0.840),
      Offset(0.404, -0.894),
      Offset(0.379, -0.867),
      Offset(0.348, -0.823),
      Offset(0.310, -0.765),
      Offset(0.405, -0.681),
      Offset(0.495, -0.583),
      Offset(0.574, -0.476),
      Offset(0.671, -0.469),
      Offset(0.758, -0.452),
    ],
    const Color(0xFFAEB7BF),
    const Color.fromRGBO(20, 20, 20, .35),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(-0.991, -0.052),
      Offset(-0.974, 0.035),
      Offset(-0.938, 0.122),
      Offset(-0.886, 0.206),
      Offset(-0.831, 0.166),
      Offset(-0.759, 0.122),
      Offset(-0.675, 0.076),
      Offset(-0.651, -0.055),
      Offset(-0.615, -0.187),
      Offset(-0.569, -0.313),
      Offset(-0.615, -0.406),
      Offset(-0.651, -0.494),
      Offset(-0.674, -0.571),
      Offset(-0.758, -0.537),
      Offset(-0.830, -0.493),
      Offset(-0.885, -0.440),
      Offset(-0.937, -0.317),
      Offset(-0.973, -0.185),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(0.487, 0.830),
      Offset(0.600, 0.757),
      Offset(0.703, 0.669),
      Offset(0.792, 0.570),
      Offset(0.823, 0.476),
      Offset(0.839, 0.371),
      Offset(0.840, 0.261),
      Offset(0.769, 0.250),
      Offset(0.682, 0.233),
      Offset(0.584, 0.213),
      Offset(0.491, 0.305),
      Offset(0.388, 0.393),
      Offset(0.279, 0.472),
      Offset(0.268, 0.586),
      Offset(0.252, 0.691),
      Offset(0.231, 0.781),
      Offset(0.322, 0.812),
      Offset(0.409, 0.828),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(-0.459, 0.673),
      Offset(-0.452, 0.580),
      Offset(-0.435, 0.476),
      Offset(-0.411, 0.364),
      Offset(-0.508, 0.273),
      Offset(-0.598, 0.175),
      Offset(-0.675, 0.076),
      Offset(-0.759, 0.122),
      Offset(-0.831, 0.166),
      Offset(-0.886, 0.206),
      Offset(-0.857, 0.335),
      Offset(-0.812, 0.461),
      Offset(-0.753, 0.575),
      Offset(-0.667, 0.619),
      Offset(-0.567, 0.652),
    ],
    const Color(0xFFD9B04F),
    const Color.fromRGBO(20, 20, 20, .35),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(0.574, -0.476),
      Offset(0.543, -0.377),
      Offset(0.501, -0.268),
      Offset(0.451, -0.156),
      Offset(0.504, -0.034),
      Offset(0.549, 0.091),
      Offset(0.584, 0.213),
      Offset(0.682, 0.233),
      Offset(0.769, 0.250),
      Offset(0.840, 0.261),
      Offset(0.897, 0.157),
      Offset(0.939, 0.049),
      Offset(0.963, -0.059),
      Offset(0.936, -0.185),
      Offset(0.891, -0.310),
      Offset(0.830, -0.428),
      Offset(0.758, -0.452),
      Offset(0.671, -0.469),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(-0.370, -0.831),
      Offset(-0.480, -0.758),
      Offset(-0.583, -0.670),
      Offset(-0.674, -0.571),
      Offset(-0.651, -0.494),
      Offset(-0.615, -0.406),
      Offset(-0.569, -0.313),
      Offset(-0.454, -0.352),
      Offset(-0.329, -0.387),
      Offset(-0.200, -0.413),
      Offset(-0.161, -0.529),
      Offset(-0.120, -0.638),
      Offset(-0.076, -0.733),
      Offset(-0.177, -0.780),
      Offset(-0.277, -0.813),
    ],
    const Color(0xFF22406F),
    const Color.fromRGBO(20, 20, 20, .35),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(-0.042, 0.264),
      Offset(-0.168, 0.303),
      Offset(-0.293, 0.337),
      Offset(-0.411, 0.364),
      Offset(-0.435, 0.476),
      Offset(-0.452, 0.580),
      Offset(-0.459, 0.673),
      Offset(-0.359, 0.756),
      Offset(-0.250, 0.827),
      Offset(-0.138, 0.881),
      Offset(-0.015, 0.863),
      Offset(0.110, 0.829),
      Offset(0.231, 0.781),
      Offset(0.252, 0.691),
      Offset(0.268, 0.586),
      Offset(0.279, 0.472),
      Offset(0.175, 0.410),
      Offset(0.066, 0.340),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(0.451, -0.156),
      Offset(0.501, -0.268),
      Offset(0.543, -0.377),
      Offset(0.574, -0.476),
      Offset(0.495, -0.583),
      Offset(0.405, -0.681),
      Offset(0.310, -0.765),
      Offset(0.185, -0.768),
      Offset(0.053, -0.757),
      Offset(-0.076, -0.733),
      Offset(-0.120, -0.638),
      Offset(-0.161, -0.529),
      Offset(-0.200, -0.413),
      Offset(-0.114, -0.323),
      Offset(-0.024, -0.225),
      Offset(0.064, -0.125),
      Offset(0.196, -0.138),
      Offset(0.328, -0.148),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(0.064, -0.125),
      Offset(-0.024, -0.225),
      Offset(-0.114, -0.323),
      Offset(-0.200, -0.413),
      Offset(-0.329, -0.387),
      Offset(-0.454, -0.352),
      Offset(-0.569, -0.313),
      Offset(-0.615, -0.187),
      Offset(-0.651, -0.055),
      Offset(-0.675, 0.076),
      Offset(-0.598, 0.175),
      Offset(-0.508, 0.273),
      Offset(-0.411, 0.364),
      Offset(-0.293, 0.337),
      Offset(-0.168, 0.303),
      Offset(-0.042, 0.264),
      Offset(-0.007, 0.137),
      Offset(0.029, 0.005),
    ],
    const Color(0xFFF8F7F2),
    const Color.fromRGBO(30, 30, 28, .3),
    0.026,
  ),
  _BallPanel(
    const [
      Offset(-0.042, 0.264),
      Offset(0.066, 0.340),
      Offset(0.175, 0.410),
      Offset(0.279, 0.472),
      Offset(0.388, 0.393),
      Offset(0.491, 0.305),
      Offset(0.584, 0.213),
      Offset(0.549, 0.091),
      Offset(0.504, -0.034),
      Offset(0.451, -0.156),
      Offset(0.328, -0.148),
      Offset(0.196, -0.138),
      Offset(0.064, -0.125),
      Offset(0.029, 0.005),
      Offset(-0.007, 0.137),
    ],
    const Color(0xFF1A1915),
    const Color(0xFFD9B25C),
    0.045,
  ),
];
