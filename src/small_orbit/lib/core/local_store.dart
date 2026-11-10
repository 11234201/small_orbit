import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'task_model.dart';

class BackupCodec {
  static const maxBytes = 16 * 1024 * 1024;
  static String encode(OrbitDocument document) {
    final payload = jsonEncode(document.toJson());
    return jsonEncode({
      'format': 'small-orbit',
      'version': 1,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'payload': payload,
      'sha256': sha256.convert(utf8.encode(payload)).toString(),
    });
  }

  static OrbitDocument decode(String source) {
    try {
      if (utf8.encode(source).length > maxBytes)
        throw const FormatException('文件超过 16 MB');
      final raw = jsonDecode(source);
      if (raw is! Map || raw['format'] != 'small-orbit')
        throw const FormatException('不是小事星球备份');
      if (raw['version'] != 1) throw const FormatException('备份版本不支持，请升级应用');
      final payload = raw['payload'];
      if (payload is! String ||
          sha256.convert(utf8.encode(payload)).toString() != raw['sha256']) {
        throw const FormatException('文件校验失败，内容可能已损坏');
      }
      return OrbitDocument.fromJson(
        Map<String, dynamic>.from(jsonDecode(payload) as Map),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('备份内容格式无效');
    }
  }
}

class LocalStore {
  LocalStore(this.directory);
  final Directory directory;
  String? recoveryNotice;
  File get current => File('${directory.path}/tasks.json');
  File get previous => File('${directory.path}/tasks.previous.json');
  Directory get backupDirectory => Directory('${directory.path}/backups');

  Future<String> readBounded(File file) async {
    if (await file.length() > BackupCodec.maxBytes)
      throw const FormatException('文件超过 16 MB');
    return file.readAsString();
  }

  Future<OrbitDocument> load() async {
    await directory.create(recursive: true);
    Object? primaryError;
    if (await current.exists()) {
      try {
        return BackupCodec.decode(await readBounded(current));
      } catch (error) {
        primaryError = error;
      }
    }
    if (await previous.exists()) {
      try {
        final document = BackupCodec.decode(await readBounded(previous));
        if (await current.exists()) {
          await current.copy(
            '${directory.path}/damaged-${DateTime.now().microsecondsSinceEpoch}.json',
          );
          await current.delete();
        }
        // Keep the known-good recovery file until a new durable write succeeds.
        await current.writeAsString(BackupCodec.encode(document), flush: true);
        recoveryNotice = '检测到保存中断，已恢复上一次完整数据。';
        return document;
      } catch (_) {
        throw StateError('本地数据及恢复副本均无法读取。原文件已保留，请从备份恢复。');
      }
    }
    if (primaryError != null) throw StateError('无法读取本地数据，原文件已保留：$primaryError');
    return OrbitDocument();
  }

  Future<void> save(OrbitDocument document) async {
    await directory.create(recursive: true);
    final source = BackupCodec.encode(document);
    BackupCodec.decode(source);
    final pending = File('${directory.path}/tasks.pending.json');
    await pending.writeAsString(source, flush: true);
    if (await current.exists()) {
      if (await previous.exists()) await previous.delete();
      await current.rename(previous.path);
    }
    try {
      await pending.rename(current.path);
    } catch (_) {
      if (!await current.exists() && await previous.exists())
        await previous.copy(current.path);
      rethrow;
    }
  }

  Future<File> backup(OrbitDocument document) async {
    await backupDirectory.create(recursive: true);
    final file = File(
      '${backupDirectory.path}/before-restore-${DateTime.now().microsecondsSinceEpoch}.orbit',
    );
    await file.writeAsString(BackupCodec.encode(document), flush: true);
    BackupCodec.decode(await readBounded(file));
    return file;
  }

  Future<File> restore(OrbitDocument incoming, OrbitDocument existing) async {
    final file = await backup(
      existing,
    ); // Failure must leave current data untouched.
    await save(incoming);
    return file;
  }

  Future<List<File>> backups() async {
    if (!await backupDirectory.exists()) return [];
    final files = await backupDirectory
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.orbit'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}
