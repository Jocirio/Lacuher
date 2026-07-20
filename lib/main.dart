// lib/main.dart
//
// Neon Car Launcher — Iniciador de multimídia automotiva Android.
//
// Arquitetura (tudo em um único arquivo, por design, para simplificar o
// deploy via pendrive / build único):
//   1. NeonPalette          -> enum de cores neon (Roxo / Ciano / Esmeralda)
//   2. AppState             -> InheritedNotifier com a cor neon ativa (persistida)
//   3. NeonCarLauncherApp   -> raiz do MaterialApp
//   4. HomeShell            -> tela principal (3 velocímetros + dock + status bar)
//   5. SpeedometerGauge     -> CustomPainter alimentado pelo GPS real (geolocator)
//   5.6 MediaGaugeWidget    -> mostra a faixa/rádio tocando em outro app
//   5.7 ClockGaugeWidget    -> relógio, data e temperatura ambiente (via OBD-II)
//   7. ConnectivityMonitor  -> status real de Wi-Fi (connectivity_plus) e
//                              Bluetooth (flutter_blue_plus)
//   8. AppDock              -> botões que abrem Waze / Google Maps / Spotify reais
//   9. OfflineMapScreen     -> flutter_map lendo tiles locais em
//                              assets/map_tiles/{z}/{x}/{y}.png
//  10. SettingsScreen       -> seletor de cor neon (Roxo / Ciano / Esmeralda)

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:external_app_launcher/external_app_launcher.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:file_picker/file_picker.dart';

import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:phone_state/phone_state.dart';
import 'package:camera/camera.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:path/path.dart' as p;

import 'package:shared_preferences/shared_preferences.dart';

const String _prefsNeonKey = 'neon_palette';
const String _prefsMapFolderKey = 'map_folder_path';
const String _prefsReverseActionKey = 'reverse_broadcast_action';
const String _prefsObdAddressKey = 'obd_device_address';
const String _prefsCallGuardEnabledKey = 'call_guard_enabled';

// Canais nativos implementados em android/MainActivity.kt — não têm pacote
// pronto no pub.dev para isso.
const MethodChannel _telecomChannel = MethodChannel('com.neoncar.launcher/telecom');
const MethodChannel _reverseChannel = MethodChannel('com.neoncar.launcher/reverse');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Trava a orientação em paisagem (padrão de centrais multimídia).
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Modo imersivo: some com barras de sistema para parecer firmware nativo.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  final prefs = await SharedPreferences.getInstance();
  final savedIndex = prefs.getInt(_prefsNeonKey) ?? 0;
  final initialPalette = NeonPalette.values[savedIndex.clamp(0, NeonPalette.values.length - 1)];
  final initialMapFolder = prefs.getString(_prefsMapFolderKey);
  final initialReverseAction = prefs.getString(_prefsReverseActionKey);
  final initialObdAddress = prefs.getString(_prefsObdAddressKey);
  final initialCallGuardEnabled = prefs.getBool(_prefsCallGuardEnabledKey) ?? true;

  runApp(NeonCarLauncherApp(
    initialPalette: initialPalette,
    initialMapFolder: initialMapFolder,
    initialReverseAction: initialReverseAction,
    initialObdAddress: initialObdAddress,
    initialCallGuardEnabled: initialCallGuardEnabled,
  ));
}

// ---------------------------------------------------------------------------
// 1) PALETA NEON
// ---------------------------------------------------------------------------

enum NeonPalette { purple, cyan, emerald }

extension NeonPaletteX on NeonPalette {
  String get label {
    switch (this) {
      case NeonPalette.purple:
        return 'Roxo Neon';
      case NeonPalette.cyan:
        return 'Azul Ciano';
      case NeonPalette.emerald:
        return 'Verde Esmeralda';
    }
  }

  Color get color {
    switch (this) {
      case NeonPalette.purple:
        return const Color(0xFFB026FF);
      case NeonPalette.cyan:
        return const Color(0xFF00E5FF);
      case NeonPalette.emerald:
        return const Color(0xFF00FFA3);
    }
  }
}

/// Guarda a cor neon ativa e a pasta de mapas externa (se houver),
/// notificando a árvore inteira quando qualquer uma delas muda. Também
/// compõe os serviços novos (GPS/viagem, OBD-II, chamadas, ré) para que
/// qualquer tela alcance-os via AppStateScope.of(context).
class AppState extends ChangeNotifier {
  AppState({
    required NeonPalette palette,
    String? mapFolderPath,
    String? reverseCameraAction,
    String? obdDeviceAddress,
    bool callGuardEnabled = true,
  })  : _palette = palette,
        _mapFolderPath = mapFolderPath,
        _reverseCameraAction = reverseCameraAction,
        _callGuardEnabled = callGuardEnabled {
    driving.start();
    tripHistory.init();
    media.start();
    if (obdDeviceAddress != null && obdDeviceAddress.isNotEmpty) {
      obd.connect(obdDeviceAddress);
    }
    if (_callGuardEnabled) {
      callGuard.start();
    }
    if (_reverseCameraAction != null && _reverseCameraAction!.isNotEmpty) {
      ReverseSignalService.register(_reverseCameraAction!);
    }
  }

  NeonPalette _palette;
  NeonPalette get palette => _palette;

  Future<void> setPalette(NeonPalette value) async {
    if (value == _palette) return;
    _palette = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsNeonKey, value.index);
  }

  // Caminho absoluto de uma pasta externa (SD/pendrive) contendo tiles no
  // padrão {z}/{x}/{y}.png. Quando nulo, o app usa os tiles embutidos em
  // assets/map_tiles/. Isso permite trocar/ampliar a cobertura do mapa
  // (ex: de Mato Grosso para o Brasil inteiro) sem recompilar o APK —
  // basta copiar uma nova pasta de tiles para o dispositivo e apontar
  // o app para ela aqui.
  String? _mapFolderPath;
  String? get mapFolderPath => _mapFolderPath;

  Future<void> setMapFolderPath(String? path) async {
    _mapFolderPath = (path != null && path.trim().isEmpty) ? null : path;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (_mapFolderPath == null) {
      await prefs.remove(_prefsMapFolderKey);
    } else {
      await prefs.setString(_prefsMapFolderKey, _mapFolderPath!);
    }
  }

  // Ação de broadcast que a central usa para sinalizar marcha-ré (varia por
  // fabricante — veja ReverseCameraScreen/ReverseSignalService).
  String? _reverseCameraAction;
  String? get reverseCameraAction => _reverseCameraAction;

  Future<void> setReverseCameraAction(String? action) async {
    _reverseCameraAction = (action != null && action.trim().isEmpty) ? null : action;
    ReverseSignalService.unregister();
    if (_reverseCameraAction != null) {
      ReverseSignalService.register(_reverseCameraAction!);
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (_reverseCameraAction == null) {
      await prefs.remove(_prefsReverseActionKey);
    } else {
      await prefs.setString(_prefsReverseActionKey, _reverseCameraAction!);
    }
  }

  bool _callGuardEnabled;
  bool get callGuardEnabled => _callGuardEnabled;

  Future<void> setCallGuardEnabled(bool enabled) async {
    _callGuardEnabled = enabled;
    if (enabled) {
      callGuard.start();
    } else {
      callGuard.stop();
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsCallGuardEnabledKey, enabled);
  }

  Future<void> _persistObdAddress(String? address) async {
    final prefs = await SharedPreferences.getInstance();
    if (address == null) {
      await prefs.remove(_prefsObdAddressKey);
    } else {
      await prefs.setString(_prefsObdAddressKey, address);
    }
  }

  /// Chamado pela tela de Configurações ao escolher um adaptador OBD-II —
  /// conecta e já salva o endereço para reconectar sozinho na próxima vez
  /// que o app abrir.
  Future<void> connectObd(String address) async {
    await obd.connect(address);
    await _persistObdAddress(address);
  }

  Future<void> disconnectObd() async {
    await obd.disconnect();
    await _persistObdAddress(null);
  }

  // --- Serviços compostos ---
  final DrivingDataService driving = DrivingDataService();
  final ObdService obd = ObdService();
  final CallGuardService callGuard = CallGuardService();
  final TripHistoryService tripHistory = TripHistoryService();
  final MediaInfoService media = MediaInfoService();

  @override
  void dispose() {
    driving.dispose();
    obd.dispose();
    callGuard.dispose();
    media.dispose();
    super.dispose();
  }
}

/// Disponibiliza o [AppState] para toda a árvore via InheritedNotifier.
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({super.key, required AppState super.notifier, required super.child});

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope não encontrado na árvore de widgets');
    return scope!.notifier!;
  }
}

// ---------------------------------------------------------------------------
// 2) APP ROOT
// ---------------------------------------------------------------------------

class NeonCarLauncherApp extends StatefulWidget {
  const NeonCarLauncherApp({
    super.key,
    required this.initialPalette,
    this.initialMapFolder,
    this.initialReverseAction,
    this.initialObdAddress,
    this.initialCallGuardEnabled = true,
  });
  final NeonPalette initialPalette;
  final String? initialMapFolder;
  final String? initialReverseAction;
  final String? initialObdAddress;
  final bool initialCallGuardEnabled;

  @override
  State<NeonCarLauncherApp> createState() => _NeonCarLauncherAppState();
}

class _NeonCarLauncherAppState extends State<NeonCarLauncherApp> {
  late final AppState _appState = AppState(
    palette: widget.initialPalette,
    mapFolderPath: widget.initialMapFolder,
    reverseCameraAction: widget.initialReverseAction,
    obdDeviceAddress: widget.initialObdAddress,
    callGuardEnabled: widget.initialCallGuardEnabled,
  );

  // Permite navegar a partir de um callback estático (o sinal de marcha-ré
  // chega via canal nativo, sem BuildContext à mão).
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    ReverseSignalService.onTriggered = () {
      _navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => const ReverseCameraScreen()),
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      notifier: _appState,
      child: AnimatedBuilder(
        animation: _appState,
        builder: (context, _) {
          final neon = _appState.palette.color;
          return MaterialApp(
            navigatorKey: _navigatorKey,
            title: 'Neon Car Launcher',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              brightness: Brightness.dark,
              scaffoldBackgroundColor: const Color(0xFF06060A),
              colorScheme: ColorScheme.fromSeed(
                seedColor: neon,
                brightness: Brightness.dark,
                surface: const Color(0xFF0D0D14),
              ),
              fontFamily: 'Roboto',
            ),
            home: const HomeShell(),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3) HOME SHELL — tela principal do launcher
// ---------------------------------------------------------------------------

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  DateTime _now = DateTime.now();
  late final Timer _clockTimer;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final neon = appState.palette.color;

    return PopScope(
      // Impede que o botão "voltar" do sistema minimize o launcher.
      canPop: false,
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.3),
              radius: 1.4,
              colors: [Color(0xFF12121B), Color(0xFF06060A)],
            ),
          ),
          child: SafeArea(
            child: Stack(
              children: [
                Column(
                  children: [
                    _TopStatusBar(now: _now, neon: neon),
                    const SizedBox(height: 4),
                    // Os três velocímetros ficam próximos/sobrepostos de leve:
                    // mídia à esquerda, velocidade (GPS real) no centro e
                    // relógio/data/temperatura à direita — tudo visível ao
                    // mesmo tempo, sem precisar trocar de tela.
                    Expanded(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          const Align(alignment: Alignment.center, child: SpeedometerGauge()),
                          const Align(alignment: Alignment(-0.62, 0.04), child: MediaGaugeWidget()),
                          const Align(alignment: Alignment(0.62, 0.04), child: ClockGaugeWidget()),
                        ],
                      ),
                    ),
                    AppDock(neon: neon),
                    const SizedBox(height: 14),
                  ],
                ),
                // Overlay de chamada tocando — cobre a tela inteira, com
                // atender/recusar em botões grandes (viva-voz sem depender
                // de CarPlay/Android Auto).
                AnimatedBuilder(
                  animation: appState.callGuard,
                  builder: (context, _) {
                    if (!appState.callGuard.isRinging) return const SizedBox.shrink();
                    return _IncomingCallOverlay(neon: neon, callGuard: appState.callGuard);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IncomingCallOverlay extends StatelessWidget {
  const _IncomingCallOverlay({required this.neon, required this.callGuard});
  final Color neon;
  final CallGuardService callGuard;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: const Color(0xFF06060A).withOpacity(0.96),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.phone_in_talk_rounded, color: neon, size: 48),
              const SizedBox(height: 12),
              Text(
                callGuard.incomingNumber ?? 'Número desconhecido',
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text('Chamada tocando', style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _CallButton(
                    icon: Icons.call_end_rounded,
                    color: Colors.redAccent,
                    label: 'Recusar',
                    onTap: callGuard.decline,
                  ),
                  const SizedBox(width: 40),
                  _CallButton(
                    icon: Icons.call_rounded,
                    color: Colors.green,
                    label: 'Atender',
                    onTap: callGuard.answer,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(40),
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }
}

class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({required this.now, required this.neon});
  final DateTime now;
  final Color neon;

  String get _timeLabel =>
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

  String get _dateLabel {
    const dias = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];
    return '${dias[now.weekday - 1]}, ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: neon.withOpacity(0.45), width: 1),
        boxShadow: [
          BoxShadow(color: neon.withOpacity(0.25), blurRadius: 14, spreadRadius: 0.5),
        ],
      ),
      child: Row(
        children: [
          Text(
            _timeLabel,
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(color: neon.withOpacity(0.8), blurRadius: 10)],
            ),
          ),
          const SizedBox(width: 10),
          Text(_dateLabel, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          const Spacer(),
          const ConnectivityMonitor(),
          const SizedBox(width: 14),
          _SettingsButton(neon: neon),
        ],
      ),
    );
  }
}

class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.neon});
  final Color neon;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.settings_outlined, color: neon),
      tooltip: 'Configurações',
      onPressed: () {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 4) VELOCÍMETRO REAL — GPS via geolocator + CustomPainter a 60 FPS
// ---------------------------------------------------------------------------

class SpeedometerGauge extends StatefulWidget {
  const SpeedometerGauge({super.key});

  @override
  State<SpeedometerGauge> createState() => _SpeedometerGaugeState();
}

class _SpeedometerGaugeState extends State<SpeedometerGauge>
    with SingleTickerProviderStateMixin {
  double _targetSpeedKmh = 0;
  double _displaySpeedKmh = 0;
  DrivingDataService? _driving;

  late final AnimationController _ticker;

  static const double _maxSpeed = 220;

  @override
  void initState() {
    super.initState();
    // Ticker a 60 FPS que suaviza a agulha em direção à velocidade real
    // lida do GPS (evita "saltos" bruscos na UI).
    _ticker = AnimationController(vsync: this, duration: const Duration(days: 1))
      ..addListener(_smoothTick)
      ..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // O GPS é lido uma única vez, de forma centralizada, pelo
    // DrivingDataService (ver AppState.driving) — este widget só assina as
    // atualizações, em vez de abrir sua própria stream de localização.
    final driving = AppStateScope.of(context).driving;
    if (_driving != driving) {
      _driving?.removeListener(_onDrivingUpdate);
      _driving = driving;
      _driving!.addListener(_onDrivingUpdate);
      _onDrivingUpdate();
    }
  }

  void _onDrivingUpdate() {
    if (!mounted) return;
    setState(() => _targetSpeedKmh = _driving!.speedKmh.clamp(0, _maxSpeed));
  }

  void _smoothTick() {
    if (!mounted) return;
    final diff = _targetSpeedKmh - _displaySpeedKmh;
    if (diff.abs() < 0.05) return;
    setState(() => _displaySpeedKmh += diff * 0.12);
  }

  @override
  void dispose() {
    _driving?.removeListener(_onDrivingUpdate);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final neon = AppStateScope.of(context).palette.color;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 300,
          height: 300,
          child: CustomPaint(
            painter: SpeedometerPainter(
              speedKmh: _displaySpeedKmh,
              maxSpeed: _maxSpeed,
              neon: neon,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(_driving?.gpsStatus ?? 'Procurando GPS…',
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
      ],
    );
  }
}

class SpeedometerPainter extends CustomPainter {
  SpeedometerPainter({required this.speedKmh, required this.maxSpeed, required this.neon});

  final double speedKmh;
  final double maxSpeed;
  final Color neon;

  static const double _startAngle = 2.35619; // 135°
  static const double _sweepAngle = 4.71239; // 270°

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;

    // Trilha de fundo.
    final trackPaint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius - 12), _startAngle,
        _sweepAngle, false, trackPaint);

    // Progresso neon.
    final progress = (speedKmh / maxSpeed).clamp(0.0, 1.0);
    final progressPaint = Paint()
      ..shader = SweepGradient(
        startAngle: _startAngle,
        endAngle: _startAngle + _sweepAngle,
        colors: [neon.withOpacity(0.2), neon],
      ).createShader(Rect.fromCircle(center: center, radius: radius - 12))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius - 12), _startAngle,
        _sweepAngle * progress, false, progressPaint);

    // Glow externo.
    final glowPaint = Paint()
      ..color = neon.withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius - 12), _startAngle,
        _sweepAngle * progress, false, glowPaint);

    // Marcações numéricas.
    const step = 20;
    for (int v = 0; v <= maxSpeedInt; v += step) {
      final t = v / maxSpeed;
      final angle = _startAngle + _sweepAngle * t;
      final outer = center + Offset(radius - 26, 0).rotate(angle);
      final tp = TextPainter(
        text: TextSpan(
          text: '$v',
          style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, outer - Offset(tp.width / 2, tp.height / 2));
    }

    // Velocidade central (grande, brilhante).
    final speedText = TextPainter(
      text: TextSpan(
        text: speedKmh.round().toString(),
        style: TextStyle(
          color: Colors.white,
          fontSize: 64,
          fontWeight: FontWeight.bold,
          shadows: [Shadow(color: neon.withOpacity(0.9), blurRadius: 20)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    speedText.paint(canvas, center - Offset(speedText.width / 2, speedText.height / 2 + 8));

    final unitText = TextPainter(
      text: const TextSpan(
        text: 'km/h',
        style: TextStyle(color: Colors.white38, fontSize: 16, letterSpacing: 2),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    unitText.paint(canvas, center + Offset(-unitText.width / 2, 36));
  }

  int get maxSpeedInt => maxSpeed.round();

  @override
  bool shouldRepaint(covariant SpeedometerPainter oldDelegate) =>
      oldDelegate.speedKmh != speedKmh || oldDelegate.neon != neon;
}

extension on Offset {
  Offset rotate(double radians) {
    final cosA = math.cos(radians);
    final sinA = math.sin(radians);
    return Offset(dx * cosA - dy * sinA, dx * sinA + dy * cosA);
  }
}

// ---------------------------------------------------------------------------
// 5.5b) MOLDURA COMUM DOS VELOCÍMETROS SATÉLITE (mídia e relógio)
// ---------------------------------------------------------------------------

const double _kSatelliteGaugeSize = 168;

class _SatelliteRingPainter extends CustomPainter {
  _SatelliteRingPainter({required this.neon});
  final Color neon;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 6;

    final ring = Paint()
      ..color = neon.withOpacity(0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, radius, ring);

    final glow = Paint()
      ..color = neon.withOpacity(0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
    canvas.drawCircle(center, radius, glow);

    final inner = Paint()
      ..color = Colors.white.withOpacity(0.05)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - 6, inner);
  }

  @override
  bool shouldRepaint(covariant _SatelliteRingPainter oldDelegate) => oldDelegate.neon != neon;
}

/// Painel circular menor, no mesmo estilo neon do velocímetro principal,
/// usado tanto pelo [MediaGaugeWidget] quanto pelo [ClockGaugeWidget] —
/// para os três ficarem visualmente próximos/parecidos, como pedido.
class _SatelliteGaugeFrame extends StatelessWidget {
  const _SatelliteGaugeFrame({required this.neon, required this.child, this.onTap});
  final Color neon;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: _kSatelliteGaugeSize,
        height: _kSatelliteGaugeSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size(_kSatelliteGaugeSize, _kSatelliteGaugeSize),
              painter: _SatelliteRingPainter(neon: neon),
            ),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: child),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5.6b) VELOCÍMETRO DE MÍDIA — mostra a faixa/rádio tocando em outro app
// ---------------------------------------------------------------------------

class MediaGaugeWidget extends StatelessWidget {
  const MediaGaugeWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final neon = appState.palette.color;

    return AnimatedBuilder(
      animation: appState.media,
      builder: (context, _) {
        final media = appState.media;
        final hasTrack = (media.trackTitle ?? '').isNotEmpty;
        return _SatelliteGaugeFrame(
          neon: neon,
          onTap: hasTrack ? null : media.openNotificationAccessSettings,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                media.isPlaying ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
                color: neon,
                size: 26,
              ),
              const SizedBox(height: 8),
              Text(
                hasTrack ? media.trackTitle! : 'Sem música',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                hasTrack ? (media.trackArtist ?? '') : 'Toque p/ ativar acesso',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 5.7) VELOCÍMETRO DE RELÓGIO — hora, data e temperatura ambiente (via OBD-II)
// ---------------------------------------------------------------------------

class ClockGaugeWidget extends StatefulWidget {
  const ClockGaugeWidget({super.key});

  @override
  State<ClockGaugeWidget> createState() => _ClockGaugeWidgetState();
}

class _ClockGaugeWidgetState extends State<ClockGaugeWidget> {
  late DateTime _now;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String get _timeLabel =>
      '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';

  String get _dateLabel {
    const dias = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];
    return '${dias[_now.weekday - 1]}, ${_now.day.toString().padLeft(2, '0')}/${_now.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final neon = appState.palette.color;

    return AnimatedBuilder(
      animation: appState.obd,
      builder: (context, _) {
        final ambientTemp = appState.obd.ambientTempC;
        return _SatelliteGaugeFrame(
          neon: neon,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _timeLabel,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(color: neon.withOpacity(0.8), blurRadius: 12)],
                ),
              ),
              const SizedBox(height: 4),
              Text(_dateLabel, style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 6),
              Text(
                ambientTemp != null ? '$ambientTemp°C' : '-- (sem OBD-II)',
                style: TextStyle(color: neon, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 5.1) DADOS DE CONDUÇÃO — GPS centralizado + computador de bordo da viagem
// ---------------------------------------------------------------------------

/// Único ponto de leitura do GPS do app: evita várias telas abrindo streams
/// de localização separadas (gasta bateria/CPU à toa). Além da velocidade
/// atual, também acumula distância, velocidade média e máxima da viagem
/// em andamento — o "computador de bordo".
class DrivingDataService extends ChangeNotifier {
  StreamSubscription<Position>? _positionSub;
  Position? _lastPosition;

  double speedKmh = 0;
  String gpsStatus = 'Procurando GPS…';

  DateTime tripStartedAt = DateTime.now();
  double tripDistanceKm = 0;
  double tripMaxSpeedKmh = 0;
  double _speedSum = 0;
  int _speedSampleCount = 0;

  double get tripAvgSpeedKmh => _speedSampleCount == 0 ? 0 : _speedSum / _speedSampleCount;

  Future<void> start() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      gpsStatus = 'GPS bloqueado nas permissões';
      notifyListeners();
      return;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      gpsStatus = 'GPS desligado';
      notifyListeners();
      return;
    }

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );

    _positionSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosition,
      onError: (_) {
        gpsStatus = 'Sinal de GPS perdido';
        notifyListeners();
      },
    );
  }

  void _onPosition(Position pos) {
    final speedMs = pos.speed.isFinite && pos.speed > 0 ? pos.speed : 0.0;
    speedKmh = (speedMs * 3.6).clamp(0, 300);
    gpsStatus = 'GPS ativo';

    if (_lastPosition != null) {
      final meters = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        pos.latitude,
        pos.longitude,
      );
      // Ignora saltos grandes (ruído de GPS parado/reflexo em túnel etc.).
      if (meters.isFinite && meters > 0 && meters < 200) {
        tripDistanceKm += meters / 1000;
      }
    }
    _lastPosition = pos;

    if (speedKmh > tripMaxSpeedKmh) tripMaxSpeedKmh = speedKmh;
    if (speedKmh > 1) {
      _speedSum += speedKmh;
      _speedSampleCount++;
    }
    notifyListeners();
  }

  /// Zera o odômetro da viagem atual (chamado manualmente ou ao salvar no
  /// histórico) sem precisar reiniciar o app.
  void resetTrip() {
    tripStartedAt = DateTime.now();
    tripDistanceKm = 0;
    tripMaxSpeedKmh = 0;
    _speedSum = 0;
    _speedSampleCount = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 5.2) HISTÓRICO DE VIAGENS — banco local (sqflite), sem nuvem
// ---------------------------------------------------------------------------

class TripRecord {
  TripRecord({
    this.id,
    required this.startedAt,
    required this.endedAt,
    required this.distanceKm,
    required this.avgSpeedKmh,
    required this.maxSpeedKmh,
  });

  final int? id;
  final DateTime startedAt;
  final DateTime endedAt;
  final double distanceKm;
  final double avgSpeedKmh;
  final double maxSpeedKmh;

  Map<String, Object?> toMap() => {
        'started_at': startedAt.toIso8601String(),
        'ended_at': endedAt.toIso8601String(),
        'distance_km': distanceKm,
        'avg_speed_kmh': avgSpeedKmh,
        'max_speed_kmh': maxSpeedKmh,
      };

  static TripRecord fromMap(Map<String, Object?> map) => TripRecord(
        id: map['id'] as int?,
        startedAt: DateTime.parse(map['started_at'] as String),
        endedAt: DateTime.parse(map['ended_at'] as String),
        distanceKm: (map['distance_km'] as num).toDouble(),
        avgSpeedKmh: (map['avg_speed_kmh'] as num).toDouble(),
        maxSpeedKmh: (map['max_speed_kmh'] as num).toDouble(),
      );
}

/// Guarda o histórico de viagens no próprio aparelho (SQLite via sqflite) —
/// nenhum dado sai do dispositivo.
class TripHistoryService extends ChangeNotifier {
  sqlite.Database? _db;
  List<TripRecord> trips = [];

  Future<void> init() async {
    final dbPath = await sqlite.getDatabasesPath();
    final path = p.join(dbPath, 'neon_car_launcher_trips.db');
    _db = await sqlite.openDatabase(
      path,
      version: 1,
      onCreate: (db, version) => db.execute('''
        CREATE TABLE trips(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          started_at TEXT NOT NULL,
          ended_at TEXT NOT NULL,
          distance_km REAL NOT NULL,
          avg_speed_kmh REAL NOT NULL,
          max_speed_kmh REAL NOT NULL
        )
      '''),
    );
    await _reload();
  }

  Future<void> _reload() async {
    final db = _db;
    if (db == null) return;
    final rows = await db.query('trips', orderBy: 'started_at DESC', limit: 100);
    trips = rows.map(TripRecord.fromMap).toList();
    notifyListeners();
  }

  Future<void> saveTrip(DrivingDataService driving) async {
    if (driving.tripDistanceKm < 0.05) return; // não vale a pena salvar viagens de metros
    final db = _db;
    if (db == null) return;
    final record = TripRecord(
      startedAt: driving.tripStartedAt,
      endedAt: DateTime.now(),
      distanceKm: driving.tripDistanceKm,
      avgSpeedKmh: driving.tripAvgSpeedKmh,
      maxSpeedKmh: driving.tripMaxSpeedKmh,
    );
    await db.insert('trips', record.toMap());
    driving.resetTrip();
    await _reload();
  }
}

// ---------------------------------------------------------------------------
// 5.3) OBD-II — leitura real do motor via Bluetooth clássico (ELM327)
// ---------------------------------------------------------------------------
//
// Requer um adaptador ELM327 Bluetooth (uns R$30-50, compatível com a porta
// OBD-II de praticamente qualquer carro pós-1996). O protocolo aqui é
// simplificado: inicializa o adaptador e faz polling de 3 PIDs comuns
// (RPM, temperatura do motor, nível de combustível). Nem toda ECU responde
// a todos os PIDs — trate valores ausentes como "não disponível".
class ObdService extends ChangeNotifier {
  BluetoothConnection? _connection;
  Timer? _pollTimer;
  final StringBuffer _rxBuffer = StringBuffer();

  bool isConnected = false;
  int? rpm;
  int? coolantTempC;
  int? fuelPercent;
  int? ambientTempC;
  List<String> dtcCodes = [];
  String status = 'Desconectado';

  Future<void> connect(String address) async {
    status = 'Conectando…';
    notifyListeners();
    try {
      _connection = await BluetoothConnection.toAddress(address);
      isConnected = true;
      status = 'Conectado';
      notifyListeners();

      _connection!.input?.listen(_onData, onDone: () {
        isConnected = false;
        status = 'Desconectado';
        notifyListeners();
      });

      // Sequência de inicialização padrão de um ELM327.
      await _send('ATZ');
      await Future.delayed(const Duration(milliseconds: 400));
      await _send('ATE0'); // desliga eco
      await _send('ATSP0'); // protocolo automático

      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollOnce());
    } catch (e) {
      isConnected = false;
      status = 'Falha ao conectar: $e';
      notifyListeners();
    }
  }

  Future<void> _pollOnce() async {
    if (!isConnected) return;
    await _send('010C'); // RPM
    await Future.delayed(const Duration(milliseconds: 200));
    await _send('0105'); // temperatura do líquido de arrefecimento
    await Future.delayed(const Duration(milliseconds: 200));
    await _send('012F'); // nível de combustível
    await Future.delayed(const Duration(milliseconds: 200));
    await _send('0146'); // temperatura ambiente (nem toda ECU expõe esse PID)
  }

  Future<void> readTroubleCodes() async {
    if (!isConnected) return;
    await _send('03');
  }

  Future<void> _send(String command) async {
    final conn = _connection;
    if (conn == null || !conn.isConnected) return;
    conn.output.add(Uint8List.fromList('$command\r'.codeUnits));
    await conn.output.allSent;
  }

  void _onData(Uint8List data) {
    _rxBuffer.write(String.fromCharCodes(data));
    final chunk = _rxBuffer.toString();
    if (!chunk.contains('>')) return; // ELM327 termina cada resposta com '>'
    _rxBuffer.clear();

    for (final rawLine in chunk.split('\r')) {
      final line = rawLine.replaceAll('>', '').trim();
      if (line.isEmpty) continue;
      _parseLine(line);
    }
    notifyListeners();
  }

  void _parseLine(String line) {
    final bytes = line.split(' ').where((s) => s.isNotEmpty).toList();
    if (bytes.length < 3) return;

    // Resposta padrão de modo 01 (dados ao vivo): "41 <PID> <A> [<B>]"
    if (bytes[0] == '41') {
      final pid = bytes[1];
      switch (pid) {
        case '0C': // RPM = ((A*256)+B)/4
          if (bytes.length >= 4) {
            final a = int.tryParse(bytes[2], radix: 16) ?? 0;
            final b = int.tryParse(bytes[3], radix: 16) ?? 0;
            rpm = ((a * 256) + b) ~/ 4;
          }
          break;
        case '05': // temperatura = A - 40
          final a = int.tryParse(bytes[2], radix: 16);
          if (a != null) coolantTempC = a - 40;
          break;
        case '2F': // combustível = A * 100 / 255
          final a = int.tryParse(bytes[2], radix: 16);
          if (a != null) fuelPercent = (a * 100 / 255).round();
          break;
        case '46': // temperatura ambiente = A - 40 (mesma formula do PID 05)
          final a = int.tryParse(bytes[2], radix: 16);
          if (a != null) ambientTempC = a - 40;
          break;
      }
    }

    // Resposta de códigos de erro (modo 03): "43 ..." — parsing simplificado,
    // só reporta que existem códigos; a decodificação completa dos DTCs
    // (ex: P0301) fica como próximo passo caso você use bastante essa tela.
    if (bytes[0] == '43' && bytes.length > 1) {
      dtcCodes = ['Códigos de erro detectados — consulte um scanner completo para detalhes'];
    }
  }

  Future<void> disconnect() async {
    _pollTimer?.cancel();
    await _connection?.finish();
    _connection = null;
    isConnected = false;
    status = 'Desconectado';
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _connection?.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 5.4) CHAMADAS VIVA-VOZ — sem depender de CarPlay/Android Auto
// ---------------------------------------------------------------------------
//
// Atender/encerrar chamada não precisa que o app seja o discador padrão:
// desde o Android 8 (atender) / 9 (encerrar), a permissão ANSWER_PHONE_CALLS
// já basta, via TelecomManager (implementado nativamente em
// android/MainActivity.kt, canal "com.neoncar.launcher/telecom").
//
// ATENÇÃO: a API do pacote `phone_state` (nomes exatos de enum/campos) pode
// variar entre versões — confira `PhoneStateStatus` e os campos de `state`
// contra a versão que o `flutter pub get` baixar, e ajuste aqui se preciso.
class CallGuardService extends ChangeNotifier {
  StreamSubscription<PhoneState>? _sub;
  bool isRinging = false;
  String? incomingNumber;

  void start() {
    _sub ??= PhoneState.stream.listen((state) {
      isRinging = state.status == PhoneStateStatus.CALL_INCOMING;
      incomingNumber = state.number;
      notifyListeners();
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    isRinging = false;
    notifyListeners();
  }

  Future<void> answer() async {
    try {
      await _telecomChannel.invokeMethod('answerCall');
    } catch (_) {
      // Permissão ainda não concedida pelo usuário, ou Android < 8.
    }
  }

  Future<void> decline() async {
    try {
      await _telecomChannel.invokeMethod('endCall');
    } catch (_) {
      // Permissão ainda não concedida, ou Android < 9.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 5.5) CÂMERA DE RÉ — sinal configurável (varia por central)
// ---------------------------------------------------------------------------
//
// IMPORTANTE: em muitas centrais automotivas baratas a troca para a câmera
// de ré é feita por hardware (o fio de ré aciona a chave de vídeo direto,
// sem passar pelo Android) — nesse caso nada aqui é necessário, a central já
// troca sozinha. Isto só é útil se a SUA central expõe o evento de marcha-ré
// como um broadcast Android configurável — confira com o suporte/manual da
// central qual ação usar.
class ReverseSignalService {
  static void Function()? onTriggered;

  static void _ensureHandler() {
    _reverseChannel.setMethodCallHandler((call) async {
      if (call.method == 'onReverseTriggered') {
        onTriggered?.call();
      }
    });
  }

  static Future<void> register(String action) async {
    _ensureHandler();
    try {
      await _reverseChannel.invokeMethod('register', {'action': action});
    } catch (_) {
      // Canal nativo indisponível (ex: rodando em modo debug web/desktop).
    }
  }

  static Future<void> unregister() async {
    try {
      await _reverseChannel.invokeMethod('unregister');
    } catch (_) {}
  }
}

class ReverseCameraScreen extends StatefulWidget {
  const ReverseCameraScreen({super.key});

  @override
  State<ReverseCameraScreen> createState() => _ReverseCameraScreenState();
}

class _ReverseCameraScreenState extends State<ReverseCameraScreen> {
  CameraController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error =
            'Nenhuma câmera Android encontrada. Se a sua central troca para a '
            'câmera de ré por hardware (a maioria faz isso), essa tela não é '
            'necessária — a troca já acontece fora do app.');
        return;
      }
      _controller = CameraController(cameras.first, ResolutionPreset.medium);
      await _controller!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      setState(() => _error = 'Não foi possível abrir a câmera: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            if (_controller != null && _controller!.value.isInitialized)
              Positioned.fill(child: CameraPreview(_controller!))
            else
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error ?? 'Abrindo câmera de ré…',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            Positioned(
              top: 12,
              right: 12,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 5.6) MÍDIA EM REPRODUÇÃO — faixa/rádio tocando em qualquer app (Spotify etc.)
// ---------------------------------------------------------------------------
//
// Para mostrar o que está tocando em outro app (Spotify, YouTube Music,
// rádio online, etc.) o Android exige que o launcher seja registrado como
// "acesso a notificações" (NotificationListenerService) — é a mesma
// permissão especial que qualquer app de "now playing" no Android usa. Ela
// é concedida manualmente pelo usuário em Configurações do sistema (não tem
// popup automático), então a tela de Configurações do launcher tem um botão
// que abre essa tela direto. O lado nativo fica em
// android/CarMediaListenerService.kt, que só lê METADADOS de sessões de
// mídia (título/artista/estado) — não lê o conteúdo de notificações.
class MediaInfoService extends ChangeNotifier {
  static const MethodChannel _mediaChannel = MethodChannel('com.neoncar.launcher/media');

  String? trackTitle;
  String? trackArtist;
  bool isPlaying = false;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _mediaChannel.setMethodCallHandler((call) async {
      if (call.method == 'onMediaChanged') {
        final args = Map<String, Object?>.from(call.arguments as Map);
        trackTitle = args['title'] as String?;
        trackArtist = args['artist'] as String?;
        isPlaying = args['isPlaying'] as bool? ?? false;
        notifyListeners();
      }
    });
    // Pede ao lado nativo para reenviar o estado atual, caso a sessão de
    // mídia já estivesse tocando antes do app abrir.
    _mediaChannel.invokeMethod('requestCurrent').catchError((_) {});
  }

  /// Abre a tela do sistema Android onde o usuário concede (ou revoga) o
  /// acesso a notificações para este launcher.
  Future<void> openNotificationAccessSettings() async {
    try {
      await _mediaChannel.invokeMethod('openNotificationSettings');
    } catch (_) {
      // Canal nativo indisponível (ex: rodando fora de um Android real).
    }
  }
}

// ---------------------------------------------------------------------------
// 6) CONECTIVIDADE — status real de Wi-Fi e Bluetooth
// ---------------------------------------------------------------------------

class ConnectivityMonitor extends StatefulWidget {
  const ConnectivityMonitor({super.key});

  @override
  State<ConnectivityMonitor> createState() => _ConnectivityMonitorState();
}

class _ConnectivityMonitorState extends State<ConnectivityMonitor> {
  bool _wifiConnected = false;
  bool _bluetoothOn = false;

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<BluetoothAdapterState>? _btSub;

  @override
  void initState() {
    super.initState();
    _bindWifi();
    _bindBluetooth();
  }

  Future<void> _bindWifi() async {
    final initial = await Connectivity().checkConnectivity();
    _applyConnectivity(initial);
    _connSub = Connectivity().onConnectivityChanged.listen(_applyConnectivity);
  }

  void _applyConnectivity(List<ConnectivityResult> results) {
    final connected = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    if (mounted) setState(() => _wifiConnected = connected);
  }

  Future<void> _bindBluetooth() async {
    if (await FlutterBluePlus.isSupported == false) return;
    await Permission.bluetoothConnect.request();
    _btSub = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) setState(() => _bluetoothOn = state == BluetoothAdapterState.on);
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _btSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          _wifiConnected ? Icons.wifi : Icons.wifi_off,
          size: 18,
          color: _wifiConnected ? Colors.white70 : Colors.white24,
        ),
        const SizedBox(width: 10),
        Icon(
          _bluetoothOn ? Icons.bluetooth : Icons.bluetooth_disabled,
          size: 18,
          color: _bluetoothOn ? Colors.white70 : Colors.white24,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 7) DOCK INFERIOR — abre Waze, Google Maps e Spotify reais + Mapa Offline
// ---------------------------------------------------------------------------

class AppDock extends StatelessWidget {
  const AppDock({super.key, required this.neon});
  final Color neon;

  Future<void> _openApp(BuildContext context, {
    required String package,
    required String storeUrl,
  }) async {
    try {
      await LaunchApp.openApp(
        androidPackageName: package,
        openStore: true,
        appStoreLink: storeUrl,
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Não foi possível abrir o app ($package).')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: neon.withOpacity(0.4)),
        boxShadow: [BoxShadow(color: neon.withOpacity(0.2), blurRadius: 16)],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _DockButton(
            icon: Icons.navigation_rounded,
            label: 'Waze',
            neon: neon,
            onTap: () => _openApp(context,
                package: 'com.waze',
                storeUrl: 'https://play.google.com/store/apps/details?id=com.waze'),
          ),
          _DockButton(
            icon: Icons.map_rounded,
            label: 'Google Maps',
            neon: neon,
            onTap: () => _openApp(context,
                package: 'com.google.android.apps.maps',
                storeUrl:
                    'https://play.google.com/store/apps/details?id=com.google.android.apps.maps'),
          ),
          _DockButton(
            icon: Icons.public,
            label: 'Mapa Offline',
            neon: neon,
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const OfflineMapScreen())),
          ),
          _DockButton(
            icon: Icons.music_note_rounded,
            label: 'Spotify',
            neon: neon,
            onTap: () => _openApp(context,
                package: 'com.spotify.music',
                storeUrl: 'https://play.google.com/store/apps/details?id=com.spotify.music'),
          ),
          _DockButton(
            icon: Icons.route_rounded,
            label: 'Viagens',
            neon: neon,
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const TripHistoryScreen())),
          ),
        ],
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.icon,
    required this.label,
    required this.neon,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color neon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.04),
                border: Border.all(color: neon.withOpacity(0.5)),
                boxShadow: [BoxShadow(color: neon.withOpacity(0.3), blurRadius: 10)],
              ),
              child: Icon(icon, color: neon, size: 26),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 8) MAPA OFFLINE — tiles locais em assets/map_tiles/{z}/{x}/{y}.png
// ---------------------------------------------------------------------------

/// Fornece tiles 100% offline, sem qualquer dependência de rede, a partir de
/// DUAS fontes possíveis:
///
///  1. Uma pasta externa (SD/pendrive) escolhida pelo usuário em
///     Configurações — permite trocar/ampliar a cobertura do mapa (ex: de
///     Mato Grosso para o Brasil inteiro) só copiando novos tiles para o
///     dispositivo, sem precisar recompilar o APK.
///  2. Os assets embutidos no próprio APK (assets/map_tiles/), usados como
///     padrão quando nenhuma pasta externa foi configurada.
class HybridTileProvider extends TileProvider {
  HybridTileProvider({this.externalBasePath});

  /// Caminho absoluto de uma pasta contendo tiles em {z}/{x}/{y}.png.
  /// Quando nulo, cai para os assets embutidos no APK.
  final String? externalBasePath;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final z = coordinates.z;
    final x = coordinates.x;
    final y = coordinates.y;

    final base = externalBasePath;
    if (base != null && base.isNotEmpty) {
      return FileImage(File('$base/$z/$x/$y.png'));
    }
    return AssetImage('assets/map_tiles/$z/$x/$y.png');
  }
}

class OfflineMapScreen extends StatelessWidget {
  const OfflineMapScreen({super.key});

  // Centro padrão: Cuiabá/MT. Ajuste para a região coberta pelos seus tiles.
  static const LatLng _initialCenter = LatLng(-15.6014, -56.0979);

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final neon = appState.palette.color;
    final mapFolder = appState.mapFolderPath;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF06060A),
        iconTheme: IconThemeData(color: neon),
        title: const Text('Mapa Offline', style: TextStyle(color: Colors.white)),
      ),
      backgroundColor: const Color(0xFF06060A),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.white.withOpacity(0.03),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mapFolder == null
                      ? 'Nenhum mapa real instalado ainda — o app só tem um '
                          'tile de exemplo embutido, por isso a tela abaixo '
                          'aparece em branco.'
                      : 'Usando pasta externa: $mapFolder',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                if (mapFolder == null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Gere os tiles da sua região com o MOBAC (gratuito, no '
                    'PC), copie a pasta gerada para o celular/pendrive e '
                    'aponte para ela em Configurações → Pasta de mapas '
                    'offline. Não recompila o app. Detalhes no README.',
                    style: TextStyle(color: neon.withOpacity(0.85), fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: FlutterMap(
              options: const MapOptions(
                initialCenter: _initialCenter,
                initialZoom: 13,
                minZoom: 4,
                maxZoom: 17,
              ),
              children: [
                TileLayer(
                  tileProvider: HybridTileProvider(externalBasePath: mapFolder),
                  // Nenhuma urlTemplate de rede: os tiles vêm 100% do local
                  // (pasta externa ou assets embutidos).
                  urlTemplate: '{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.neoncar.launcher',
                  errorTileCallback: (tile, error, stackTrace) {
                    // Tile ausente na fonte configurada: renderiza vazio
                    // silenciosamente (fora da área coberta pelos tiles).
                  },
                ),
                const MarkerLayer(markers: []),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 8.1) HISTÓRICO DE VIAGENS — lista local (sem nuvem)
// ---------------------------------------------------------------------------

class TripHistoryScreen extends StatefulWidget {
  const TripHistoryScreen({super.key});

  @override
  State<TripHistoryScreen> createState() => _TripHistoryScreenState();
}

class _TripHistoryScreenState extends State<TripHistoryScreen> {
  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final neon = appState.palette.color;

    return Scaffold(
      backgroundColor: const Color(0xFF06060A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF06060A),
        iconTheme: IconThemeData(color: neon),
        title: const Text('Viagens', style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: Icon(Icons.save_alt, color: neon),
            tooltip: 'Salvar viagem atual no histórico',
            onPressed: () async {
              await appState.tripHistory.saveTrip(appState.driving);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([appState.tripHistory, appState.driving]),
        builder: (context, _) {
          final driving = appState.driving;
          final trips = appState.tripHistory.trips;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.03),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: neon.withOpacity(0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Viagem em andamento',
                        style: TextStyle(color: neon, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _TripStat(label: 'Distância', value: '${driving.tripDistanceKm.toStringAsFixed(1)} km'),
                        _TripStat(label: 'Média', value: '${driving.tripAvgSpeedKmh.round()} km/h'),
                        _TripStat(label: 'Máxima', value: '${driving.tripMaxSpeedKmh.round()} km/h'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text('Histórico', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              if (trips.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('Nenhuma viagem salva ainda.', style: TextStyle(color: Colors.white38)),
                ),
              ...trips.map((trip) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.03),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.route_rounded, color: neon, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${trip.startedAt.day.toString().padLeft(2, '0')}/'
                                '${trip.startedAt.month.toString().padLeft(2, '0')} · '
                                '${trip.startedAt.hour.toString().padLeft(2, '0')}:'
                                '${trip.startedAt.minute.toString().padLeft(2, '0')}',
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${trip.distanceKm.toStringAsFixed(1)} km · média ${trip.avgSpeedKmh.round()} km/h · máx ${trip.maxSpeedKmh.round()} km/h',
                                style: const TextStyle(color: Colors.white38, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )),
            ],
          );
        },
      ),
    );
  }
}

class _TripStat extends StatelessWidget {
  const _TripStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 9) CONFIGURAÇÕES — seletor de cor neon
// ---------------------------------------------------------------------------

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _folderController;
  late final TextEditingController _reverseActionController;
  late final TextEditingController _obdAddressController;
  String? _feedback;

  @override
  void initState() {
    super.initState();
    final appState = AppStateScope.of(context);
    _folderController = TextEditingController(text: appState.mapFolderPath ?? '');
    _reverseActionController = TextEditingController(text: appState.reverseCameraAction ?? '');
    _obdAddressController = TextEditingController();
  }

  @override
  void dispose() {
    _folderController.dispose();
    _reverseActionController.dispose();
    _obdAddressController.dispose();
    super.dispose();
  }

  Future<void> _pickFolderAutomatically(AppState appState) async {
    try {
      // Em Android 11+, ler arquivos fora da pasta do próprio app exige a
      // permissão especial "Acesso a todos os arquivos".
      await Permission.manageExternalStorage.request();

      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Selecione a pasta com os tiles do mapa',
      );
      if (path == null) return; // usuário cancelou
      _folderController.text = path;
      await appState.setMapFolderPath(path);
      setState(() => _feedback = 'Pasta de mapas atualizada.');
    } catch (e) {
      // Em algumas centrais/ROMs automotivas o seletor de pastas do sistema
      // pode não estar disponível — nesse caso, use o campo de texto acima
      // para colar o caminho manualmente (ex: /storage/6331-6162/NeonMaps).
      setState(() => _feedback =
          'Não foi possível abrir o seletor automático. Cole o caminho manualmente no campo acima.');
    }
  }

  Future<void> _saveManualPath(AppState appState) async {
    final path = _folderController.text.trim();
    await appState.setMapFolderPath(path.isEmpty ? null : path);
    setState(() => _feedback = path.isEmpty
        ? 'Voltando a usar os tiles embutidos no APK.'
        : 'Pasta de mapas salva: $path');
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final current = appState.palette;
    final neon = current.color;

    return Scaffold(
      backgroundColor: const Color(0xFF06060A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF06060A),
        title: const Text('Configurações', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('Cor de destaque neon',
              style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          ...NeonPalette.values.map((palette) {
            final selected = palette == current;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => appState.setPalette(palette),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: Colors.white.withOpacity(0.03),
                    border: Border.all(
                      color: selected ? palette.color : Colors.white12,
                      width: selected ? 2 : 1,
                    ),
                    boxShadow: selected
                        ? [BoxShadow(color: palette.color.withOpacity(0.4), blurRadius: 14)]
                        : null,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: palette.color),
                      ),
                      const SizedBox(width: 16),
                      Text(palette.label, style: const TextStyle(color: Colors.white, fontSize: 15)),
                      const Spacer(),
                      if (selected) Icon(Icons.check_circle, color: palette.color),
                    ],
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 32),
          const Text('Pasta de mapas offline',
              style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'Aponte para uma pasta (SD/pendrive) com tiles no padrão '
            '{z}/{x}/{y}.png para trocar ou ampliar a cobertura do mapa '
            '(ex: de Mato Grosso para o Brasil inteiro) sem recompilar o app. '
            'Deixe em branco para usar os tiles já embutidos no APK.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _folderController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '/storage/6331-6162/NeonMaps',
              hintStyle: const TextStyle(color: Colors.white24),
              filled: true,
              fillColor: Colors.white.withOpacity(0.04),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: neon.withOpacity(0.3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: neon),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickFolderAutomatically(appState),
                  icon: Icon(Icons.folder_open, color: neon),
                  label: Text('Selecionar pasta', style: TextStyle(color: neon)),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: neon.withOpacity(0.5))),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => _saveManualPath(appState),
                  style: FilledButton.styleFrom(backgroundColor: neon.withOpacity(0.85)),
                  child: const Text('Salvar'),
                ),
              ),
            ],
          ),
          if (_feedback != null) ...[
            const SizedBox(height: 12),
            Text(_feedback!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],

          const SizedBox(height: 32),
          const Text('Chamadas viva-voz',
              style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'Mostra quem está ligando e permite atender/recusar direto na '
            'tela, sem precisar do CarPlay/Android Auto — funciona com o '
            'celular só pareado por Bluetooth para chamadas.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: neon,
            title: const Text('Ativar detecção de chamadas', style: TextStyle(color: Colors.white, fontSize: 14)),
            value: appState.callGuardEnabled,
            onChanged: (v) => appState.setCallGuardEnabled(v),
          ),

          const SizedBox(height: 24),
          const Text('Velocímetro de mídia (música/rádio)',
              style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'Para mostrar a faixa tocando no Spotify (ou outro app de música/'
            'rádio), o Android exige uma permissão especial chamada "Acesso a '
            'notificações", concedida manualmente pelo sistema — o app só lê '
            'o título/artista da sessão de mídia, nunca o conteúdo de outras '
            'notificações.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: appState.media.openNotificationAccessSettings,
            icon: Icon(Icons.notifications_active_outlined, color: neon),
            label: Text('Abrir acesso a notificações', style: TextStyle(color: neon)),
            style: OutlinedButton.styleFrom(side: BorderSide(color: neon.withOpacity(0.5))),
          ),

          const SizedBox(height: 24),
          const Text('OBD-II (Bluetooth)',
              style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'Cole o endereço MAC do seu adaptador ELM327 (pareie-o primeiro '
            'nas configurações de Bluetooth do Android da central). Isso lê '
            'RPM, temperatura do motor e nível de combustível reais da ECU.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _obdAddressController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '00:1D:A5:XX:XX:XX',
              hintStyle: const TextStyle(color: Colors.white24),
              filled: true,
              fillColor: Colors.white.withOpacity(0.04),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: neon.withOpacity(0.3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: neon),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    final addr = _obdAddressController.text.trim();
                    if (addr.isNotEmpty) appState.connectObd(addr);
                  },
                  style: FilledButton.styleFrom(backgroundColor: neon.withOpacity(0.85)),
                  child: const Text('Conectar'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: appState.disconnectObd,
                  style: OutlinedButton.styleFrom(side: BorderSide(color: neon.withOpacity(0.5))),
                  child: Text('Desconectar', style: TextStyle(color: neon)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AnimatedBuilder(
            animation: appState.obd,
            builder: (context, _) => Text(
              'Status: ${appState.obd.status}'
              '${appState.obd.rpm != null ? ' · ${appState.obd.rpm} RPM' : ''}'
              '${appState.obd.coolantTempC != null ? ' · ${appState.obd.coolantTempC}°C' : ''}'
              '${appState.obd.fuelPercent != null ? ' · ${appState.obd.fuelPercent}% combustível' : ''}'
              '${appState.obd.ambientTempC != null ? ' · ${appState.obd.ambientTempC}°C ambiente' : ''}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),

          const SizedBox(height: 24),
          const Text('Câmera de ré',
              style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'Só preencha isto se a SUA central troca para a câmera de ré via '
            'um broadcast Android (varia por fabricante — consulte o suporte '
            'da central). Muitas centrais já trocam sozinhas por hardware, '
            'sem precisar de nada aqui.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _reverseActionController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'com.exemplo.central.REVERSE',
              hintStyle: const TextStyle(color: Colors.white24),
              filled: true,
              fillColor: Colors.white.withOpacity(0.04),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: neon.withOpacity(0.3)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: neon),
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              final action = _reverseActionController.text.trim();
              appState.setReverseCameraAction(action.isEmpty ? null : action);
              setState(() => _feedback = action.isEmpty
                  ? 'Detecção de marcha-ré desativada.'
                  : 'Ouvindo o broadcast: $action');
            },
            style: FilledButton.styleFrom(backgroundColor: neon.withOpacity(0.85)),
            child: const Text('Salvar ação de marcha-ré'),
          ),
        ],
      ),
    );
  }
}
