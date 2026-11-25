// 把「已经缓存好的内容」导出成文件（换机 / 归档 / 丢 NAS 都方便）：
//   - 小说：按阅读顺序拼成一个 .txt（含章节标题；没缓存的章写明「未缓存」）；
//   - 漫画：把已缓存的话打成 .cbz（zip 里按话分目录、图片按清单顺序）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'export_dirs.dart';
import 'book_store.dart';
import 'chapter_cache.dart';
import 'models.dart';

/// 导出结果。
class ExportResult {
  const ExportResult({
    required this.path,
    required this.chapters,
    required this.bytes,
    this.skipped = 0,
  });

  final String path;
  final int chapters;
  final int bytes;

  /// 没缓存、所以没写进去的章数。
  final int skipped;
}

/// 缓存导出器。
class CacheExporter {
  CacheExporter({String? dirOverride, String? filesFallback})
    : _dirOverride = dirOverride,
      _filesFallback = filesFallback;

  final String? _dirOverride;
  final String? _filesFallback;

  /// 导出目录：外部存储 `Download/嘤阅导出`，拿不到就退回 App 私有目录。
  Future<Directory> _targetDir() => resolveExportDir(
    dirOverride: _dirOverride,
    filesFallback: _filesFallback,
  );

  static String _safeName(String raw) => safeFileName(raw, fallback: 'book');

  /// 导出小说正文（TXT）。
  Future<ExportResult> exportNovel(Book book, BookStore store) async {
    final order = _readingOrder(book);
    final buffer = StringBuffer()
      ..writeln(book.title)
      ..writeln(book.author.isEmpty ? '' : '作者：${book.author}')
      ..writeln('（导出自嘤阅，已缓存部分）')
      ..writeln();
    var chapters = 0;
    var skipped = 0;
    for (final index in order) {
      final text = await store.readCachedChapter(book, index);
      final title = book.chapters[index].title.trim();
      if (text == null) {
        skipped++;
        continue;
      }
      buffer
        ..writeln(title)
        ..writeln()
        ..writeln(text.trim())
        ..writeln()
        ..writeln('—' * 12)
        ..writeln();
      chapters++;
    }
    final dir = await _targetDir();
    final name = '${_safeName(book.title)}${chapters > 0 ? '' : '-空'}.txt';
    final file = File('${dir.path}/$name');
    await file.writeAsString(buffer.toString(), encoding: utf8);
    return ExportResult(
      path: file.path,
      chapters: chapters,
      bytes: await file.length(),
      skipped: skipped,
    );
  }

  /// 导出漫画（CBZ）。只打包已经落盘的图。
  Future<ExportResult> exportComic(Book book, BookStore store) async {
    final dir = await _targetDir();
    final file = File('${dir.path}/${_safeName(book.title)}.cbz');
    final archive = Archive();
    var chapters = 0;
    var images = 0; // 实际打包的图片数
    var skipped = 0;
    try {
      for (final index in _readingOrder(book)) {
        final imgDir = ChapterCache.imageDirFor(store.appDirs, book, index);
        if (!imgDir.existsSync()) {
          skipped++;
          continue;
        }
        final manifest = ChapterCache.readManifest(imgDir);
        final files = <File>[];
        if (manifest != null) {
          for (final e in manifest) {
            final f = File('${imgDir.path}/${e['f']}');
            if (f.existsSync() && f.lengthSync() > 0) files.add(f);
          }
        } else {
          files.addAll(
            imgDir
                .listSync()
                .whereType<File>()
                .where((f) => f.lengthSync() > 0)
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path)),
          );
        }
        if (files.isEmpty) {
          skipped++;
          continue;
        }
        final chapterName = _safeName(book.chapters[index].title)
            .replaceAll(' ', '')
            .trim();
        for (var i = 0; i < files.length; i++) {
          final ext = files[i].path.split('.').last;
          final bytes = await files[i].readAsBytes();
          archive.addFile(
            ArchiveFile(
              '${index.toString().padLeft(4, '0')}_$chapterName/'
              '${i.toString().padLeft(3, '0')}.$ext',
              bytes.length,
              bytes,
            ),
          );
          images++;
        }
        chapters++;
      }
    } catch (e) {
      // 打包失败也要留个能看懂的错，而不是静默生成半截文件
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    }
    if (images > 0) {
      final bytes = ZipEncoder().encode(archive);
      await file.writeAsBytes(bytes, flush: true);
    }
    return ExportResult(
      path: file.path,
      chapters: chapters,
      bytes: await file.length(),
      skipped: skipped,
    );
  }

  /// 阅读顺序：小说顺着排，漫画（最新话在前）倒过来，导出总是「从第 1 话到最后」。
  static List<int> _readingOrder(Book book) {
    final newestFirst = looksNewestFirst(book.chapters);
    return [
      for (var i = 0; i < book.chapters.length; i++)
        newestFirst ? book.chapters.length - 1 - i : i,
    ];
  }
}
