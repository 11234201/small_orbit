import 'package:flutter/material.dart';
import '../core/task_model.dart';

Future<OrbitTask?> editTask(
  BuildContext context, {
  OrbitTask? task,
  String title = '',
}) => showDialog<OrbitTask>(
  context: context,
  builder: (_) => TaskEditor(task: task, title: title),
);

class TaskEditor extends StatefulWidget {
  const TaskEditor({super.key, this.task, this.title = ''});
  final OrbitTask? task;
  final String title;
  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  late final TextEditingController _title;
  DateTime? _date;
  int? _minute;
  RepeatKind _repeat = RepeatKind.none;
  int _importance = 2, _urgency = 2;
  String? _error;
  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _title = TextEditingController(text: task?.title ?? widget.title);
    _date = task?.date;
    _minute = task?.reminderMinute;
    _repeat = task?.repeat ?? RepeatKind.none;
    _importance = task?.importance ?? 2;
    _urgency = task?.urgency ?? 2;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = '给这件小事起个名字吧');
      return;
    }
    final task = widget.task;
    Navigator.pop(
      context,
      OrbitTask(
        id: task?.id ?? newTaskId(),
        title: _title.text.trim(),
        createdAt: task?.createdAt ?? DateTime.now(),
        date: _date,
        reminderMinute: _minute,
        repeat: _repeat,
        importance: _importance,
        urgency: _urgency,
        records: task?.records ?? {},
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.task == null ? '放进一件小事' : '整理这件小事'),
    content: SizedBox(
      width: 390,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              maxLength: 240,
              maxLines: 2,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                hintText: '比如，出门散步 20 分钟',
                errorText: _error,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text(_date == null ? '安排日期' : dayKey(_date!)),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2200, 12, 31),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                ),
                if (_date != null)
                  IconButton(
                    tooltip: '移除日期和提醒',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() {
                      _date = null;
                      _minute = null;
                      _repeat = RepeatKind.none;
                    }),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.notifications_none, size: 18),
                  label: Text(
                    _minute == null
                        ? '加个提醒'
                        : '${(_minute! ~/ 60).toString().padLeft(2, '0')}:${(_minute! % 60).toString().padLeft(2, '0')}',
                  ),
                  onPressed: () async {
                    final time = await showTimePicker(
                      context: context,
                      initialTime: _minute == null
                          ? TimeOfDay.now()
                          : TimeOfDay(
                              hour: _minute! ~/ 60,
                              minute: _minute! % 60,
                            ),
                    );
                    if (time != null)
                      setState(() {
                        _minute = time.hour * 60 + time.minute;
                        _date ??= dateOnly(DateTime.now());
                      });
                  },
                ),
                if (_minute != null)
                  IconButton(
                    tooltip: '移除提醒',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _minute = null),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<RepeatKind>(
              initialValue: _repeat,
              key: ValueKey(_repeat),
              decoration: const InputDecoration(labelText: '重复'),
              items: const [
                DropdownMenuItem(value: RepeatKind.none, child: Text('只做一次')),
                DropdownMenuItem(value: RepeatKind.daily, child: Text('每天')),
                DropdownMenuItem(
                  value: RepeatKind.weekly,
                  child: Text('每周 · 按所选日期的星期'),
                ),
              ],
              onChanged: (value) => setState(() {
                _repeat = value!;
                if (_repeat != RepeatKind.none)
                  _date ??= dateOnly(DateTime.now());
              }),
            ),
            const SizedBox(height: 18),
            _level(
              '重要程度',
              _importance,
              (value) => setState(() => _importance = value),
            ),
            const SizedBox(height: 10),
            _level(
              '紧急程度',
              _urgency,
              (value) => setState(() => _urgency = value),
            ),
            const SizedBox(height: 10),
            const Text(
              '越重要、越紧急，泡泡就越大。',
              style: TextStyle(fontSize: 12, color: Color(0xff777180)),
            ),
            if (_repeat != RepeatKind.none)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '漏做的旧期留在历史里，新周期只出现一个待办。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('先放一放'),
      ),
      FilledButton(
        onPressed: _save,
        child: Text(widget.task == null ? '放进去' : '保存'),
      ),
    ],
  );
  Widget _level(String label, int value, ValueChanged<int> changed) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    runSpacing: 4,
    children: [
      SizedBox(width: 76, child: Text(label)),
      ...List.generate(
        3,
        (index) => Padding(
          padding: const EdgeInsets.only(right: 5),
          child: ChoiceChip(
            label: Text(['低', '中', '高'][index]),
            selected: value == index + 1,
            showCheckmark: false,
            onSelected: (_) => changed(index + 1),
          ),
        ),
      ),
    ],
  );
}
