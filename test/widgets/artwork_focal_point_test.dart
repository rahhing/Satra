import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/widgets/artwork_focal_point.dart';

void main() {
  const width = 64;
  const height = 36;

  ByteData painting({required bool withSubject}) {
    final data = ByteData(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final index = (y * width + x) * 4;
        final inSubject = withSubject && x >= 42 && x < 58 && y >= 5 && y < 19;
        final shade = inSubject && ((x ~/ 3) + (y ~/ 3)).isEven ? 210 : 48;
        for (var rgb = 0; rgb < 3; rgb++) {
          data.setUint8(index + rgb, shade);
        }
        data.setUint8(index + 3, 255);
      }
    }
    return data;
  }

  test('focus follows an off-centre patch of detail and defaults to centre on flat art', () {
    expect(ArtworkFocalPoint.estimate(painting(withSubject: false), width, height), const Offset(.5, .5));
    final point = ArtworkFocalPoint.estimate(painting(withSubject: true), width, height);
    expect(point.dx, greaterThan(.72));
    expect(point.dy, lessThan(.42));
  });

  test('cover crop centres the focus on the cropped axis and clamps at the edge', () {
    const source = Size(1600, 900);
    const output = Size(400, 400);
    expect(ArtworkFocalPoint.alignment(const Offset(.5, .5), source, output, BoxFit.cover), Alignment.center);
    expect(ArtworkFocalPoint.alignment(const Offset(.92, .2), source, output, BoxFit.cover), Alignment.centerRight);
    expect(ArtworkFocalPoint.alignment(const Offset(.92, .2), source, source, BoxFit.cover), Alignment.center);
  });
}
