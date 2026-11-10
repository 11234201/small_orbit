import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:small_orbit/core/task_model.dart';
import 'package:small_orbit/ui/task_editor.dart';
import 'package:small_orbit/ui/task_stage.dart';

Widget editorHost({
  required Future<void> Function(OrbitTask) save,
  required ValueChanged<OrbitTask?> result,
  OrbitTask? task,
}) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () async {
            result(await editTask(context, task: task, onSave: save));
          },
          child: const Text('打开编辑器'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('completing a paper does not animate its neighbor as completed', (
    tester,
  ) async {
    final now = DateTime(2026, 11, 10);
    var items = ['first', 'second']
        .map(
          (id) => OrbitTask(id: id, title: id, createdAt: now).activeAt(now)!,
        )
        .toList();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => TaskStage(
              items: items,
              settings: const AppSettings(display: DisplayMode.papers),
              onComplete: (completed) async {
                setState(() {
                  items = items
                      .where((item) => item.identity != completed.identity)
                      .toList();
                });
              },
              onEdit: (_) {},
              onDelete: (_) {},
              replay: 0,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('收进口袋').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    final transition = tester.widget<ScaleTransition>(
      find.descendant(
        of: find.byType(AnimatedScale),
        matching: find.byType(ScaleTransition),
      ),
    );
    expect(transition.scale.value, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed editor save keeps the complete draft for retry', (
    tester,
  ) async {
    var attempts = 0;
    final results = <OrbitTask?>[];
    final saved = <OrbitTask>[];
    final original = OrbitTask(
      id: 'draft',
      title: '原来的任务',
      createdAt: DateTime(2026, 11, 10),
      date: DateTime(2026, 11, 11),
      reminderMinute: 9 * 60 + 30,
      repeat: RepeatKind.weekly,
      importance: 3,
    );
    await tester.pumpWidget(
      editorHost(
        task: original,
        result: results.add,
        save: (task) async {
          attempts++;
          if (attempts == 1) throw StateError('disk full');
          saved.add(task);
        },
      ),
    );
    await tester.tap(find.text('打开编辑器'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '已经修改、不能丢掉的草稿');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(TaskEditor), findsOneWidget);
    expect(find.textContaining('没有保存成功，请重试'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '已经修改、不能丢掉的草稿',
    );
    expect(results, isEmpty);
    expect(saved, isEmpty);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(results.single, same(saved.single));
    expect(saved.single.title, '已经修改、不能丢掉的草稿');
    expect(saved.single.date, original.date);
    expect(saved.single.reminderMinute, original.reminderMinute);
    expect(saved.single.repeat, original.repeat);
    expect(saved.single.importance, original.importance);
    expect(find.byType(TaskEditor), findsNothing);
    expect(find.text('打开编辑器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending editor save rejects duplicate submission and dismissal',
    (tester) async {
      final gate = Completer<void>();
      var attempts = 0;
      final results = <OrbitTask?>[];
      await tester.pumpWidget(
        editorHost(
          result: results.add,
          save: (_) async {
            attempts++;
            await gate.future;
          },
        ),
      );
      await tester.tap(find.text('打开编辑器'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '只保存一次');
      final submit = tester
          .widget<TextField>(find.byType(TextField))
          .onSubmitted!;
      submit('只保存一次');
      submit('只保存一次');
      await tester.pump();
      expect(attempts, 1);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '放进去'))
            .onPressed,
        isNull,
      );
      await tester.tapAt(const Offset(2, 2));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(TaskEditor), findsOneWidget);
      expect(results, isEmpty);
      gate.complete();
      await tester.pumpAndSettle();
      expect(results.single!.title, '只保存一次');
      expect(find.byType(TaskEditor), findsNothing);
      expect(find.text('打开编辑器'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
