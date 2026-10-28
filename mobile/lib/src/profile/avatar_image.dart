import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

const _maximumAvatarBytes = 5 * 1024 * 1024;
const _maximumAvatarDimension = 1200;

/// Retain only decoded pixels, never the picked file's EXIF, GPS or text data.
/// The native decoder applies orientation before the pixels are PNG-encoded.
Future<Uint8List> sanitizeAvatarImage(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > _maximumAvatarBytes) {
    throw const FormatException('Choose a photo smaller than 5 MB.');
  }

  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longestSide = math.max(descriptor.width, descriptor.height);
    final scale = math.min(1.0, _maximumAvatarDimension / longestSide);
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * scale).round()),
      targetHeight: math.max(1, (descriptor.height * scale).round()),
    );
    image = (await codec.getNextFrame()).image;

    // Animated codecs may ignore the requested decode size. Enforce the limit
    // on the actual first frame as well as on the decoder request.
    final decodedLongestSide = math.max(image.width, image.height);
    if (decodedLongestSide > _maximumAvatarDimension) {
      final resized = await _resize(
        image,
        _maximumAvatarDimension / decodedLongestSide,
      );
      image.dispose();
      image = resized;
    }

    while (true) {
      final currentImage = image!;
      final encoded = await currentImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (encoded == null) {
        throw const FormatException('Could not read this photo. Try another.');
      }
      if (encoded.lengthInBytes <= _maximumAvatarBytes) {
        return encoded.buffer.asUint8List(
          encoded.offsetInBytes,
          encoded.lengthInBytes,
        );
      }
      // An uncompressed PNG can exceed the bucket limit even when its source
      // was a small JPEG. Reduce pixels and encode again before any upload.
      final resized = await _resize(currentImage, 0.75);
      currentImage.dispose();
      image = resized;
    }
  } catch (_) {
    throw const FormatException('Could not read this photo. Try another.');
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<ui.Image> _resize(ui.Image image, double scale) async {
  final width = math.max(1, (image.width * scale).round());
  final height = math.max(1, (image.height * scale).round());
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}
