import 'dart:developer';

import 'package:device_apps/device_apps.dart';
import 'package:flutter_accessibility_service/accessibility_event.dart';
import 'package:flutter_accessibility_service/constants.dart';
import 'package:flutter_accessibility_service/flutter_accessibility_service.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:negate/logger/logger.dart';
import 'package:negate/sentiment_db.dart';
import 'package:permission_handler/permission_handler.dart';

class AndroidLogger extends SentenceLogger {
  static final AndroidLogger _instance = AndroidLogger.init();

  factory AndroidLogger() {
    return _instance;
  }

  AndroidLogger.init() : super.init();

  @override
  Future<void> startLogger(TfliteRequest request) async {
    await super.startLogger(request);
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sentence_logger',
        channelName: 'Sentiment Tracker',
        channelDescription: 'Analyzing sentence sentiment',
        channelImportance: NotificationChannelImportance.NONE,
        priority: NotificationPriority.LOW,
        visibility: NotificationVisibility.VISIBILITY_SECRET,
        iconData: const NotificationIconData(
          resType: ResourceType.drawable,
          resPrefix: ResourcePrefix.ic,
          name: 'brain_icon',
        ),
        buttons: [
          //const NotificationButton(id: 'stopButton', text: 'Stop'),
        ],
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  Future<void> startAccessibility() async {
    var statusNotify = await Permission.notification.request();
    if (statusNotify.isGranted) {
      FlutterForegroundTask.startService(
          notificationTitle: "Sentiment Tracker",
          notificationText: "Analyzing sentence sentiment");
    }
    bool status =
        await FlutterAccessibilityService.isAccessibilityPermissionEnabled();
    if (!status) {
      status =
          await FlutterAccessibilityService.requestAccessibilityPermission();
    }
    if (status) {
      FlutterAccessibilityService.accessStream.listen(_accessibilityListener);
    }
  }

  static void _accessibilityListener(AccessibilityEvent event) {
    if (AndroidLogger().blacklist.hasMatch(event.packageName!)) {
      return;
    }
    if (event.eventType == EventType.typeWindowStateChanged) {
      event.packageTitle().then((title) {
        AndroidLogger().updateFGApp(title!);
        if (!AndroidLogger().hasAppIcon(title)) {
          DeviceApps.getApp(event.packageName!, true).then((app) {
            var appWIcon = (app as ApplicationWithIcon?)!;
            AndroidLogger().addAppIcon(appWIcon.appName, appWIcon.icon);
          });
        }
      });
      return;
    }
    var textNow = event.nodesText![0];
    log(textNow);
    if (textNow.length == 1) {
      AndroidLogger().addAppEntry();
    }
    AndroidLogger().clearSentence();
    AndroidLogger().writeToSentence(textNow);
    event.packageTitle().then((title) => AndroidLogger().updateFGApp(title!));
  }
}

extension NameConversion on AccessibilityEvent {
  Future<String?> packageTitle() async {
    if (packageName != null) {
      var app = await DeviceApps.getApp(packageName!);
      return app?.appName;
    }
    return null;
  }
}
