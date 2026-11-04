import 'package:flutter/material.dart';

/// The white ribbon S stays white in every palette. A black tile supplies
/// contrast when a user explicitly chooses a light appearance.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.light ? Colors.black : Colors.transparent,
      borderRadius: BorderRadius.circular(size * 0.22),
    ),
    child: Image.asset('assets/plezy.png', width: size, height: size, semanticLabel: 'Satra'),
  );
}
