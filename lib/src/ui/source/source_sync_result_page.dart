// 「这次从源仓库加了哪些书源」——同步是后台跑的，结果得能回头翻。
import 'package:flutter/material.dart';

import '../../source/source_store.dart';
import '../../source/source_sync_log.dart';
import 'source_health_page.dart';

class SourceSyncResultPage extends StatelessWidget {
  const SourceSyncResultPage({super.key, required this.log, this.store});

  final SourceSyncLog log;

  /// 传了就带一个「去体检」入口（体检会把这些新源也一起测）。
  final SourceStore? store;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = log.byCollection;
    final store = this.store;

    return Scaffold(
      appBar: AppBar(
        title: const Text('本次新增的书源'),
        actions: [
          if (store != null)
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SourceHealthPage(store: store),
                ),
              ),
              icon: const Icon(Icons.health_and_safety_outlined, size: 18),
              label: const Text('去体检'),
            ),
        ],
      ),
      body: log.at == null || log.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  log.at == null
                      ? '还没有同步过。\n回设置页点「同步源仓库」试试。'
                      : '${_fmt(log.at!)} 的同步没有新增书源。\n（合集没更新，或者都已存在）',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.8,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                Text(
                  '${_fmt(log.at!)} 同步：新增 ${log.addedCount} 个'
                  '${log.updated > 0 ? ' · 更新 ${log.updated} 个' : ''}'
                  '${log.collections > 0 ? ' · 来自 ${log.collections} 个合集' : ''}',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                if (log.error != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '部分合集下载失败：${log.error}',
                    style: TextStyle(fontSize: 11.5, color: scheme.error),
                  ),
                ],
                const SizedBox(height: 8),
                for (final entry in groups.entries)
                  Card(
                    elevation: 0,
                    margin: const EdgeInsets.only(bottom: 8),
                    color: scheme.surfaceContainerHighest.withValues(alpha: .45),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: ExpansionTile(
                      shape: const Border(),
                      initiallyExpanded: groups.length <= 3,
                      title: Text(
                        entry.key,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        '${entry.value.length} 个源',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      children: [
                        for (final item in entry.value)
                          ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                            title: Text(
                              item.name.isEmpty ? '(未命名)' : item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                            subtitle: Text(
                              _hostOf(item.url),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  static String _hostOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.host.isEmpty ? url : uri.host;
  }

  static String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
