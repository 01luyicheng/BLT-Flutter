import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:blt/src/global/variables.dart';
import 'package:blt/src/util/endpoints/general_endpoints.dart';

enum ActivityType {
  mouse,
  keyboard,
}

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
      'domain': domain ?? GeneralEndPoints.baseUrl,
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
  Completer<void>? _sendCompleter;
  bool _isDisposed = false;
  bool _isStopping = false;

  final List<ActivityLog> _pendingLogs = [];

  ActivityLog? _currentMouseActivity;
  ActivityLog? _currentKeyboardActivity;

  DateTime? get lastActivityTime => _lastActivityTime;

  int get pendingLogCount => _pendingLogs.length;

  void startTracking() {
    if (_isDisposed) return;
    if (_isStopping) return;
    if (_isTracking) return;

    _isTracking = true;
    _sessionStartTime = DateTime.now();
    _lastActivityTime = DateTime.now();

    _sendTimer = Timer.periodic(_sendInterval, (_) => _sendPendingLogs());
    _idleCheckTimer = Timer.periodic(Duration(seconds: 30), (_) => _checkIdle());
  }

  Future<void> stopTracking() async {
    if (_isDisposed) return;
    if (_isStopping) return;
    _isStopping = true;

    _isTracking = false;

    _sendTimer?.cancel();
    _sendTimer = null;

    _idleCheckTimer?.cancel();
    _idleCheckTimer = null;

    _finalizeCurrentActivities();

    if (_isSending && _sendCompleter != null) {
      await _sendCompleter!.future;
    }

    await _sendPendingLogs();

    _isStopping = false;
  }

  void recordMouseActivity() {
    if (!_isTracking) return;

    final now = DateTime.now();

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

  void _checkIdle() {
    if (!_isTracking || _lastActivityTime == null) return;

    final now = DateTime.now();
    if (now.difference(_lastActivityTime!) > _idleTimeout) {
      _finalizeCurrentActivities();
    }
  }

  Future<void> _sendPendingLogs() async {
    if (_isDisposed) return;
    if (_isSending) return;
    _isSending = true;
    _sendCompleter = Completer<void>();

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
          final response = await http
              .post(
                url,
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Token ${currentUser!.token}',
                },
                body: json.encode(log.toJson(userId: userId)),
              )
              .timeout(const Duration(seconds: 10));

          if (response.statusCode != 201 && response.statusCode != 200) {
            _pendingLogs.add(log);
          }
        } on TimeoutException {
          debugPrint('Activity log send timed out');
          _pendingLogs.add(log);
        } catch (e, stackTrace) {
          debugPrint('Failed to send activity log: $e\n$stackTrace');
          _pendingLogs.add(log);
        }
      }
    } finally {
      _isSending = false;
      _sendCompleter?.complete();
      _sendCompleter = null;
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    _sendTimer?.cancel();
    _sendTimer = null;
    _idleCheckTimer?.cancel();
    _idleCheckTimer = null;
    _finalizeCurrentActivities();
  }
}

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
