import 'package:field/src/home/home_screen.dart';
import 'package:field/src/home/tab_refresh_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'only Home loads initially; each other tab loads on first visit',
    (tester) async {
      final repositories = List.generate(5, (_) => _Repository());
      final firstMounts = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: _Harness(repositories: repositories, firstMounts: firstMounts),
        ),
      );
      await tester.pumpAndSettle();

      expect(repositories.map((repo) => repo.loads), [1, 0, 0, 0, 0]);
      expect(firstMounts, [0]);
      for (var index = 1; index < 5; index++) {
        expect(
          find.byKey(ValueKey('probe-$index'), skipOffstage: false),
          findsNothing,
        );
        await tester.tap(find.byKey(ValueKey('nav-$index')));
        await tester.pumpAndSettle();
        expect(repositories[index].loads, 1);
        expect(find.text('Loaded tab $index'), findsOneWidget);
      }
      expect(repositories.map((repo) => repo.loads), [1, 1, 1, 1, 1]);
      expect(firstMounts, [0, 1, 2, 3, 4]);

      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      expect(repositories.map((repo) => repo.loads), [1, 1, 1, 1, 1]);
      expect(repositories.every((repo) => repo.disposals == 0), isTrue);
    },
  );

  testWidgets('returning to a visited tab retains its draft and local state', (
    tester,
  ) async {
    final repositories = List.generate(5, (_) => _Repository());
    await tester.pumpWidget(
      MaterialApp(home: _Harness(repositories: repositories)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('draft-1')),
      'An unfinished fixture filter',
    );
    tester.testTextInput.hide();
    await tester.tap(find.byKey(const ValueKey('increment-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-1')));
    await tester.pumpAndSettle();

    expect(find.text('An unfinished fixture filter'), findsOneWidget);
    expect(find.text('Tab 1 count 1'), findsOneWidget);
    expect(repositories[1].loads, 1);
    expect(repositories[1].disposals, 0);
  });

  testWidgets(
    'late first visit is fresh, while stale and explicit ticks reload',
    (tester) async {
      final repositories = List.generate(5, (_) => _Repository());
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: _Harness(key: key, repositories: repositories),
        ),
      );
      await tester.pumpAndSettle();
      // The shell can sit on Home for a long time before any other tab is used.
      key.currentState!.advance(const Duration(minutes: 2));
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      expect(repositories[1].loads, 1);
      key.currentState!.advance(const Duration(seconds: 30));
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      expect(repositories[1].loads, 1);

      key.currentState!.advance(const Duration(seconds: 31));
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      expect(repositories[1].loads, 2);
      // Existing booking-return ticks still reach a mounted, offstage tab.
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pumpAndSettle();
      key.currentState!.refreshTab(1);
      await tester.pumpAndSettle();
      expect(repositories[1].loads, 3);
      expect(repositories[2].loads, 0);
      // Refreshing an untouched tab does not mount/fetch it in the background.
      key.currentState!.refreshTab(4);
      await tester.pumpAndSettle();
      expect(repositories[4].loads, 0);
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await tester.pumpAndSettle();
      expect(repositories[4].loads, 1);
    },
  );

  testWidgets(
    'direct ranks navigation mounts once and keeps explicit reloads',
    (tester) async {
      final repositories = List.generate(5, (_) => _Repository());
      final firstMounts = <int>[];
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: _Harness(
            key: key,
            repositories: repositories,
            firstMounts: firstMounts,
          ),
        ),
      );
      await tester.pumpAndSettle();
      key.currentState!.openRanks();
      await tester.pumpAndSettle();
      expect(repositories.map((repo) => repo.loads), [1, 0, 0, 1, 0]);
      key.currentState!.openRanks();
      await tester.pumpAndSettle();
      expect(repositories[3].loads, 2);
      expect(firstMounts, [0, 3]);
      expect(repositories[3].disposals, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(repositories[0].disposals, 1);
      expect(repositories[3].disposals, 1);
      expect(repositories[1].disposals, 0);
    },
  );
}

class _Repository {
  int loads = 0;
  int disposals = 0;
  Future<void> load() async {
    loads++;
  }
}

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.repositories, this.firstMounts});
  final List<_Repository> repositories;
  final List<int>? firstMounts;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  int selected = 0;
  final ticks = List.filled(5, 0);
  DateTime now = DateTime.utc(2026, 10, 22);
  late final refresh = TabRefreshPolicy(now: now);

  void advance(Duration duration) => now = now.add(duration);

  void select(int index) {
    if (index == selected) return;
    setState(() {
      if (refresh.activate(index, now: now)) ticks[index]++;
      selected = index;
    });
  }

  void refreshTab(int index) {
    refresh.refreshed(index, now: now);
    setState(() => ticks[index]++);
  }

  void openRanks() => setState(() {
    ticks[3]++;
    selected = 3;
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: HomeTabStack(
      selectedIndex: selected,
      onFirstMount: (index) {
        refresh.refreshed(index, now: now);
        widget.firstMounts?.add(index);
      },
      tabBuilders: [
        for (var index = 0; index < 5; index++)
          (_) => _Probe(
            key: ValueKey('probe-$index'),
            index: index,
            repository: widget.repositories[index],
            activationTick: ticks[index],
          ),
      ],
    ),
    bottomNavigationBar: Row(
      children: [
        for (var index = 0; index < 5; index++)
          Expanded(
            child: TextButton(
              key: ValueKey('nav-$index'),
              onPressed: () => select(index),
              child: Text('$index'),
            ),
          ),
      ],
    ),
  );
}

class _Probe extends StatefulWidget {
  const _Probe({
    super.key,
    required this.index,
    required this.repository,
    required this.activationTick,
  });
  final int index;
  final _Repository repository;
  final int activationTick;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final draft = TextEditingController();
  int count = 0;
  late Future<void> loading;

  @override
  void initState() {
    super.initState();
    loading = widget.repository.load();
  }

  @override
  void didUpdateWidget(covariant _Probe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activationTick != widget.activationTick) {
      loading = widget.repository.load();
    }
  }

  @override
  void dispose() {
    widget.repository.disposals++;
    draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FutureBuilder(
        future: loading,
        builder: (_, snapshot) => Text(
          snapshot.connectionState == ConnectionState.done
              ? 'Loaded tab ${widget.index}'
              : 'Loading tab ${widget.index}',
        ),
      ),
      TextField(key: ValueKey('draft-${widget.index}'), controller: draft),
      TextButton(
        key: ValueKey('increment-${widget.index}'),
        onPressed: () => setState(() => count++),
        child: Text('Tab ${widget.index} count $count'),
      ),
    ],
  );
}
