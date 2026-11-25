import 'package:flutter/material.dart';

import '../progress.dart';
import 'models.dart';
import 'presentation.dart';

const _healthConsentOff = '健康数据授权已关闭。';
const _voiceConsentOff = '语音特征授权已关闭。';

class BaselineProgressSection extends StatelessWidget {
  const BaselineProgressSection({
    super.key,
    required this.progress,
    required this.error,
    required this.onReload,
  });

  final BaselineProgress? progress;
  final String? error;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final snapshot = progress;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text('信号基线进度', style: theme.textTheme.titleLarge),
        ),
        const SizedBox(height: 8),
        if (error case final message?)
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          )
        else if (snapshot == null)
          Semantics(liveRegion: true, child: const Text('正在读取基线进度…'))
        else ...[
          const Text('时长信号分别累计。每天满 30 分钟计 1 个有效日，满 7 个有效日后就绪。'),
          const SizedBox(height: 8),
          _DurationCard(
            label: '心率',
            progress: snapshot.heartRate,
            consentOff: _healthConsentOff,
          ),
          _DurationCard(
            label: '语速',
            progress: snapshot.speechRate,
            consentOff: _voiceConsentOff,
            sourceNote: '本手机的设备端转写来源当前不可用。',
          ),
          _DurationCard(
            label: '音量',
            progress: snapshot.volume,
            consentOff: _voiceConsentOff,
          ),
          _DurationCard(
            label: '音调',
            progress: snapshot.pitch,
            consentOff: _voiceConsentOff,
          ),
          _HrvCard(trend: snapshot.hrv),
        ],
        if (snapshot != null || error != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: assistButtonStyle,
              onPressed: onReload,
              icon: const Icon(Icons.refresh),
              label: const Text('重新读取基线'),
            ),
          ),
      ],
    );
  }
}

class _DurationCard extends StatelessWidget {
  const _DurationCard({
    required this.label,
    required this.progress,
    required this.consentOff,
    this.sourceNote,
  });

  final String label;
  final DurationProgress? progress;
  final String consentOff;
  final String? sourceNote;

  @override
  Widget build(BuildContext context) {
    final data = progress;
    final note = sourceNote;
    return _SignalCard(
      label: label,
      children: data == null
          ? [Text(consentOff)]
          : [
              Text('${data.validDays} / 7 个有效日'),
              Text('今日 ${data.todayValidSeconds} / 1800 秒'),
              const SizedBox(height: 4),
              ExcludeSemantics(
                child: LinearProgressIndicator(
                  value: (data.todayValidSeconds / 1800).clamp(0.0, 1.0),
                ),
              ),
              const SizedBox(height: 4),
              Text(data.reason),
              if (note != null) Text(note),
            ],
    );
  }
}

class _HrvCard extends StatelessWidget {
  const _HrvCard({required this.trend});

  final HrvTrend? trend;

  @override
  Widget build(BuildContext context) {
    final data = trend;
    return _SignalCard(
      label: 'HRV',
      children: [
        const Text('仅用于趋势'),
        if (data == null)
          const Text(_healthConsentOff)
        else ...[
          Text('${data.readings} 次读数 · ${data.samplingDays} 个采样日'),
          Text(data.reason),
        ],
      ],
    );
  }
}

class _SignalCard extends StatelessWidget {
  const _SignalCard({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      ),
    ),
  );
}
