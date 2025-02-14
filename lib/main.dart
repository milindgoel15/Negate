import 'dart:developer';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_saver/file_saver.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:intl/intl.dart';
import 'package:negate/logger/android_logger.dart';
import 'package:negate/logger/logger_factory.dart';
import 'package:negate/sentiment_analysis.dart';
import 'package:negate/sentiment_db.dart';

import 'package:drift/isolate.dart';
import 'package:flutter/material.dart';
import 'package:negate/ui/daily_breakdown.dart';
import 'package:negate/ui/settings.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:system_tray/system_tray.dart';
import 'package:dynamic_color/dynamic_color.dart';

import 'package:negate/ui/globals.dart';
import 'package:negate/ui/recommendations.dart';
import 'package:negate/ui/window_decorations.dart';
import 'package:negate/ui/common_ui.dart';

Future<void> main() async {
  const loggerUI = ThemedHourlyUI();
  WidgetsFlutterBinding.ensureInitialized();

  final dbFolder = await getApplicationSupportDirectory();
  final dbString = p.join(dbFolder.path, 'db.sqlite');
  final rPort = ReceivePort();

  var analyser = SentimentAnalysis();
  await analyser.init();
  var tfp = TfParams(analyser.sInterpreter.address, analyser.dictionary);

  var prefs = await SharedPreferences.getInstance();
  if (prefs.getBool('dynamic_theme') == null) {
    prefs.setBool('dynamic_theme', true);
    getIt.registerSingleton<bool>(true);
  } else {
    getIt.registerSingleton<bool>(prefs.getBool('dynamic_theme')!);
  }
  prefs.getBool('average_sentiment') == null
      ? prefs.setBool('average_sentiment', true)
      : null;
  prefs.getDouble('multiplier_sentiment') == null
      ? prefs.setDouble('multiplier_sentiment', 0.75)
      : null;
  prefs.getString('blacklist') == null
      ? prefs.setString('blacklist', LoggerFactory.getLoggerRegex().pattern)
      : null;

  if (Platform.isAndroid || Platform.isIOS) {
    LoggerFactory.startLoggerFactory(
        TfliteRequest(rPort.sendPort, dbString, tfp, prefs));
  } else {
    await loggerUI.initSystemTray();
    await Isolate.spawn(LoggerFactory.startLoggerFactory,
        TfliteRequest(rPort.sendPort, dbString, tfp, prefs));
  }

  var iPort = await rPort.first as SendPort;
  var isolate = DriftIsolate.fromConnectPort(iPort);
  var sdb = SentimentDB.connect(await isolate.connect());
  getIt.registerSingleton<SentimentDB>(sdb);
  runApp(const ProviderScope(child: loggerUI));
}

class ThemedHourlyUI extends StatelessWidget {
  const ThemedHourlyUI({super.key});

  Future<void> initSystemTray() async {
    String path =
        Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png';

    final AppWindow appWindow = AppWindow();
    final SystemTray systemTray = SystemTray();

    // We first init the systray menu
    await systemTray.initSystemTray(
      title: "system tray",
      iconPath: path,
    );

    // create context menu
    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: 'Show', onClicked: (menuItem) => appWindow.show()),
      MenuItemLabel(label: 'Hide', onClicked: (menuItem) => appWindow.hide()),
      MenuItemLabel(label: 'Exit', onClicked: (menuItem) => appWindow.close()),
    ]);

    // set context menu
    await systemTray.setContextMenu(menu);

    // handle system tray event
    systemTray.registerSystemTrayEventHandler((eventName) {
      debugPrint("eventName: $eventName");
      if (eventName == kSystemTrayEventClick) {
        Platform.isWindows ? appWindow.show() : systemTray.popUpContextMenu();
      } else if (eventName == kSystemTrayEventRightClick) {
        Platform.isWindows ? systemTray.popUpContextMenu() : appWindow.show();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget home = HourlyDashboard();
    if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      home = Column(
        children: [
          WindowButtons(),
          Expanded(child: home),
        ],
      );
    } else {
      home = WithForegroundTask(child: home);
    }

    return DynamicColorBuilder(
        builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
      ColorScheme light;
      ColorScheme dark;
      bool enabled = getIt<bool>.call();
      bool dynamicCheck =
          lightDynamic != null && darkDynamic != null && enabled;
      if (dynamicCheck) {
        light = lightDynamic;
        dark = darkDynamic;
      } else {
        light = ColorScheme.fromSwatch(
            primarySwatch: Colors.deepPurple,
            primaryColorDark: Colors.deepPurpleAccent,
            accentColor: Colors.deepPurpleAccent,
            brightness: Brightness.light);
        dark = ColorScheme.fromSwatch(
            primarySwatch: Colors.deepPurple,
            primaryColorDark: Colors.deepPurpleAccent,
            cardColor: Colors.deepPurpleAccent,
            accentColor: Colors.deepPurpleAccent,
            brightness: Brightness.dark);
      }
      return MaterialApp(
          title: 'Negate Mental Health Tracker',
          theme: ThemeData(colorSchemeSeed: light.primary, useMaterial3: true),
          darkTheme: ThemeData(
              colorSchemeSeed: dark.primary,
              brightness: Brightness.dark,
              useMaterial3: true),
          themeMode: ThemeMode.system,
          home: home);
    });
  }
}

//ignore: must_be_immutable
class HourlyDashboard extends ConsumerWidget {
  HourlyDashboard({super.key});
  bool _requested = false;
  late BuildContext _context;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var sdb = getIt<SentimentDB>.call();
    _context = context;
    SharedPreferences.getInstance().then((pref) {
      if ((pref.getBool('accepted_privacy') == null ||
              !pref.getBool('accepted_privacy')!) &&
          !_requested) {
        _requested = true;
        CommonUI.showDisclosure(context, pref);
      } else {
        if (Platform.isAndroid && !_requested) {
          _requested = true;
          AndroidLogger().startAccessibility();
        }
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
              onPressed: () {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => CommonUI.infoPage(context)));
              },
              icon: const Icon(Icons.info_outline)),
          IconButton(
              onPressed: () {
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const RecommendationsPage()));
              },
              icon: const Icon(Icons.analytics)),
          IconButton(
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(builder: (context) {
                  return StatefulBuilder(
                      builder: (BuildContext context, StateSetter setState) {
                    return DailyBreakdown.dashboard(
                        context, sdb, ref, setState);
                  });
                }));
              },
              icon: const Icon(Icons.pie_chart)),
          PopupMenuButton<String>(
              onSelected: handleMenu,
              itemBuilder: (context) {
                return {'Settings', 'Stop and Exit'}.map((String choice) {
                  return PopupMenuItem<String>(
                      value: choice, child: Text(choice));
                }).toList();
              }),
        ],
      ),
      body: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            CommonUI.dateChanger(context, sdb, ref),
            const Expanded(
                child: Text("Average Positivity per Hour",
                    style: TextStyle(fontWeight: FontWeight.bold))),
            Expanded(
                flex: 9,
                child: FutureBuilder<List<BarChartGroupData>>(
                    future: getHourBars(),
                    builder: (context, averages) {
                      if (averages.hasData) {
                        return BarChart(BarChartData(
                            alignment: BarChartAlignment.spaceAround,
                            maxY: 100,
                            minY: 0,
                            baselineY: 50,
                            barTouchData: barTouchData(ref),
                            titlesData: FlTitlesData(
                                show: true,
                                rightTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                        showTitles: true,
                                        reservedSize: 25,
                                        getTitlesWidget: (value, meta) =>
                                            const Text(""))),
                                topTitles: AxisTitles(
                                    sideTitles: SideTitles(showTitles: false)),
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 28,
                                      getTitlesWidget: bottomTitles),
                                ),
                                leftTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 25,
                                      getTitlesWidget: (value, meta) =>
                                          const Text("")),
                                )),
                            barGroups: averages.data));
                      } else {
                        return const CircularProgressIndicator();
                      }
                    })),
            Expanded(
                child: Text(
                    'Positivity scores for ${DateFormat.j().format(selectedDate)}',
                    style: const TextStyle(fontWeight: FontWeight.bold))),
            Expanded(
                flex: 9,
                child: FutureBuilder<List<SentimentLog>>(
                    future: sdb.getDaySentiment(selectedDate),
                    builder: (context, s) {
                      var logs = ref.watch(dbProvider) as List<SentimentLog>;
                      if (s.hasData) {
                        if (s.data!.isNotEmpty) {
                          logs = s.data!;
                        }
                      }
                      return ListView.separated(
                        itemCount: logs.length,
                        itemBuilder: (BuildContext context, int index) {
                          return SizedBox(
                              height: 50,
                              child: ListTile(
                                leading: FutureBuilder<Uint8List?>(
                                  future: sdb.getAppIcon(logs[index].name),
                                  builder: (ctx, ico) {
                                    if (ico.hasData) {
                                      return Image.memory(ico.data!);
                                    }
                                    return const ImageIcon(null);
                                  },
                                ),
                                trailing: Text(
                                    "${(logs[index].avgScore * 100).toStringAsFixed(2)}%"),
                                title: Text(logs[index].name),
                                subtitle:
                                    Text("Used for ${logs[index].timeUsed} m"),
                              ));
                        },
                        separatorBuilder: (BuildContext context, int index) =>
                            const Divider(),
                      );
                    })),
          ]),
      persistentFooterButtons: [
        TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.all(16.0),
            textStyle: const TextStyle(fontSize: 20),
          ),
          onPressed: () {
            var res = sdb.getDaySentiment(selectedDate);
            res.then((slog) {
              ref.read(dbProvider.notifier).set(slog);
            }, onError: (err, stk) => log(err));
          },
          child: const Text('Update logs'),
        ),
      ],
    );
  }

  Widget bottomTitles(double value, TitleMeta meta) {
    const style = TextStyle(fontWeight: FontWeight.normal, fontSize: 14);
    String text;
    if (value == 0) {
      text = '12 AM';
    } else if (value == 6) {
      text = '6 AM';
    } else if (value == 12) {
      text = '12 PM';
    } else if (value == 18) {
      text = '6 PM';
    } else if (value == 23) {
      text = '11 PM';
    } else {
      text = '';
    }
    return SideTitleWidget(
      axisSide: meta.axisSide,
      child: Text(text, style: style),
    );
  }

  BarTouchData barTouchData(WidgetRef ref) => BarTouchData(
        enabled: true,
        mouseCursorResolver: (barData, res) {
          if (res?.spot != null) {
            return SystemMouseCursors.click;
          }
          return SystemMouseCursors.basic;
        },
        handleBuiltInTouches: true,
        touchCallback: (event, res) {
          if (event.runtimeType == FlTapDownEvent) {
            if (res?.spot != null) {
              var hour = res!.spot!.touchedBarGroup.x;
              selectedDate = DateTime(selectedDate.year, selectedDate.month,
                  selectedDate.day, hour);
              var sdb = getIt<SentimentDB>.call();
              var ret = sdb.getDaySentiment(selectedDate);
              ret.then((slog) {
                ref.read(dbProvider.notifier).set(slog);
              }, onError: (err, stk) => log(err));
            }
          }
        },
        touchTooltipData: BarTouchTooltipData(
          tooltipBgColor: Colors.transparent,
          tooltipPadding: EdgeInsets.zero,
          tooltipMargin: 8,
          getTooltipItem: (
            BarChartGroupData group,
            int groupIndex,
            BarChartRodData rod,
            int rodIndex,
          ) {
            return BarTooltipItem(
              '${rod.toY.round()}%',
              const TextStyle(
                fontWeight: FontWeight.bold,
              ),
            );
          },
        ),
      );

  Future<List<BarChartGroupData>> getHourBars() async {
    List<BarChartGroupData> bars = [];
    var sdb = getIt<SentimentDB>.call();
    var res = await sdb.getAvgHourlySentiment(selectedDate);
    for (int i = 0; i < 24; i++) {
      List<int>? show;
      if (selectedDate.hour == i) {
        show = [0];
      }
      bars.add(BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
                toY: (res[i] * 100).roundToDouble(),
                width: 10,
                color: CommonUI.getBarColour(res[i]),
                borderRadius: const BorderRadius.all(Radius.zero))
          ],
          showingTooltipIndicators: show));
    }
    return bars;
  }

  void handleMenu(String value) async {
    switch (value) {
      case 'Settings':
        Navigator.push(
            _context,
            MaterialPageRoute(
                builder: (context) => StatefulBuilder(
                    builder: (BuildContext context, StateSetter setState) =>
                        SettingsPage.build(context, setState))));
        break;
      case 'Stop and Exit':
        exit(0);
    }
  }
}
