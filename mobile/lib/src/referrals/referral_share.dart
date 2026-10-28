import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

Future<void> shareFieldrushReferralCode(
  BuildContext context,
  String code,
) async {
  final box = context.findRenderObject();
  final origin = box is RenderBox && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  await SharePlus.instance.share(
    ShareParams(
      text:
          'Join me on Fieldrush! My referral code is $code. '
          'Add it in You within 7 days of signing up. https://fieldrush.gg',
      subject: 'Play with me on Fieldrush',
      sharePositionOrigin: origin,
    ),
  );
}
