import 'dart:async';
import 'package:flutter/material.dart';
import '../app.dart';
import 'shell.dart';
import '../state/app_state.dart';
import '../services/app_update_service.dart';
import '../widgets/update_dialog.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _typewriterController;
  late final AnimationController _fadeController;
  late final AnimationController _logoController;
  late final Animation<int> _charCount;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;

  String get _title => 'Flutter Installer';
  String get _subtitle => 'تثبيت وإدارة Flutter و Dart SDKs';
  String get _subtitle2 => 'Dart-only • No Backend • System Commands';

  Future<AppState>? _stateFuture;
  AppState? _appState;
  Timer? _minDisplayTimer;
  bool _animationComplete = false;
  bool _stateReady = false;
  bool _updateChecked = false;

  @override
  void initState() {
    super.initState();

    // Typewriter animation for title
    _typewriterController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );

    _charCount = StepTween(
      begin: 0,
      end: _title.length,
    ).animate(CurvedAnimation(
      parent: _typewriterController,
      curve: Curves.easeOut,
    ));

    // Logo animation
    _logoController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _logoScale = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _logoController,
      curve: Curves.elasticOut,
    ));

    _logoOpacity = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _logoController,
      curve: Curves.easeIn,
    ));

    // Fade in subtitles
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    ));

    // Start animations sequence
    _startAnimations();

    // Initialize app state with minimum display time for nice animation
    _minDisplayTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) {
        setState(() => _animationComplete = true);
        _checkAndNavigate();
      }
    });

    _stateFuture = FlutterInstallerApp.createState();
    _stateFuture!.then((state) {
      if (mounted) {
        setState(() {
          _appState = state;
          _stateReady = true;
        });
        _checkAndNavigate();
      }
    });
  }

  void _startAnimations() async {
    // Start logo first with bounce
    await Future.delayed(const Duration(milliseconds: 100));
    if (mounted) {
      _logoController.forward();
    }

    // Start typing title
    await Future.delayed(const Duration(milliseconds: 250));
    if (mounted) {
      _typewriterController.forward();
    }

    // Fade in subtitles
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) {
      _fadeController.forward();
    }
  }

  void _checkAndNavigate() async {
    if (_animationComplete && _stateReady && _appState != null && mounted) {
      if (!_updateChecked) {
        _updateChecked = true;
        try {
          final release = await AppUpdateService.checkForUpdates();
          if (release != null && AppUpdateService.hasUpdate(release) && mounted) {
            if (!mounted) return;
            await showDialog(
              context: context,
              barrierDismissible: true,
              builder: (context) => UpdateDialog(release: release),
            );
          }
        } catch (_) {}
      }

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              Shell(state: _appState!),
          transitionDuration: const Duration(milliseconds: 400),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: animation,
              child: child,
            );
          },
        ),
      );
    }
  }

  @override
  void dispose() {
    _typewriterController.dispose();
    _fadeController.dispose();
    _logoController.dispose();
    _minDisplayTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0E1726),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0E1726),
              Color(0xFF16233A),
              Color(0xFF0E1726),
            ],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Animated Flutter logo
              AnimatedBuilder(
                animation: _logoController,
                builder: (context, child) {
                  return Opacity(
                    opacity: _logoOpacity.value,
                    child: Transform.scale(
                      scale: _logoScale.value,
                      child: Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              const Color(0xFF45D1FD).withValues(alpha: 0.2),
                              Colors.transparent,
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF45D1FD).withValues(alpha: 0.3),
                              blurRadius: 60,
                              spreadRadius: 10,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.flutter_dash,
                          size: 80,
                          color: Color(0xFF45D1FD),
                        ),
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(height: 40),

              // Typewriter title
              AnimatedBuilder(
                animation: _charCount,
                builder: (context, child) {
                  final text = _title.substring(0, _charCount.value);
                  return ShaderMask(
                    shaderCallback: (bounds) {
                      return const LinearGradient(
                        colors: [Color(0xFF45D1FD), Color(0xFF2BD576)],
                      ).createShader(bounds);
                    },
                    child: Text(
                      text,
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                        fontSize: 42,
                        height: 1.1,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  );
                },
              ),

              const SizedBox(height: 24),

              // Subtitles with fade
              FadeTransition(
                opacity: _fadeAnimation,
                child: Column(
                  children: [
                    Text(
                      _subtitle,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.9),
                        fontSize: 16,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                      textDirection: TextDirection.rtl,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _subtitle2,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.6),
                        fontSize: 13,
                        letterSpacing: 0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 60),

              // Loading indicator with fade
              FadeTransition(
                opacity: _fadeAnimation,
                child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFF45D1FD),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
