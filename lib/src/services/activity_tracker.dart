import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:blt/src/global/variables.dart';
import 'package:blt/src/util/endpoints/general_endpoints.dart';

/// Enum representing the type of user activity detected.
enum ActivityType {
  mouse,
  keyboard,
}

/// Model class representing a single activity log entry.
class ActivityLog {
  final DateTime startTime;
  DateTime _endTime;
  final ActivityType activityType;
  String? windowTitle;

  ActivityLog({
    required this.startTime,
    required DateTime endTime,
    required this.activityType,
    this.windowTitle,
  }) : _endTime = endTime;

  DateTime get endTime => _endTime;

  void updateEndTime(DateTime time) {
    _endTime = time;
  }

  Map<String, dynamic> toJson({String? userId, String? domain}) {
    return {
      'user': userId,
      'domain': domain ?? 'blt.owasp.org',
      'start_time': startTime.toUtc().toIso8601String(),
      'end_time': _endTime.toUtc().toIso8601String(),
      'activity_description': _activityDescription,
      'window_title': windowTitle ?? 'BLT Sizzle Timer',
    };
  }

  String get _activityDescription {
    switch (activityType) {
      case ActivityType.mouse:
        return 'Mouse activity detected';
      case ActivityType.keyboard:
        return 'Keyboard activity detected';
    }
  }
}

/// Service class that tracks mouse and keyboard activity while the timer is running
/// and sends activity logs to the backend API periodically.
class ActivityTracker {
  static const String _endpoint = 'activity-logs/';
  static const Duration _sendInterval = Duration(minutes: 1);
  static const Duration _idleTimeout = Duration(minutes: 2);
  static const Duration _mouseThrottle = Duration(milliseconds: 100);

  bool _isTracking = false;
  bool get isTracking => _isTracking;

  DateTime? _lastActivityTime;
  DateTime? _lastMouseRecord;
  DateTime? _sessionStartTime;
  Timer? _sendTimer;
  Timer? _idleCheckTimer;
  bool _isSending = false;

  final List<ActivityLog> _pendingLogs = [];

  ActivityLog? _currentMouseActivity;
  ActivityLog? _currentKeyboardActivity;

  /// Returns the time of the last detected activity, or null if none.
  DateTime? get lastActivityTime => _lastActivityTime;

  /// Returns the number of pending logs waiting to be sent.
  int get pendingLogCount => _pendingLogs.length;

  /// Starts tracking user activity.
  void startTracking() {
    if (_isTracking) return;

    _isTracking = true;
    _sessionStartTime = DateTime.now();
    _lastActivityTime = DateTime.now();

    _sendTimer = Timer.periodic(_sendInterval, (_) => _sendPendingLogs());
    _idleCheckTimer = Timer.periodic(Duration(seconds: 30), (_) => _checkIdle());
  }

  /// Stops tracking user activity and flushes any pending logs.
  Future<void> stopTracking() async {
    if (!_isTracking) return;

    _isTracking = false;

    _sendTimer?.cancel();
    _sendTimer = null;

    _idleCheckTimer?.cancel();
    _idleCheckTimer = null;

    _finalizeCurrentActivities();
    await _sendPendingLogs();
  }

  /// Records a mouse/pointer movement event.
  void recordMouseActivity() {
    if (!_isTracking) return;

    final now = DateTime.now();

    // Throttle mouse events to avoid excessive updates
    if (_lastMouseRecord != null &&
        now.difference(_lastMouseRecord!) < _mouseThrottle) {
      return;
    }
    _lastMouseRecord = now;
    _lastActivityTime = now;

    if (_currentMouseActivity != null) {
      _currentMouseActivity!.updateEndTime(now);
    } else {
      _currentMouseActivity = ActivityLog(
        startTime: now,
        endTime: now,
        activityType: ActivityType.mouse,
      );
    }
  }

  /// Records a keyboard input event.
  void recordKeyboardActivity() {
    if (!_isTracking) return;

    final now = DateTime.now();
    _lastActivityTime = now;

    if (_currentKeyboardActivity != null) {
      _currentKeyboardActivity!.updateEndTime(now);
    } else {
      _currentKeyboardActivity = ActivityLog(
        startTime: now,
        endTime: now,
        activityType: ActivityType.keyboard,
      );
    }
  }

  /// Finalizes any ongoing activity sessions and moves them to pending logs.
  void _finalizeCurrentActivities() {
    final now = DateTime.now();

    if (_currentMouseActivity != null) {
      _currentMouseActivity!.updateEndTime(now);
      _pendingLogs.add(_currentMouseActivity!);
      _currentMouseActivity = null;
    }

    if (_currentKeyboardActivity != null) {
      _currentKeyboardActivity!.updateEndTime(now);
      _pendingLogs.add(_currentKeyboardActivity!);
      _currentKeyboardActivity = null;
    }
  }

  /// Checks if the user has been idle for too long and finalizes activities accordingly.
  void _checkIdle() {
    if (!_isTracking || _lastActivityTime == null) return;

    final now = DateTime.now();
    if (now.difference(_lastActivityTime!) > _idleTimeout) {
      _finalizeCurrentActivities();
    }
  }

  /// Sends pending activity logs to the backend API.
  Future<void> _sendPendingLogs() async {
    if (_isSending) return;
    _isSending = true;

    try {
      _finalizeCurrentActivities();

      if (_pendingLogs.isEmpty) return;
      if (currentUser == null || currentUser!.token == null) return;

      final logsToSend = List<ActivityLog>.from(_pendingLogs);
      _pendingLogs.clear();

      final url = Uri.parse('${GeneralEndPoints.apiBaseUrl}$_endpoint');
      final userId = currentUser!.username;

      for (final log in logsToSend) {
        try {
          final response = await http.post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Token ${currentUser!.token}',
            },
            body: json.encode(log.toJson(userId: userId)),
          );

          if (response.statusCode != 201 && response.statusCode != 200) {
            _pendingLogs.add(log);
          }
        } catch (e, stackTrace) {
          debugPrint('Failed to send activity log: $e\n$stackTrace');
          _pendingLogs.add(log);
        }
      }
    } finally {
      _isSending = false;
    }
  }

  /// Disposes resources. Should be called when the tracker is no longer needed.
  void dispose() {
    _isTracking = false;
    _sendTimer?.cancel();
    _idleCheckTimer?.cancel();
    _finalizeCurrentActivities();
  }
}

/// A widget that wraps its child and listens for pointer and keyboard events
/// to track user activity. Should be placed around the area where activity
/// needs to be monitored.
class ActivityTrackerListener extends StatefulWidget {
  final ActivityTracker tracker;
  final Widget child;

  const ActivityTrackerListener({
    super.key,
    required this.tracker,
    required this.child,
  });

  @override
  State<ActivityTrackerListener> createState() =>
      _ActivityTrackerListenerState();
}

class _ActivityTrackerListenerState extends State<ActivityTrackerListener> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerMove: (_) => widget.tracker.recordMouseActivity(),
      onPointerDown: (_) => widget.tracker.recordMouseActivity(),
      child: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (event) {
          if (event is KeyDownEvent) {
            widget.tracker.recordKeyboardActivity();
          }
        },
        child: GestureDetector(
          onTap: () {
            widget.tracker.recordMouseActivity();
            if (!_focusNode.hasFocus) {
              _focusNode.requestFocus();
            }
          },
          behavior: HitTestBehavior.translucent,
          child: widget.child,
        ),
      ),
    );
  }
}
