import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'data/local_store.dart';
import 'data/market_repository.dart';
import 'data/sync_service.dart';
import 'state/home_controller.dart';
import 'theme/app_theme.dart';
import 'ui/root_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LazyPersonApp());
}

class LazyPersonApp extends StatelessWidget {
  const LazyPersonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LazyPerson',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const _AppRoot(),
    );
  }
}

class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  HomeController? _controller;
  String _bootError = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final store = await LocalStore.open(
          p.join(await getDatabasesPath(), 'lazyperson.db'));
      final sync = SyncService(store: store);
      final repository = MarketRepository(store: store, sync: sync);
      await repository.ensureSeeded();
      // 直接进主界面；全市场同步由 HomeController 在后台跑（顶部进度条展示）
      setState(() => _controller = HomeController(repository));
    } catch (exc) {
      setState(() => _bootError = '$exc');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bootError.isNotEmpty) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('启动失败：$_bootError',
                style: const TextStyle(color: AppColors.rise, fontSize: 13)),
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: AppColors.warn)),
      );
    }
    return RootScreen(controller: controller);
  }
}
