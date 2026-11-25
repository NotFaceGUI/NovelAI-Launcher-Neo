/// How a precise-reference image is normalized before it is sent to NovelAI.
///
/// V4.5 expects the image to be resized onto one of three large canvases with
/// padding, while V5 buckets the image into a 1 MP aspect-ratio bucket and
/// center-crops it. The mode is exposed through model capabilities so request
/// building and background normalization stay consistent.
enum PreciseReferenceImageMode {
  /// No precise-reference normalization is defined for the model.
  none,

  /// V4.5: resize onto 1024x1536 / 1536x1024 / 1472x1472 with padding.
  directorCanvas,

  /// V5: cover-resize into the official 1 MP aspect-ratio bucket and crop.
  aspectBucket,
}
