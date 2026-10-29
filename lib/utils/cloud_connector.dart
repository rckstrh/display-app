import 'dart:async';
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

  /// Whether cloud-connector answered with a valid json response at all.
  /// If it didn't, the daemon is not running (yet).
  final bool answered;

  const CloudConnectorResponse({
    required this.success,
    this.error = "",
    this.data = const {},
    this.answered = false,
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
        answered: true,
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

  /// cloud-connector allows only a few plugin calls (like `est status` or
  /// `est enroll`) per minute and caller, and refuses the rest.
  bool get rateLimited => !success && error.startsWith("rate limit exceeded");

  /// Parses the output of `cloud-connector ping --format json`, which has no
  /// response envelope: `{"running": true}`.
  static bool parsePing(String output, int exitCode) {
    try {
      final json = jsonDecode(output);
      return exitCode == 0 && json is Map<String, dynamic> && json["running"] == true;
    } catch (_) {
      return false;
    }
  }
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

  static const Duration commandTimeout = Duration(seconds: 10);
  static const Duration pollInterval = Duration(seconds: 2);
  static const Duration startupTimeout = Duration(seconds: 60);

  /// How often the footer asks `est status`. cloud-connector allows 5 plugin
  /// calls per minute and caller, and the enrollment itself needs some of them.
  static const Duration statusPollInterval = Duration(seconds: 30);

  /// Last state read from `est status`, reused while cloud-connector refuses
  /// the call because of its rate limit.
  static CloudConnectorState? _lastState;

  /// Runs a command and kills it if it doesn't finish within [timeout].
  static Future<ProcessResult> _run(String executable, List<String> args,
      {Duration timeout = commandTimeout}) async {
    final proc = await Process.start(executable, args);
    final stdout = proc.stdout.transform(utf8.decoder).join();
    final stderr = proc.stderr.transform(utf8.decoder).join();
    final exitCode = await proc.exitCode.timeout(timeout, onTimeout: () {
      proc.kill();
      throw TimeoutException("$executable ${args.join(" ")} timed out");
    });
    return ProcessResult(proc.pid, exitCode, await stdout, await stderr);
  }

  static Future<bool> isServiceActive() async {
    try {
      final result = await _run("systemctl", ["is-active", cloudConnectorService]);
      return result.exitCode == 0 && (result.stdout as String).trim() == "active";
    } catch (e) {
      debugPrint("Failed to get cloud-connector service state: $e");
      return false;
    }
  }

  /// Checks that the service is active and the daemon answers `est status`.
  static Future<CloudConnectorState> state() async {
    if (!await isServiceActive()) return CloudConnectorState.notReady;
    try {
      final result = await _run(cloudConnectorPath, ["est", "status", "--format", "json"]);
      final response = CloudConnectorResponse.parse(
          result.stdout as String, result.exitCode);
      if (response.rateLimited) {
        debugPrint("cloud-connector status rate limited, keeping $_lastState");
        return _lastState ?? CloudConnectorState.notReady;
      }
      if (!response.success || response.data["enrolled"] is! bool) {
        return _lastState = CloudConnectorState.notReady;
      }
      return _lastState = response.enrolled
          ? CloudConnectorState.enrolled
          : CloudConnectorState.notEnrolled;
    } catch (e) {
      debugPrint("Failed to get cloud-connector status: $e");
      return CloudConnectorState.notReady;
    }
  }

  /// Whether the daemon answers. Uses `ping`, which, unlike `est status`,
  /// does not count against cloud-connector's rate limit, so it can be polled.
  static Future<bool> isReady() async {
    if (!await isServiceActive()) return false;
    try {
      final result = await _run(cloudConnectorPath, ["ping", "--format", "json"]);
      return CloudConnectorResponse.parsePing(
          result.stdout as String, result.exitCode);
    } catch (e) {
      debugPrint("Failed to ping cloud-connector: $e");
      return false;
    }
  }

  /// Polls until the daemon is ready. Returns false on timeout or if
  /// [cancelled] returns true.
  static Future<bool> waitUntilReady({bool Function()? cancelled}) async {
    final deadline = DateTime.now().add(startupTimeout);
    while (!(cancelled?.call() ?? false)) {
      if (await isReady()) return true;
      if (DateTime.now().isAfter(deadline)) return false;
      await Future.delayed(pollInterval);
    }
    return false;
  }

  static Future<CloudConnectorResponse> restartService() async {
    try {
      final result = await _run("systemctl", restartArgs,
          timeout: startupTimeout);
      return CloudConnectorResponse.fromExitCode(
          result.exitCode, result.stderr as String);
    } catch (e) {
      return CloudConnectorResponse(success: false, error: e.toString());
    }
  }
}

enum CloudConnectorState {
  /// Service inactive, daemon not answering, or enrollment status unreadable.
  notReady,
  notEnrolled,
  enrolled,
}
