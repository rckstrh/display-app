import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

const String cloudConnectorPath = "/usr/bin/cloud-connector";
const String cloudConnectorService = "cloud-connector";

/// The legacy RFC 7030 enrollment path is only available if the environment
/// variable DISPLAY_APP_ENABLE_RFC7030 is set to "1" or "true".
bool get rfc7030Enabled {
  final value = Platform.environment['DISPLAY_APP_ENABLE_RFC7030'];
  return value == "1" || value?.toLowerCase() == "true";
}

/// Result of a `cloud-connector ... --format json` call.
class CloudConnectorResponse {
  final bool success;
  final String error;
  final Map<String, dynamic> data;

  const CloudConnectorResponse({
    required this.success,
    this.error = "",
    this.data = const {},
  });

  /// Parses the json output of cloud-connector. Invalid json or a non-zero
  /// exit code are treated as a failure.
  factory CloudConnectorResponse.parse(String output, int exitCode) {
    try {
      final json = jsonDecode(output);
      if (json is! Map<String, dynamic>) throw FormatException();
      final data = json["data"];
      final error = (json["error"] as String?) ?? "";
      final success = json["success"] == true && exitCode == 0;
      return CloudConnectorResponse(
        success: success,
        error: (!success && error.isEmpty) ? "exit code $exitCode" : error,
        data: (data is Map<String, dynamic>) ? data : const {},
      );
    } catch (_) {
      final trimmed = output.trim();
      return CloudConnectorResponse(
        success: false,
        error: trimmed.isNotEmpty ? trimmed : "exit code $exitCode",
      );
    }
  }

  /// For commands without json output, e.g. systemctl.
  factory CloudConnectorResponse.fromExitCode(int exitCode, String stderr) {
    if (exitCode == 0) return CloudConnectorResponse(success: true);
    final trimmed = stderr.trim();
    return CloudConnectorResponse(
      success: false,
      error: trimmed.isNotEmpty ? trimmed : "exit code $exitCode",
    );
  }

  /// Only meaningful for the response of `est status`.
  bool get enrolled => success && data["enrolled"] == true;
}

class CloudConnector {
  static List<String> enrollArgs(String otp) =>
      ["est", "enroll", "--otp-code", otp, "--format", "json"];

  static const List<String> restartArgs = ["restart", cloudConnectorService];

  static bool get available {
    try {
      return File(cloudConnectorPath).existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isEnrolled() async {
    try {
      final result = await Process.run(
          cloudConnectorPath, ["est", "status", "--format", "json"]);
      return CloudConnectorResponse.parse(
              result.stdout as String, result.exitCode)
          .enrolled;
    } catch (e) {
      debugPrint("Failed to get cloud-connector status: $e");
      return false;
    }
  }
}
