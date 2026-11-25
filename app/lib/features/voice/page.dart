import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/consent.dart';
import '../../core/session.dart';
import 'access.dart';
import 'controller.dart';
import 'platform.dart';
import 'store.dart';

class VoicePage extends StatefulWidget {
  final VoiceController controller;
  final VoidCallback? onOpenEmotion;
  const VoicePage({super.key, required this.controller, this.onOpenEmotion});

  factory VoicePage.forAccount({
    Key? key,
    required AppApi api,
    required AccountScope scope,
    required ConsentGate gate,
    VoidCallback? onOpenEmotion,
  }) {
    final platform = MethodChannelVoiceCapture();
    return VoicePage(
      key: key,
      onOpenEmotion: onOpenEmotion,
      controller: VoiceController(
        sessions: api.sessions,
        scope: scope,
        access: ApiVoiceAccess(api, gate: gate),
        uploader: ApiVoiceUploader(api),
        platform: platform,
        store: VoiceWindowStore(api.sessions, scope),
      ),
    );
  }

  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> with WidgetsBindingObserver {
  late final Timer _ticker;
  int _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    unawaited(widget.controller.initialize());
  }

  @override
  void dispose() {
    _ticker.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        (widget.controller.isCapturing ||
            widget.controller.status == VoiceStatus.starting)) {
      unawaited(widget.controller.stop());
    }
  }

  void _changed() {
    if (mounted) setState(_tick);
  }

  void _tick() {
    final started = widget.controller.captureStartedAt;
    final seconds = started == null
        ? 0
        : DateTime.now().difference(started).inSeconds;
    if (mounted && seconds != _elapsedSeconds) {
      setState(() => _elapsedSeconds = seconds);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('语音特征与录音')),
      body: SafeArea(
        child: Column(
          children: [
            if (controller.isCapturing)
              _CaptureBanner(
                seconds: _elapsedSeconds,
                recording: controller.retainAudio,
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
                children: [
                  _intro(context),
                  if (widget.onOpenEmotion case final openEmotion?)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.insights_outlined),
                      title: const Text('查看本人情绪汇总'),
                      trailing: const Icon(Icons.chevron_right),
                      enabled:
                          !controller.isCapturing &&
                          controller.status != VoiceStatus.starting &&
                          controller.status != VoiceStatus.stopping &&
                          controller.playingRecordingId == null,
                      onTap: openEmotion,
                    ),
                  const SizedBox(height: 16),
                  _captureCard(context),
                  const SizedBox(height: 14),
                  _retentionCard(context),
                  const SizedBox(height: 14),
                  _privacyCard(context),
                  if (controller.latestAnalysis != null) ...[
                    const SizedBox(height: 14),
                    _metricsCard(context),
                  ],
                  const SizedBox(height: 14),
                  _queueCard(context),
                  const SizedBox(height: 14),
                  _recordingsCard(context),
                  if (controller.notice != null) ...[
                    const SizedBox(height: 14),
                    _noticeCard(context, controller.notice!),
                  ],
                  const SizedBox(height: 20),
                  _revokeButton(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq, color: colors.onPrimaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '只看本机计算出的波动',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '音量、音调与声学音节速率在本机提取，每 30 秒只上传统计值。'
            '转写不可用：本机没有离线识别，也不会退回云端识别。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onPrimaryContainer,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }

  Widget _captureCard(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    final active = controller.isCapturing;
    final unavailable =
        !controller.memberActive || controller.voiceRevocationPending;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: _statusDot(
                    active
                        ? const Color(0xffc33636)
                        : theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    active ? '正在本地分析语音' : '语音采集未开启',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Chip(
              avatar: const Icon(Icons.text_fields, size: 16),
              label: Text(controller.transcriptionLabel),
            ),
            const SizedBox(height: 10),
            Text(
              active
                  ? '状态会在本页顶部持续显示。离开本页、切到后台或撤回授权会立即停止。'
                  : '仅会员可用；先完成 App 内单独同意，再请求系统麦克风权限。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            if (controller.voiceRevocationPending) ...[
              const SizedBox(height: 12),
              Text(
                '上次撤回尚未同步。本机不会采集或补传旧窗口。',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () =>
                    unawaited(widget.controller.retryVoiceRevocation()),
                icon: const Icon(Icons.sync),
                label: const Text('重试完成撤回'),
              ),
            ] else ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: unavailable
                      ? null
                      : () => unawaited(
                          active ? _stopCapture() : _beginVoice(context),
                        ),
                  icon: Icon(active ? Icons.stop : Icons.mic_none),
                  label: Text(active ? '停止本地分析' : '开启语音特征分析'),
                ),
              ),
            ],
            if (!controller.memberActive && !controller.voiceRevocationPending)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '当前会员权益未生效，语音采集保持关闭。',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _retentionCard(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            value: controller.retainAudio,
            onChanged:
                (controller.voiceRevocationPending ||
                    (!controller.voiceConsent && !controller.retainAudio) ||
                    (!controller.memberActive && !controller.retainAudio))
                ? null
                : (value) => unawaited(_changeRetention(context, value)),
            secondary: const Icon(Icons.lock_outline),
            title: const Text('录音保留（默认关）'),
            subtitle: Text(
              controller.retainAudio
                  ? '本机加密保存完整 30 秒窗口，3 天后自动删除。'
                  : '关闭时仍可做特征分析；不会保存原始录音。',
            ),
          ),
          if (controller.retentionRevocationPending)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '录音已删除，服务端撤回待同步。',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        unawaited(widget.controller.retryRetentionRevocation()),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _privacyCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('混音只描述对话波动', style: theme.textTheme.titleSmall),
            const SizedBox(height: 7),
            Text(
              '麦克风可能同时收到对方声音。结果不能证明谁在激动，也不会据此归因为本人。'
              '录音会包含他人声音，开启前建议告知对方。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 8),
            Text(
              '不保存逐秒数组，不上传音频、PCM 或转写。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricsCard(BuildContext context) {
    final analysis = widget.controller.latestAnalysis!;
    final theme = Theme.of(context);
    final level = widget.controller.levelDb;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最近完整窗口', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (level != null) ...[
              Row(
                children: [
                  const Icon(Icons.mic, size: 18),
                  const SizedBox(width: 8),
                  Text('当前输入 ${level.toStringAsFixed(1)} dBFS'),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 7),
              LinearProgressIndicator(
                value: ((level + 60) / 60).clamp(0, 1),
                minHeight: 6,
                borderRadius: BorderRadius.circular(99),
              ),
              const SizedBox(height: 14),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _metric(context, '人声', '${analysis.voicedSeconds} 秒'),
                _metric(
                  context,
                  '音量均值',
                  analysis.volume == null
                      ? '—'
                      : '${analysis.volume!.mean.toStringAsFixed(1)} dB',
                ),
                _metric(
                  context,
                  '音调均值',
                  analysis.pitch == null
                      ? '—'
                      : '${analysis.pitch!.mean.toStringAsFixed(0)} Hz',
                ),
                _metric(
                  context,
                  '音节速率代理',
                  analysis.speechRate == null
                      ? '—'
                      : '${analysis.speechRate!.mean.toStringAsFixed(0)} / 分',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '“音节速率代理”来自能量峰，不是逐字转写语速，也没有转写文本。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 130),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _queueCard(BuildContext context) {
    final controller = widget.controller;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.cloud_upload_outlined),
        title: Text('待上传统计窗口：${controller.pendingCount}'),
        subtitle: const Text('仅统计值，使用账号隔离的 AES-GCM 本机队列。'),
        trailing: controller.pendingCount == 0
            ? null
            : TextButton(
                onPressed: controller.uploading
                    ? null
                    : () => unawaited(controller.uploadPending()),
                child: Text(controller.uploading ? '上传中' : '重试'),
              ),
      ),
    );
  }

  Widget _recordingsCard(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history),
                const SizedBox(width: 9),
                Expanded(
                  child: Text('本机录音', style: theme.textTheme.titleMedium),
                ),
                Text(
                  '最多 3 天',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (controller.recordings.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  controller.retainAudio
                      ? '下一个完整 30 秒窗口完成后才会出现录音。'
                      : '没有保留录音。历史页只显示仍在 3 天内的本机条目。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final recording in controller.recordings)
                _recordingTile(context, recording),
          ],
        ),
      ),
    );
  }

  Widget _recordingTile(BuildContext context, VoiceRecording recording) {
    final controller = widget.controller;
    final playing = controller.playingRecordingId == recording.id;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(playing ? Icons.graphic_eq : Icons.audio_file_outlined),
      title: Text(_timeLabel(recording.startsAt.toLocal())),
      subtitle: Text(
        '30 秒 · 本机加密 · ${_expiryLabel(recording.expiresAt.toLocal())} 到期',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: playing ? '停止回听' : '本机回听',
            onPressed: () => unawaited(
              playing
                  ? controller.stopPlayback()
                  : controller.playRecording(recording.id),
            ),
            icon: Icon(playing ? Icons.stop_circle : Icons.play_circle_outline),
          ),
          IconButton(
            tooltip: '删除本机录音',
            onPressed: () =>
                unawaited(controller.deleteRecording(recording.id)),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  Widget _noticeCard(BuildContext context, String notice) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(notice)),
        ],
      ),
    );
  }

  Widget _revokeButton(BuildContext context) {
    final controller = widget.controller;
    if (!controller.voiceConsent && !controller.isCapturing) {
      return const SizedBox.shrink();
    }
    return OutlinedButton.icon(
      onPressed: () => unawaited(_revokeVoice(context)),
      icon: const Icon(Icons.mic_off_outlined),
      label: const Text('撤回语音授权并清除本机待发窗口'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
        minimumSize: const Size.fromHeight(48),
      ),
    );
  }

  Future<void> _beginVoice(BuildContext context) async {
    final controller = widget.controller;
    if (!controller.voiceConsent) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('单独同意语音特征采集'),
          content: const Text(
            '本机将提取音量、音调和声学音节速率，并每 30 秒上传统计值。'
            '麦克风可能混入对方声音，结果不能据此认定本人情绪。'
            '本机没有离线转写，不会把音频送到云端识别。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('暂不开启'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('同意并继续'),
            ),
          ],
        ),
      );
      if (accepted != true || !context.mounted) return;
      if (!await controller.grantVoiceConsent()) return;
    }
    await controller.start();
  }

  Future<void> _stopCapture() => widget.controller.stop();

  Future<void> _changeRetention(BuildContext context, bool enabled) async {
    final controller = widget.controller;
    if (enabled) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('单独同意录音保留'),
          content: const Text(
            '录音会包含对方的声音，仅以加密形式保存在本机 3 天，建议告知对方。'
            '开启后只保留完整的 30 秒窗口；关闭会立即删除本机已有录音。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('同意录音保留'),
            ),
          ],
        ),
      );
      if (accepted == true) await controller.enableRetention();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关闭并删除本机录音？'),
        content: const Text('关闭录音保留会立即删除全部本机录音，但不会影响语音特征分析。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('关闭并删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.disableRetention();
  }

  Future<void> _revokeVoice(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤回语音授权？'),
        content: const Text(
          '会立即停止采集，先清空本机未上传窗口，再删除本机录音并同步撤回。'
          '恢复联网后也不会补传撤回前的窗口。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('撤回并清除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.controller.revokeVoice();
  }

  static Widget _statusDot(Color color) => Container(
    width: 11,
    height: 11,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  static String _timeLabel(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.month} 月 ${time.day} 日 ${two(time.hour)}:${two(time.minute)}';
  }

  static String _expiryLabel(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.month}/${time.day} ${two(time.hour)}:${two(time.minute)}';
  }
}

class _CaptureBanner extends StatelessWidget {
  final int seconds;
  final bool recording;
  const _CaptureBanner({required this.seconds, required this.recording});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = recording
        ? const Color(0xffb42318)
        : theme.colorScheme.primary;
    final label = recording ? '正在录音并本地分析' : '正在本地分析语音（不保存录音）';
    return Semantics(
      liveRegion: true,
      label: '$label，已持续 $seconds 秒',
      child: Material(
        color: recording
            ? const Color(0xffffe4e0)
            : theme.colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.35),
                      blurRadius: 7,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                style: TextStyle(
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
