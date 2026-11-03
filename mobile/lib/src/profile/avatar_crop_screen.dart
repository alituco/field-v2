import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ui/field_loading.dart';

import '../auth/fieldrush_auth_theme.dart';
import 'avatar_image.dart';

/// The square crop is stored; the rounded preview matches the player card.
class AvatarCropScreen extends StatefulWidget {
  const AvatarCropScreen({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  ui.Image? _image;
  String? _error;
  Offset _center = Offset.zero;
  double _zoom = 1;
  double _gestureZoom = 1;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final clean = await sanitizeAvatarImage(widget.bytes);
      final codec = await ui.instantiateImageCodec(clean);
      late final ui.Image image;
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image = image;
        _center = Offset(image.width / 2, image.height / 2);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not read this photo. Try another.');
      }
    }
  }

  Rect get _crop {
    final image = _image!;
    final side = math.min(image.width, image.height) / _zoom;
    final half = side / 2;
    return Rect.fromCenter(
      center: Offset(
        _center.dx.clamp(half, image.width - half),
        _center.dy.clamp(half, image.height - half),
      ),
      width: side,
      height: side,
    );
  }

  void _setZoom(double zoom) {
    _zoom = zoom.clamp(1, 4);
    _center = _crop.center;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final recorder = ui.PictureRecorder();
    final crop = _crop;
    final size = crop.width.round().clamp(1, 1200);
    Canvas(recorder).drawImageRect(
      _image!,
      crop,
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    ui.Image? cropped;
    try {
      cropped = await picture.toImage(size, size);
      final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Could not crop photo');
      if (mounted) {
        Navigator.of(
          context,
        ).pop(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not crop this photo. Try again.';
        });
      }
    } finally {
      cropped?.dispose();
      picture.dispose();
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: PopScope(
        canPop: !_saving,
        child: Scaffold(
          backgroundColor: FieldrushAuthTheme.cream,
          appBar: AppBar(
            title: const Text(
              'Crop photo',
              style: TextStyle(
                fontFamily: 'Outfit',
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -.44,
              ),
            ),
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Text(
                    'Drag to reposition. Pinch or use the slider to zoom.',
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: image == null
                        ? Center(
                            child: _error == null
                                ? const FieldLoadingIndicator(
                                    label: 'Loading photo',
                                  )
                                : Text(_error!),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final size = math.min(
                                340.0,
                                math.min(
                                  constraints.maxWidth,
                                  constraints.maxHeight,
                                ),
                              );
                              return Center(
                                child: Semantics(
                                  label: 'Profile photo crop preview',
                                  child: GestureDetector(
                                    key: const ValueKey('avatar-crop-preview'),
                                    onScaleStart: _saving
                                        ? null
                                        : (_) => _gestureZoom = _zoom,
                                    onScaleUpdate: _saving
                                        ? null
                                        : (details) {
                                            setState(() {
                                              _setZoom(
                                                _gestureZoom * details.scale,
                                              );
                                              _center -=
                                                  details.focalPointDelta *
                                                  (_crop.width / size);
                                              _center = _crop.center;
                                            });
                                          },
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(
                                        size * 19 / 58,
                                      ),
                                      child: CustomPaint(
                                        size: Size.square(size),
                                        painter: _CropPainter(image, _crop),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  if (image != null) ...[
                    const SizedBox(height: 20),
                    Slider(
                      key: const ValueKey('avatar-crop-zoom'),
                      value: _zoom,
                      min: 1,
                      max: 4,
                      label: '${_zoom.toStringAsFixed(1)}×',
                      semanticFormatterCallback: (value) =>
                          '${value.toStringAsFixed(1)} times zoom',
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _setZoom(value)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: _saving
                              ? null
                              : () => setState(() {
                                  _zoom = 1;
                                  _center = Offset(
                                    image.width / 2,
                                    image.height / 2,
                                  );
                                }),
                          child: const Text('Reset'),
                        ),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child: Text(_saving ? 'Saving…' : 'Use photo'),
                        ),
                      ],
                    ),
                    if (_error != null) Text(_error!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  const _CropPainter(this.image, this.crop);
  final ui.Image image;
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      crop,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.crop != crop;
}
