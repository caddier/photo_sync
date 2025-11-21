/// Utility functions for the app

/// Get formatted timestamp for logging
String timestamp() {
  final now = DateTime.now();
  return '[${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${(now.millisecond ~/ 10).toString().padLeft(2, '0')}]';
}
