import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'task_model.dart';

class UnsupportedBackupVersion extends FormatException {
  const UnsupportedBackupVersion() : super('备份版本不支持，请使用较新版本的小事星球打开');
}

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
      final version = raw['version'];
      if (version is int && version > 1) {
        throw const UnsupportedBackupVersion();
      }
      if (version is! int || version != 1) {
        throw const FormatException('备份版本无效');
      }
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
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, BackupCodec.maxBytes + 1)) {
      bytes.add(chunk);
    }
    if (bytes.length > BackupCodec.maxBytes)
      throw const FormatException('文件超过 16 MB');
    // Decode separately so malformed UTF-8 is distinguishable from a genuine
    // filesystem/permission failure. Both must leave the original untouched.
    return utf8.decode(bytes.takeBytes());
  }

  Future<OrbitDocument> load() async {
    await directory.create(recursive: true);
    Object? primaryError;
    if (await current.exists()) {
      try {
        return BackupCodec.decode(await readBounded(current));
      } on UnsupportedBackupVersion {
        // A downgrade must never replace newer data with an older recovery copy.
        rethrow;
      } on FormatException catch (error) {
        // A filesystem failure is not evidence of corruption. Do not roll a
        // valid current database back merely because it was temporarily locked
        // or unreadable; leave both copies untouched and let the user retry.
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
      } on UnsupportedBackupVersion {
        rethrow;
      } on FormatException {
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

  /// Recovery when neither database copy can be loaded. Preserve the exact
  /// originals before replacing anything, including an interrupted pending file.
  Future<Directory> recover(OrbitDocument incoming) async {
    BackupCodec.decode(BackupCodec.encode(incoming));
    final originals = [
      current,
      previous,
      File('${directory.path}/tasks.pending.json'),
    ];
    for (final original in originals) {
      if (!await original.exists()) continue;
      try {
        BackupCodec.decode(await readBounded(original));
      } on UnsupportedBackupVersion {
        // Only a newer application should interpret or replace these files.
        rethrow;
      } on FormatException {
        // Broken bytes are precisely what this recovery route preserves.
      }
    }
    final archive = Directory(
      '${backupDirectory.path}/recovery-${DateTime.now().microsecondsSinceEpoch}',
    );
    await archive.create(recursive: true);
    for (final original in originals) {
      if (!await original.exists()) continue;
      final copy = await original.copy(
        '${archive.path}/${original.uri.pathSegments.last}',
      );
      final handle = await copy.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      final expected = await sha256.bind(original.openRead()).first;
      final actual = await sha256.bind(copy.openRead()).first;
      if (expected != actual) throw StateError('原文件备份校验失败，没有恢复数据');
    }
    await save(incoming);
    recoveryNotice = '已从备份恢复；原文件已保留在 ${archive.path}';
    return archive;
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
