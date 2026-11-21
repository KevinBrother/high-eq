import 'package:flutter/material.dart';
import '../../core/transport.dart';
import 'models.dart';
import 'scene.dart';

const retention = '请使用称呼，不必填写真名。问答和画像可能涉及他人信息，服务端加密保留至你删除关系人或注销账号。';
const chatRetention =
    '聊天片段可能含有他人信息。请隐去姓名、联系方式，只粘贴有权分享的必要片段。用于画像推断的聊天原文将在 24 小时内删除；画像保留至删除关系人或注销。';

class ContactForm extends StatefulWidget {
  const ContactForm({
    super.key,
    required this.initialScene,
    required this.questions,
    required this.onSave,
    this.contact,
  });
  final Scene initialScene;
  final Contact? contact;
  final List<Question> questions;
  final ValueChanged<Json> onSave;
  @override
  State<ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends State<ContactForm> {
  late final name = TextEditingController(text: widget.contact?.name);
  late Scene scene = widget.contact?.scene ?? widget.initialScene;
  late final answers = [
    for (final _ in widget.questions) TextEditingController(),
  ];
  int step = 0;
  bool get last => step == answers.length;
  @override
  void dispose() {
    name.dispose();
    for (final a in answers) {
      a.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final edit = widget.contact != null;
    final field = step == 0 ? name : answers[step - 1];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!edit) ...[
          Text(
            step == 0 ? '认识一下' : '观察手记 · $step / ${answers.length}',
            style: theme.labelLarge,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: (step + 1) / (answers.length + 1)),
          const SizedBox(height: 20),
        ],
        if (step == 0) ...[
          Text('怎么称呼对方？', style: theme.headlineSmall),
          const SizedBox(height: 8),
          const Text(retention),
          const SizedBox(height: 20),
          TextField(
            controller: name,
            decoration: const InputDecoration(
              labelText: '称呼',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          Text('你们通常在哪种场景交流？', style: theme.titleMedium),
          ScenePicker(
            value: scene,
            onChanged: (s) => setState(() => scene = s),
          ),
        ] else ...[
          Text(widget.questions[step - 1].prompt, style: theme.headlineSmall),
          const SizedBox(height: 8),
          const Text('回想最近一次交流。不确定时，不必猜测。'),
          const SizedBox(height: 16),
          TextField(
            key: ValueKey(step),
            controller: field,
            minLines: 2,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '你的观察',
              border: OutlineInputBorder(),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => field.text = '还不确定'),
              child: const Text('还不确定'),
            ),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: field.text.trim().isEmpty
              ? null
              : () {
                  FocusScope.of(context).unfocus();
                  if (!last) {
                    setState(() => step++);
                    return;
                  }
                  widget.onSave({
                    'nickname': name.text.trim(),
                    'scene': scene.name,
                    if (!edit)
                      'answers': [
                        for (var i = 0; i < answers.length; i++)
                          {
                            'question_id': widget.questions[i].id,
                            'answer': answers[i].text.trim(),
                          },
                      ],
                  });
                },
          child: Text(last ? '保存关系人' : '下一步'),
        ),
        if (step > 0)
          TextButton(
            onPressed: () => setState(() => step--),
            child: const Text('上一题'),
          ),
      ],
    );
  }
}

class ChatForm extends StatefulWidget {
  const ChatForm({super.key, required this.onSubmit});
  final ValueChanged<String> onSubmit;
  @override
  State<ChatForm> createState() => _ChatFormState();
}

class _ChatFormState extends State<ChatForm> {
  final text = TextEditingController();
  bool consent = false;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('补充一次对话', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      const Text(chatRetention),
      CheckboxListTile(
        value: consent,
        onChanged: (v) => setState(() {
          consent = v == true;
          if (!consent) text.clear();
        }),
        title: const Text('我已了解，并有权分享这段内容'),
      ),
      if (consent)
        TextField(
          controller: text,
          minLines: 3,
          maxLines: 6,
          enableSuggestions: false,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: '粘贴必要片段',
            border: OutlineInputBorder(),
          ),
        ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: consent && text.text.trim().isNotEmpty
            ? () {
                final value = text.text.trim();
                text.clear();
                widget.onSubmit(value);
              }
            : null,
        child: const Text('提交片段'),
      ),
    ],
  );
}
