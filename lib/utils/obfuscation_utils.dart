/// Blur all artwork (for store screenshots). Compile-time switch: run with
/// `--dart-define=SATRA_BLUR_ARTWORK=true`; const-folded out of normal builds.
const kBlurArtwork = bool.fromEnvironment('SATRA_BLUR_ARTWORK');
