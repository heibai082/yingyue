// 下载中心：全局缓存队列（排队 / 进度 / 暂停 / 重试 / 清理）。
import 'package:flutter/material.dart';

import '../data/book_store.dart';
import '../data/download_center.dart';
import 'widgets/cute.dart';

class DownloadCenterPage extends StatelessWidget {
  const DownloadCenterPage({super.key, required this.store, this.center});

  final BookStore store;

  /// 测试可注入；正式运行用全局单例。
  final DownloadCenter? center;

  DownloadCenter get _center => center ?? DownloadCenter.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载中心'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '清除已完成',
            onPressed: _center.clearFinished,
            icon: const Icon(Icons.playlist_remove_rounded),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _center,
        builder: (context, _) {
          final tasks = _center.tasks.reversed.toList();
          if (tasks.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_download_outlined,
                    size: 46,
                    color: Colors.grey,
                  ),
                  SizedBox(height: 10),
                  Text('还没有下载任务', style: TextStyle(color: Colors.grey)),
                  SizedBox(height: 6),
                  Text(
                    '去书籍详情把这本书加入队列吧',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: tasks.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _TaskCard(center: _center, task: tasks[i]),
            ),
          );
        },
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.center, required this.task});

  final DownloadCenter center;
  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = task.status == DownloadTaskStatus.running;
    final paused = task.status == DownloadTaskStatus.paused;
    final failed = task.status == DownloadTaskStatus.failed;
    return SoftCard(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '${(task.fraction * 100).round()}%',
                style: TextStyle(fontSize: 12, color: scheme.primary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: task.fraction,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  task.label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: failed ? Colors.redAccent : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (running)
                TextButton.icon(
                  onPressed: center.pauseCurrent,
                  icon: const Icon(Icons.pause_rounded, size: 16),
                  label: const Text('暂停', style: TextStyle(fontSize: 12)),
                ),
              if (paused)
                TextButton.icon(
                  onPressed: () => center.resumeTask(task.id),
                  icon: const Icon(Icons.play_arrow_rounded, size: 16),
                  label: const Text('继续', style: TextStyle(fontSize: 12)),
                ),
              if (failed)
                TextButton.icon(
                  onPressed: () => center.retry(task.id),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('重试', style: TextStyle(fontSize: 12)),
                ),
              if (!running && !paused)
                TextButton.icon(
                  onPressed: () => center.remove(task.id),
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('移除', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 供外部打开下载中心。
Future<void> openDownloadCenter(
  BuildContext context, {
  required BookStore store,
}) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => DownloadCenterPage(store: store)));
}
