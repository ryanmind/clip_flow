import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_flow/core/constants/clip_constants.dart';
import 'package:clip_flow/core/models/clip_item.dart';
import 'package:clip_flow/core/services/observability/index.dart';
import 'package:clip_flow/core/services/storage/index.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// SQL 输入验证器
///
/// 防止 SQL 注入和输入攻击
class SqlInputValidator {
  /// 最大搜索查询长度
  static const int maxSearchLength = 100;

  /// 危险的 SQL 字符模式
  static const List<String> dangerousPatterns = [
    ';--',
    '/*',
    '*/',
    'xp_',
    'exec(',
    'execute(',
    'script:',
    'javascript:',
    'union.*select',
    'drop.*table',
    'delete.*from',
    'insert.*into',
    'update.*set',
    "'or'1'='1",
    "' or 1=1",
    '--',
    '/*',
    '*/',
  ];

  /// 验证并清理搜索查询
  ///
  /// 返回清理后的查询，如果输入不安全则抛出异常
  static String sanitizeSearchQuery(String query) {
    // 检查长度
    if (query.length > maxSearchLength) {
      throw ArgumentError(
        '搜索查询过长: ${query.length} 字符（最大 $maxSearchLength）',
      );
    }

    // 检查危险模式
    final lowerQuery = query.toLowerCase();
    for (final pattern in dangerousPatterns) {
      if (lowerQuery.contains(RegExp(pattern, caseSensitive: false))) {
        throw ArgumentError(
          '搜索查询包含不安全字符: $pattern',
        );
      }
    }

    // 移除控制字符
    final sanitized = query.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();

    if (sanitized.isEmpty) {
      throw ArgumentError('搜索查询不能为空或仅包含空白字符');
    }

    return sanitized;
  }
}

/// 数据库服务类
///
/// 提供对数据库的增删改查操作
class DatabaseService {
  /// 工厂构造：返回数据库服务单例
  factory DatabaseService() => _instance;

  /// 私有构造：单例内部初始化
  DatabaseService._internal();

  /// 单例实例
  static final DatabaseService _instance = DatabaseService._internal();

  /// 获取数据库服务单例
  static DatabaseService get instance => _instance;

  /// 底层数据库连接
  Database? _database;

  /// 是否已完成初始化
  bool _isInitialized = false;

  /// 初始化进行中的 Future（用于防止并发初始化）
  Completer<void>? _initializationCompleter;

  /// 初始化数据库
  ///
  /// - 计算数据库路径并打开/创建数据库
  /// - 设置版本及 onCreate/onUpgrade 回调
  /// - 使用 Completer 确保并发调用时只初始化一次
  Future<void> initialize() async {
    // 如果已经初始化完成，直接返回
    if (_isInitialized) return;

    // 如果正在初始化，等待初始化完成
    if (_initializationCompleter != null) {
      return _initializationCompleter!.future;
    }

    // 创建新的 Completer 来跟踪初始化过程
    _initializationCompleter = Completer<void>();

    try {
      final path = await PathService.instance.getDatabasePath(
        ClipConstants.databaseName,
      );

      await Log.d(
        'Initializing database',
        tag: 'DatabaseService',
        fields: {'path': path},
      );

      _database = await openDatabase(
        path,
        version: ClipConstants.databaseVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );

      // 在线迁移：确保历史库补齐新列（不清库、不中断）
      await _ensureColumnsExist(_database!);

      _isInitialized = true;

      await Log.d(
        'Database initialized successfully',
        tag: 'DatabaseService',
      );

      // 完成初始化
      _initializationCompleter!.complete();
    } on Exception catch (e) {
      await Log.e(
        'Database initialization failed',
        tag: 'DatabaseService',
        error: e,
      );
      // 初始化失败，清除 completer 以便重试
      _initializationCompleter!.completeError(e);
      _initializationCompleter = null;
      _isInitialized = false;
      rethrow;
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE ${ClipConstants.clipItemsTable} (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        content TEXT,
        file_path TEXT,
        thumbnail BLOB,
        metadata TEXT NOT NULL DEFAULT '{}',
        ocr_text TEXT,
        ocr_text_id TEXT,
        is_ocr_extracted INTEGER NOT NULL DEFAULT 0,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        schema_version INTEGER NOT NULL DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_clip_items_created_at ON ${ClipConstants.clipItemsTable}(created_at)
    ''');

    await db.execute('''
      CREATE INDEX idx_clip_items_is_favorite ON ${ClipConstants.clipItemsTable}(is_favorite)
    ''');

    await db.execute('''
      CREATE INDEX idx_clip_items_type ON ${ClipConstants.clipItemsTable}(type)
    ''');

    // OCR相关索引
    await db.execute('''
      CREATE INDEX idx_clip_items_ocr_text_id ON ${ClipConstants.clipItemsTable}(ocr_text_id)
    ''');

    await db.execute('''
      CREATE INDEX idx_clip_items_is_ocr_extracted ON ${ClipConstants.clipItemsTable}(is_ocr_extracted)
    ''');

    // 复合索引：优化清理操作（收藏状态 + 创建时间）
    await db.execute('''
      CREATE INDEX idx_clip_items_favorite_created ON ${ClipConstants.clipItemsTable}(is_favorite, created_at)
    ''');

    // 复合索引：优化类型+时间查询
    await db.execute('''
      CREATE INDEX idx_clip_items_type_created ON ${ClipConstants.clipItemsTable}(type, created_at DESC)
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    await Log.i(
      'Database upgrade started',
      tag: 'DatabaseService',
      fields: {
        'oldVersion': oldVersion,
        'newVersion': newVersion,
      },
    );

    // 处理数据库升级（版本迁移），并兜底在线检查列
    await _ensureColumnsExist(db);

    // 创建OCR相关索引（如果不存在）
    await _ensureIndexExists(
      db,
      'idx_clip_items_ocr_text_id',
      ClipConstants.clipItemsTable,
      'ocr_text_id',
    );

    // 版本2：清理废弃字段
    if (newVersion >= 2) {
      await _cleanupDeprecatedColumns(db);
    }

    await Log.i(
      'Database upgrade completed',
      tag: 'DatabaseService',
      fields: {
        'oldVersion': oldVersion,
        'newVersion': newVersion,
      },
    );
    await _ensureIndexExists(
      db,
      'idx_clip_items_is_ocr_extracted',
      ClipConstants.clipItemsTable,
      'is_ocr_extracted',
    );

    // 创建复合索引（如果不存在）
    try {
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_clip_items_favorite_created
        ON ${ClipConstants.clipItemsTable}(is_favorite, created_at)
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_clip_items_type_created
        ON ${ClipConstants.clipItemsTable}(type, created_at DESC)
      ''');
    } on Exception catch (e) {
      await Log.d(
        'Composite indexes already exist or creation failed: $e',
        tag: 'DatabaseService',
      );
    }
  }

  /// 新增或替换一条剪贴项记录
  ///
  /// 参数：
  /// - item：要插入的剪贴项（若主键重复则替换）
  Future<void> insertClipItem(ClipItem item) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    await Log.i(
      'Inserting or replacing clip item with OCR data',
      tag: 'DatabaseService',
      fields: {
        'id': item.id,
        'type': item.type.name,
        'hasOcrText': item.ocrText != null && item.ocrText!.isNotEmpty,
      },
    );

    await _database!.insert(
      ClipConstants.clipItemsTable,
      {
        'id': item.id,
        'type': item.type.name,
        'content': item.content is String
            ? item.content
            : (item.content?.toString() ?? ''),
        'file_path': item.filePath,
        'thumbnail': item.thumbnail, // 使用 item.thumbnail 保持一致性
        'metadata': jsonEncode(item.metadata),
        'ocr_text': item.ocrText,
        'ocr_text_id': item.ocrTextId,
        'is_ocr_extracted': item.isOcrExtracted ? 1 : 0,
        'is_favorite': item.isFavorite ? 1 : 0,
        'created_at': item.createdAt.toIso8601String(),
        'updated_at': item.updatedAt.toIso8601String(),
        'schema_version': 1,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await Log.d(
      'Clip item inserted/replaced successfully',
      tag: 'DatabaseService',
      fields: {
        'id': item.id,
        'type': item.type.name,
      },
    );
  }

  /// 批量插入剪贴项记录
  ///
  /// 参数：
  /// - items：要插入的剪贴项列表
  /// - useTransaction：是否使用事务（默认true）
  Future<void> batchInsertClipItems(
    List<ClipItem> items, {
    bool useTransaction = true,
  }) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');
    if (items.isEmpty) return;

    final stopwatch = Stopwatch()..start();

    await Log.i(
      'Starting batch insert',
      tag: 'DatabaseService',
      fields: {
        'count': items.length,
        'useTransaction': useTransaction,
      },
    );

    try {
      if (useTransaction) {
        await _database!.transaction((txn) async {
          final batch = txn.batch();

          for (final item in items) {
            batch.insert(
              ClipConstants.clipItemsTable,
              {
                'id': item.id,
                'type': item.type.name,
                'content': item.content is String
                    ? item.content
                    : (item.content?.toString() ?? ''),
                'file_path': item.filePath,
                'thumbnail': null, // 所有类型都不存储 thumbnail，只使用 file_path
                'metadata': jsonEncode(item.metadata),
                'ocr_text': item.ocrText,
                'is_favorite': item.isFavorite ? 1 : 0,
                'created_at': item.createdAt.toIso8601String(),
                'updated_at': item.updatedAt.toIso8601String(),
                'schema_version': 1,
              },
              conflictAlgorithm: ConflictAlgorithm.ignore, // 改为 ignore
            );
          }

          await batch.commit(noResult: true);
        });
      } else {
        // 不使用事务，单独插入（仍然利用 ignore 策略）
        for (final item in items) {
          await _database!.insert(
            ClipConstants.clipItemsTable,
            {
              'id': item.id,
              'type': item.type.name,
              'content': item.content is String
                  ? item.content
                  : (item.content?.toString() ?? ''),
              'file_path': item.filePath,
              'thumbnail': null, // 所有类型都不存储 thumbnail，只使用 file_path
              'metadata': jsonEncode(item.metadata),
              'ocr_text': item.ocrText,
              'is_favorite': item.isFavorite ? 1 : 0,
              'created_at': item.createdAt.toIso8601String(),
              'updated_at': item.updatedAt.toIso8601String(),
              'schema_version': 1,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }

      stopwatch.stop();

      await Log.i(
        'Batch insert completed successfully',
        tag: 'DatabaseService',
        fields: {
          'attemptedCount': items.length,
          'duration': stopwatch.elapsedMilliseconds,
          'useTransaction': useTransaction,
        },
      );
    } on Exception catch (e) {
      stopwatch.stop();

      await Log.e(
        'Batch insert failed',
        tag: 'DatabaseService',
        error: e,
        fields: {
          'count': items.length,
          'duration': stopwatch.elapsedMilliseconds,
          'useTransaction': useTransaction,
        },
      );

      rethrow;
    }
  }

  /// 更新一条剪贴项记录
  ///
  /// 参数：
  /// - item：包含最新数据的剪贴项（依据 id 定位）
  Future<void> updateClipItem(ClipItem item) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    await _database!.update(
      ClipConstants.clipItemsTable,
      {
        'type': item.type.name,
        'content': item.content is String
            ? item.content
            : (item.content?.toString() ?? ''),
        'file_path': item.filePath,
        'thumbnail': item.thumbnail,
        'metadata': jsonEncode(item.metadata),
        'ocr_text': item.ocrText,
        'is_favorite': item.isFavorite ? 1 : 0,
        'updated_at': item.updatedAt.toIso8601String(),
        'schema_version': 1,
      },
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  /// 更新剪贴板项目的收藏状态
  ///
  /// 参数：
  /// - id：剪贴项主键
  /// - isFavorite：收藏状态
  Future<void> updateFavoriteStatus({
    required String id,
    required bool isFavorite,
  }) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    await _database!.update(
      ClipConstants.clipItemsTable,
      {
        'is_favorite': isFavorite ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
        'schema_version': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除指定 id 的剪贴项
  ///
  /// 参数：
  /// - id：剪贴项主键
  Future<void> deleteClipItem(String id) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    // 先查询 file_path 用于删除磁盘文件
    final item = await getClipItemById(id);
    await _database!.delete(
      ClipConstants.clipItemsTable,
      where: 'id = ?',
      whereArgs: [id],
    );

    // 尝试删除媒体文件
    if (item?.filePath != null && item!.filePath!.isNotEmpty) {
      await _deleteMediaFileSafe(item.filePath!);
    }
  }

  /// 清空所有剪贴项（保留收藏的项目）
  Future<void> clearAllClipItemsExceptFavorites() async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    // 只删除非收藏的项目
    await _database!.delete(
      ClipConstants.clipItemsTable,
      where: 'is_favorite = ?',
      whereArgs: [0],
    );

    // 清理媒体文件（只删除非收藏项目的文件）
    await _cleanupMediaFilesExceptFavorites();
  }

  /// 清空所有剪贴项（包括收藏的项目）
  Future<void> clearAllClipItems() async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    // 清空数据库
    await _database!.delete(ClipConstants.clipItemsTable);

    // 直接删除整个媒体目录（更高效）
    await _deleteMediaDirectorySafe();
  }

  /// 清理超出最大历史记录数的旧项目
  ///
  /// 保留所有收藏项和最新的 [maxItems] 条非收藏项。
  /// 超出限制的旧项目将被删除（包括数据库记录和关联的媒体文件）。
  ///
  /// 参数：
  /// - maxItems：最大保留的历史记录数（不包括收藏项）
  Future<void> cleanupExcessItems(int maxItems) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    await Log.i(
      'Starting cleanup of excess items',
      tag: 'DatabaseService',
      fields: {'maxItems': maxItems},
    );

    try {
      // 1. 获取当前总记录数
      final totalCount = await getClipItemsCount();
      final favoriteCount = await getFavoriteClipItemsCount();
      final nonFavoriteCount = totalCount - favoriteCount;

      await Log.d(
        'Current database stats',
        tag: 'DatabaseService',
        fields: {
          'totalCount': totalCount,
          'favoriteCount': favoriteCount,
          'nonFavoriteCount': nonFavoriteCount,
          'maxItems': maxItems,
        },
      );

      // 2. 如果非收藏项数量未超过限制，无需清理
      if (nonFavoriteCount <= maxItems) {
        await Log.d(
          'No cleanup needed - within limit',
          tag: 'DatabaseService',
        );
        return;
      }

      // 3. 计算需要删除的数量
      final excessCount = nonFavoriteCount - maxItems;

      // 4. 查询需要删除的旧项目（非收藏项，按创建时间升序，取最旧的 excessCount 条）
      final itemsToDelete = await _database!.query(
        ClipConstants.clipItemsTable,
        columns: ['id', 'file_path'],
        where: 'is_favorite = ?',
        whereArgs: [0],
        orderBy: 'created_at ASC',
        limit: excessCount,
      );

      if (itemsToDelete.isEmpty) {
        await Log.d(
          'No items to delete',
          tag: 'DatabaseService',
        );
        return;
      }

      await Log.i(
        'Deleting excess items',
        tag: 'DatabaseService',
        fields: {'count': itemsToDelete.length},
      );

      // 5. 批量删除数据库记录
      final idsToDelete = itemsToDelete
          .map((row) => row['id'] as String?)
          .whereType<String>()
          .toList();

      await _database!.delete(
        ClipConstants.clipItemsTable,
        where: 'id IN (${List.filled(idsToDelete.length, '?').join(',')})',
        whereArgs: idsToDelete,
      );

      // 6. 删除关联的媒体文件
      for (final row in itemsToDelete) {
        final filePath = row['file_path'] as String?;
        if (filePath != null && filePath.isNotEmpty) {
          await _deleteMediaFileSafe(filePath);
        }
      }

      await Log.i(
        'Cleanup completed successfully',
        tag: 'DatabaseService',
        fields: {
          'deletedCount': itemsToDelete.length,
          'remainingNonFavorites': maxItems,
        },
      );
    } on Exception catch (e) {
      await Log.e(
        'Failed to cleanup excess items',
        tag: 'DatabaseService',
        error: e,
      );
      // 不重新抛出异常，避免影响主流程
    }
  }

  /// 获取所有剪贴项（按创建时间倒序）
  ///
  /// 参数：
  /// - limit：返回数量上限
  /// - offset：偏移量（用于分页）
  ///
  /// 返回：剪贴项列表
  Future<List<ClipItem>> getAllClipItems({int? limit, int? offset}) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final List<Map<String, dynamic>> maps = await _database!.query(
      ClipConstants.clipItemsTable,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    return maps.map(_mapToClipItem).toList();
  }

  /// 按类型获取剪贴项（倒序）
  ///
  /// 参数：
  /// - type：剪贴类型
  /// - limit/offset：分页参数
  ///
  /// 返回：剪贴项列表
  Future<List<ClipItem>> getClipItemsByType(
    ClipType type, {
    int? limit,
    int? offset,
  }) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final List<Map<String, dynamic>> maps = await _database!.query(
      ClipConstants.clipItemsTable,
      where: 'type = ?',
      whereArgs: [type.name],
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    return maps.map(_mapToClipItem).toList();
  }

  /// 获取收藏的剪贴项（倒序）
  ///
  /// 参数：
  /// - limit/offset：分页参数
  ///
  /// 返回：剪贴项列表
  Future<List<ClipItem>> getFavoriteClipItems({int? limit, int? offset}) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final List<Map<String, dynamic>> maps = await _database!.query(
      ClipConstants.clipItemsTable,
      where: 'is_favorite = ?',
      whereArgs: [1],
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    return maps.map(_mapToClipItem).toList();
  }

  /// 搜索剪贴项（在 content、metadata 和 OCR 文本中模糊匹配）
  ///
  /// 参数：
  /// - query：关键字
  /// - limit/offset：分页参数
  ///
  /// 返回：匹配的剪贴项列表
  Future<List<ClipItem>> searchClipItems(
    String query, {
    int? limit,
    int? offset,
  }) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    // 验证并清理搜索查询，防止 SQL 注入
    final sanitizedQuery = SqlInputValidator.sanitizeSearchQuery(query);

    await Log.i(
      'Searching clip items with OCR text support',
      tag: 'DatabaseService',
      fields: {
        'query': sanitizedQuery,
        'limit': limit,
        'offset': offset,
      },
    );

    // 搜索内容、元数据和OCR文本
    final List<Map<String, dynamic>> maps = await _database!.query(
      ClipConstants.clipItemsTable,
      where: '''
        content LIKE ? OR
        metadata LIKE ? OR
        ocr_text LIKE ?
      ''',
      whereArgs: [
        '%$sanitizedQuery%',
        '%$sanitizedQuery%',
        '%$sanitizedQuery%',
      ],
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    final results = maps.map(_mapToClipItem).toList();

    await Log.i(
      'Search completed with OCR text support',
      tag: 'DatabaseService',
      fields: {
        'query': query,
        'resultCount': results.length,
        'hasOcrMatches': results.any(
          (item) =>
              item.ocrText?.toLowerCase().contains(query.toLowerCase()) ??
              false,
        ),
      },
    );

    return results;
  }

  /// 搜索指定类型的剪贴项（支持OCR文本搜索）
  ///
  /// 参数：
  /// - query：搜索关键字
  /// - type：剪贴项类型（可选）
  /// - limit/offset：分页参数
  ///
  /// 返回：匹配的剪贴项列表
  Future<List<ClipItem>> searchClipItemsByType(
    String query, {
    ClipType? type,
    int? limit,
    int? offset,
  }) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    // 验证并清理搜索查询，防止 SQL 注入
    final sanitizedQuery = SqlInputValidator.sanitizeSearchQuery(query);

    await Log.i(
      'Searching clip items by type with OCR text support',
      tag: 'DatabaseService',
      fields: {
        'query': sanitizedQuery,
        'type': type?.name,
        'limit': limit,
        'offset': offset,
      },
    );

    var whereClause = '''
      content LIKE ? OR
      metadata LIKE ? OR
      ocr_text LIKE ?
    ''';
    final whereArgs = [
      '%$sanitizedQuery%',
      '%$sanitizedQuery%',
      '%$sanitizedQuery%',
    ];

    // 如果指定了类型，添加类型过滤
    if (type != null) {
      whereClause = '($whereClause) AND type = ?';
      whereArgs.add(type.name);
    }

    final List<Map<String, dynamic>> maps = await _database!.query(
      ClipConstants.clipItemsTable,
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );

    final results = maps.map(_mapToClipItem).toList();

    await Log.i(
      'Type-specific search completed with OCR text support',
      tag: 'DatabaseService',
      fields: {
        'query': sanitizedQuery,
        'type': type?.name,
        'resultCount': results.length,
        'hasOcrMatches': results.any(
          (item) =>
              item.ocrText?.toLowerCase().contains(
                sanitizedQuery.toLowerCase(),
              ) ??
              false,
        ),
      },
    );

    return results;
  }

  /// 通过 id 获取剪贴项
  ///
  /// 参数：
  /// - id：剪贴项主键
  ///
  /// 返回：存在则为 ClipItem，否则为 null
  Future<ClipItem?> getClipItemById(String id) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final List<Map<String, dynamic>> maps = await _database!.query(
      ClipConstants.clipItemsTable,
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return _mapToClipItem(maps.first);
  }

  /// 切换指定剪贴项的收藏状态
  ///
  /// 参数：
  /// - id：剪贴项主键
  Future<void> toggleFavorite(String id) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final item = await getClipItemById(id);
    if (item != null) {
      await updateClipItem(item.copyWith(isFavorite: !item.isFavorite));
    }
  }

  /// 获取所有剪贴项数量
  ///
  /// 返回：计数
  Future<int> getClipItemsCount() async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final result = await _database!.rawQuery(
      'SELECT COUNT(*) as count FROM ${ClipConstants.clipItemsTable}',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// 获取指定类型的剪贴项数量
  ///
  /// 参数：
  /// - type：剪贴类型
  ///
  /// 返回：计数
  Future<int> getClipItemsCountByType(ClipType type) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final result = await _database!.rawQuery(
      'SELECT COUNT(*) as count FROM ${ClipConstants.clipItemsTable} '
      'WHERE type = ?',
      [type.name],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// 获取收藏的剪贴项数量
  ///
  /// 返回：计数
  Future<int> getFavoriteClipItemsCount() async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final result = await _database!.rawQuery(
      'SELECT COUNT(*) as count FROM ${ClipConstants.clipItemsTable} '
      'WHERE is_favorite = 1',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// 删除早于指定天数的历史剪贴项
  ///
  /// 参数：
  /// - maxAgeInDays：最大保留天数
  Future<void> deleteOldClipItems(int maxAgeInDays) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final cutoffDate = DateTime.now().subtract(Duration(days: maxAgeInDays));

    // 先找出要删的 id 与 file_path
    final stale = await _database!.query(
      ClipConstants.clipItemsTable,
      columns: ['id', 'file_path'],
      where: 'created_at < ?',
      whereArgs: [cutoffDate.toIso8601String()],
    );

    await _database!.delete(
      ClipConstants.clipItemsTable,
      where: 'created_at < ?',
      whereArgs: [cutoffDate.toIso8601String()],
    );

    for (final row in stale) {
      final path = row['file_path'] as String?;
      if (path != null && path.isNotEmpty) {
        await _deleteMediaFileSafe(path);
      }
    }
  }

  /// 删除指定类型的剪贴项
  ///
  /// 参数：
  /// - type：剪贴类型
  Future<void> deleteClipItemsByType(ClipType type) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    // 取出将被删除的 file_path
    final rows = await _database!.query(
      ClipConstants.clipItemsTable,
      columns: ['file_path'],
      where: 'type = ?',
      whereArgs: [type.name],
    );

    await _database!.delete(
      ClipConstants.clipItemsTable,
      where: 'type = ?',
      whereArgs: [type.name],
    );

    for (final r in rows) {
      final p = r['file_path'] as String?;
      if (p != null && p.isNotEmpty) {
        await _deleteMediaFileSafe(p);
      }
    }
  }

  ClipItem _mapToClipItem(Map<String, dynamic> map) {
    final id = map['id'] as String?;
    final typeName = map['type'] as String?;
    final contentRaw = map['content'];
    final filePathRaw = map['file_path'];
    final thumbRaw = map['thumbnail'];
    final metadataRaw = map['metadata'];
    final ocrTextRaw = map['ocr_text'];
    final ocrTextIdRaw = map['ocr_text_id'];
    final isOcrExtractedRaw = map['is_ocr_extracted'];
    final isFavRaw = map['is_favorite'];
    final createdAtRaw = map['created_at'];
    final updatedAtRaw = map['updated_at'];

    Map<String, dynamic> metadata;
    if (metadataRaw is String) {
      final decoded = jsonDecode(metadataRaw);
      metadata = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } else if (metadataRaw is Map<String, dynamic>) {
      metadata = metadataRaw;
    } else if (metadataRaw is Map) {
      metadata = Map<String, dynamic>.from(metadataRaw);
    } else {
      metadata = <String, dynamic>{};
    }

    return ClipItem(
      id: id,
      type: ClipType.values.firstWhere(
        (e) => e.name == typeName,
        orElse: () => ClipType.text,
      ),
      content: contentRaw is String
          ? contentRaw
          : (contentRaw?.toString() ?? ''),
      filePath: filePathRaw is String ? filePathRaw : null,
      thumbnail: thumbRaw is List<int>
          ? Uint8List.fromList(thumbRaw)
          : (thumbRaw is Uint8List
                ? thumbRaw
                : (thumbRaw is List
                      ? Uint8List.fromList(List<int>.from(thumbRaw))
                      : null)),
      metadata: metadata,
      ocrText: ocrTextRaw is String ? ocrTextRaw : null,
      ocrTextId: ocrTextIdRaw is String ? ocrTextIdRaw : null,
      isOcrExtracted: isOcrExtractedRaw == 1 || isOcrExtractedRaw == true,
      isFavorite: isFavRaw == 1 || isFavRaw == true,
      createdAt: createdAtRaw is String
          ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
          : (createdAtRaw is DateTime ? createdAtRaw : DateTime.now()),
      updatedAt: updatedAtRaw is String
          ? DateTime.tryParse(updatedAtRaw) ?? DateTime.now()
          : (updatedAtRaw is DateTime ? updatedAtRaw : DateTime.now()),
    );
  }

  /// 安全删除指定的媒体文件
  ///
  /// 参数：
  /// - relativePath：相对路径，如 'media/image.jpg'
  Future<void> _deleteMediaFileSafe(String relativePath) async {
    try {
      final absPath = await _resolveAbsoluteMediaPath(relativePath);
      final file = File(absPath);
      if (file.existsSync()) {
        await file.delete();
        await Log.d(
          'Successfully deleted media file: $absPath',
          tag: 'DatabaseService',
        );
      } else {
        await Log.w(
          'Attempted to delete non-existent media file: $absPath',
          tag: 'DatabaseService',
        );
      }
    } on FileSystemException catch (e) {
      await Log.e(
        'Failed to delete media file due to FileSystemException: $relativePath',
        tag: 'DatabaseService',
        error: e,
        fields: {'path': relativePath},
      );
    } on Exception catch (e) {
      await Log.e(
        'Failed to delete media file due to unexpected error: $relativePath',
        tag: 'DatabaseService',
        error: e,
        fields: {'path': relativePath},
      );
    }
  }

  /// 解析相对媒体路径为绝对路径
  ///
  /// 参数：
  /// - relativePath：相对路径，如 'media/image.jpg'
  Future<String> _resolveAbsoluteMediaPath(String relativePath) async {
    final supportDirectory = await PathService.instance
        .getApplicationSupportDirectory();
    return join(supportDirectory.path, relativePath);
  }

  /// 安全删除整个媒体目录
  Future<void> _deleteMediaDirectorySafe() async {
    try {
      final supportDirectory = await PathService.instance
          .getApplicationSupportDirectory();
      final mediaDirectory = Directory(join(supportDirectory.path, 'media'));
      if (mediaDirectory.existsSync()) {
        await mediaDirectory.delete(recursive: true);
      }
    } on FileSystemException catch (_) {
      // 忽略文件系统异常，避免阻塞清空操作
    }
  }

  /// 清理媒体文件（只删除非收藏项目的文件）
  Future<void> _cleanupMediaFilesExceptFavorites() async {
    try {
      // 获取所有非收藏项目的文件路径
      final List<Map<String, dynamic>>
      nonFavoriteItems = await _database!.query(
        ClipConstants.clipItemsTable,
        columns: ['file_path', 'thumbnail'],
        where:
            'is_favorite = ? AND (file_path IS NOT NULL OR thumbnail IS NOT NULL)',
        whereArgs: [0],
      );

      final supportDirectory = await PathService.instance
          .getApplicationSupportDirectory();
      final mediaDirectory = Directory(join(supportDirectory.path, 'media'));

      if (mediaDirectory.existsSync()) {
        // 删除非收藏项目的文件
        for (final item in nonFavoriteItems) {
          final filePath = item['file_path'] as String?;

          // 删除主文件
          if (filePath != null && filePath.isNotEmpty) {
            await _deleteMediaFileSafe(filePath);
          }

          // 注意：缩略图存储为二进制数据在数据库中，不需要单独删除文件
        }
      }
    } on FileSystemException catch (_) {
      // 忽略文件系统异常，避免阻塞操作
    } on Exception catch (e) {
      // 记录其他异常但不抛出
      await Log.w(
        'Error cleaning media files except favorites',
        tag: 'DatabaseService',
        error: e,
      );
    }
  }

  /// 扫描媒体目录，删除未在 DB 引用的"孤儿文件"
  /// retainDays: 保留最近 N 天内的文件，避免误删
  Future<int> cleanOrphanMediaFiles({int retainDays = 3}) async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final supportDirectory = await PathService.instance.getDocumentsDirectory();
    final mediaRoot = Directory(join(supportDirectory.path, 'media'));
    if (!mediaRoot.existsSync()) return 0;

    // 读取数据库中所有 file_path 引用
    final rows = await _database!.query(
      ClipConstants.clipItemsTable,
      columns: ['file_path'],
      where: 'file_path IS NOT NULL AND file_path != ""',
    );
    final referenced = rows
        .map((r) => r['file_path'] as String?)
        .where((p) => p != null && p.isNotEmpty)
        .map((p) => join(supportDirectory.path, p))
        .toSet();

    final cutoff = DateTime.now().subtract(Duration(days: retainDays));
    var deleted = 0;

    await for (final entity in mediaRoot.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final path = entity.path;

      if (path.endsWith('.tmp')) continue;

      final stat = entity.statSync();
      if (stat.modified.isAfter(cutoff)) continue;

      if (!referenced.contains(path)) {
        try {
          await entity.delete();
          deleted++;
        } on FileSystemException catch (_) {}
      }
    }
    return deleted;
  }

  /// 关闭数据库连接并重置初始化状态
  Future<void> close() async {
    await _database?.close();
    _isInitialized = false;
  }

  // === 在线迁移辅助：确保缺失列被补齐（安全、幂等） ===
  Future<void> _ensureColumnsExist(Database db) async {
    // clip_items: file_path TEXT
    final hasFilePath = await _columnExists(
      db,
      ClipConstants.clipItemsTable,
      'file_path',
    );
    if (!hasFilePath) {
      await db.execute(
        'ALTER TABLE ${ClipConstants.clipItemsTable} ADD COLUMN file_path TEXT',
      );
    }

    // clip_items: thumbnail BLOB
    final hasThumbnail = await _columnExists(
      db,
      ClipConstants.clipItemsTable,
      'thumbnail',
    );
    if (!hasThumbnail) {
      await db.execute(
        'ALTER TABLE ${ClipConstants.clipItemsTable} ADD COLUMN thumbnail BLOB',
      );
    }

    // clip_items: schema_version INTEGER NOT NULL DEFAULT 1
    final hasSchemaVersion = await _columnExists(
      db,
      ClipConstants.clipItemsTable,
      'schema_version',
    );
    if (!hasSchemaVersion) {
      await db.execute(
        'ALTER TABLE ${ClipConstants.clipItemsTable} '
        'ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1',
      );
    }

    // clip_items: ocr_text TEXT
    final hasOcrText = await _columnExists(
      db,
      ClipConstants.clipItemsTable,
      'ocr_text',
    );
    if (!hasOcrText) {
      await db.execute(
        'ALTER TABLE ${ClipConstants.clipItemsTable} ADD COLUMN ocr_text TEXT',
      );
    }

    // clip_items: ocr_text_id TEXT (OCR文本的独立ID)
    final hasOcrTextId = await _columnExists(
      db,
      ClipConstants.clipItemsTable,
      'ocr_text_id',
    );
    if (!hasOcrTextId) {
      await db.execute(
        'ALTER TABLE ${ClipConstants.clipItemsTable} ADD COLUMN ocr_text_id TEXT',
      );
    }

    // clip_items: is_ocr_extracted INTEGER NOT NULL DEFAULT 0 (是否已提取OCR)
    final hasIsOcrExtracted = await _columnExists(
      db,
      ClipConstants.clipItemsTable,
      'is_ocr_extracted',
    );
    if (!hasIsOcrExtracted) {
      await db.execute(
        'ALTER TABLE ${ClipConstants.clipItemsTable} '
        'ADD COLUMN is_ocr_extracted INTEGER NOT NULL DEFAULT 0',
      );
    }

    // 预留：如未来新增列，可在此继续检测并 ALTER
  }

  Future<bool> _columnExists(Database db, String table, String column) async {
    final rows = await db.rawQuery("PRAGMA table_info('$table')");
    for (final row in rows) {
      final name = row['name'];
      if (name == column) return true;
    }
    return false;
  }

  /// 检查索引是否存在，不存在则创建
  Future<void> _ensureIndexExists(
    Database db,
    String indexName,
    String table,
    String column,
  ) async {
    try {
      // 尝试创建索引，如果已存在会抛出异常
      await db.execute(
        'CREATE INDEX IF NOT EXISTS $indexName ON $table($column)',
      );
    } on Exception catch (e) {
      // 忽略索引已存在的错误
      await Log.d(
        'Index $indexName already exists or creation failed: $e',
        tag: 'DatabaseService',
      );
    }
  }

  /// 清理空内容的文本类型数据
  ///
  /// 删除 type 为 'text' 但 content 为空或只包含空白字符的记录
  /// 返回删除的记录数量
  Future<int> cleanEmptyTextItems() async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final deletedCount = await _database!.delete(
      ClipConstants.clipItemsTable,
      where: "type = 'text' AND (content IS NULL OR TRIM(content) = '')",
    );

    await Log.i('Cleaned $deletedCount empty text items from database');
    return deletedCount;
  }

  /// 获取空内容的文本数据统计
  ///
  /// 返回 type 为 'text' 但 content 为空的记录数量
  Future<int> countEmptyTextItems() async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final result = await _database!.rawQuery(
      'SELECT COUNT(*) as count FROM ${ClipConstants.clipItemsTable} '
      "WHERE type = 'text' AND (content IS NULL OR TRIM(content) = '')",
    );

    return (result.first['count'] as int?) ?? 0;
  }

  /// 验证并修复数据完整性
  ///
  /// 执行多项数据完整性检查和修复：
  /// - 清理空内容的文本数据
  /// - 清理孤儿媒体文件
  /// - 清理重复记录（基于ID）
  /// 返回修复统计信息
  Future<Map<String, int>> validateAndRepairData() async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    final stats = <String, int>{};

    // 清理空文本内容
    stats['emptyTextItemsDeleted'] = await cleanEmptyTextItems();

    // 清理重复记录
    stats['duplicateItemsDeleted'] = await cleanDuplicateItems();

    // 清理孤儿媒体文件
    stats['orphanFilesDeleted'] = await cleanOrphanMediaFiles();

    // 统计当前数据
    final totalItems = await _database!.rawQuery(
      'SELECT COUNT(*) as count FROM ${ClipConstants.clipItemsTable}',
    );
    stats['totalItemsRemaining'] = (totalItems.first['count'] as int?) ?? 0;

    await Log.i('Database validation completed: $stats');
    return stats;
  }

  /// 清理重复记录（基于ID）
  ///
  /// 删除具有相同ID的重复记录，保留最新的一个
  /// 返回删除的记录数量
  Future<int> cleanDuplicateItems() async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    await Log.i('Starting to clean duplicate items', tag: 'DatabaseService');

    // 查找重复记录
    final duplicates = await _database!.rawQuery('''
      SELECT id, COUNT(*) as count
      FROM ${ClipConstants.clipItemsTable}
      GROUP BY id
      HAVING COUNT(*) > 1
    ''');

    if (duplicates.isEmpty) {
      await Log.d('No duplicate items found', tag: 'DatabaseService');
      return 0;
    }

    var totalDeleted = 0;

    for (final duplicate in duplicates) {
      final id = duplicate['id'] as String?;

      // 跳过 id 为 null 的记录
      if (id == null) {
        await Log.w(
          'Found duplicate item with null id, skipping',
          tag: 'DatabaseService',
        );
        continue;
      }

      // 删除重复记录，保留最新的一个（基于created_at）
      final deleted = await _database!.rawQuery(
        '''
        DELETE FROM ${ClipConstants.clipItemsTable}
        WHERE id = ? AND rowid NOT IN (
          SELECT rowid FROM ${ClipConstants.clipItemsTable}
          WHERE id = ?
          ORDER BY created_at DESC, rowid DESC
          LIMIT 1
        )
      ''',
        [id, id],
      );

      final deletedCount = Sqflite.firstIntValue(deleted) ?? 0;
      totalDeleted += deletedCount;

      await Log.d(
        'Cleaned duplicates for item',
        tag: 'DatabaseService',
        fields: {
          'id': id,
          'deletedCount': deletedCount,
        },
      );
    }

    await Log.i(
      'Cleaned duplicate items successfully',
      tag: 'DatabaseService',
      fields: {'totalDeleted': totalDeleted},
    );

    return totalDeleted;
  }

  /// 清理废弃的数据库字段
  Future<void> _cleanupDeprecatedColumns(Database db) async {
    try {
      await Log.i(
        'Starting cleanup of deprecated columns',
        tag: 'DatabaseService',
      );

      // 要清理的字段列表
      final deprecatedColumns = [
        'parent_image_id',
        'origin_width',
        'origin_height',
        'schema_version',
      ];

      final columnsToActuallyRemove = <String>[];
      for (final column in deprecatedColumns) {
        if (await _columnExists(db, ClipConstants.clipItemsTable, column)) {
          columnsToActuallyRemove.add(column);
        }
      }

      if (columnsToActuallyRemove.isNotEmpty) {
        await _recreateTableWithoutColumns(
          db,
          ClipConstants.clipItemsTable,
          columnsToActuallyRemove,
        );
        await Log.d(
          'Successfully cleaned up deprecated columns: ${columnsToActuallyRemove.join(', ')}',
          tag: 'DatabaseService',
        );
      } else {
        await Log.d(
          'No deprecated columns to clean up',
          tag: 'DatabaseService',
        );
      }

      await Log.i(
        'Deprecated columns cleanup completed',
        tag: 'DatabaseService',
      );
    } on Exception catch (e) {
      await Log.e(
        'Failed to cleanup deprecated columns',
        tag: 'DatabaseService',
        error: e,
      );
      // 不阻止数据库升级
    }
  }

  /// 重建表以移除指定的一组列
  Future<void> _recreateTableWithoutColumns(
    Database db,
    String tableName,
    List<String> columnsToRemove,
  ) async {
    final tempTableName = '${tableName}_temp';
    final columnsToRemoveSet = columnsToRemove.toSet();

    // 获取原表结构
    final tableInfo = await db.rawQuery("PRAGMA table_info('$tableName')");

    // 构建新表的CREATE语句的列定义
    final keptColumnDefs = <String>[];
    // 构建复制数据时要 SELECT 的列名
    final keptColumnNames = <String>[];

    for (final column in tableInfo) {
      final name = column['name']! as String;
      if (!columnsToRemoveSet.contains(name)) {
        final type = column['type']! as String;
        final notNull = (column['notnull']! as int) == 1 ? ' NOT NULL' : '';
        final defaultValue = column['dflt_value'] != null
            ? ' DEFAULT ${column['dflt_value']}'
            : '';
        keptColumnDefs.add('$name $type$notNull$defaultValue');
        keptColumnNames.add(name);
      }
    }

    if (keptColumnDefs.isEmpty) {
      // 避免创建空表
      await Log.w('No columns left after removing, skipping table recreation.');
      return;
    }

    // 1. 创建临时表
    final createTableSql =
        'CREATE TABLE $tempTableName (${keptColumnDefs.join(', ')})';
    await db.execute(createTableSql);

    // 2. 复制数据（仅复制保留的列）
    final selectColumns = keptColumnNames.join(', ');
    await db.execute(
      'INSERT INTO $tempTableName ($selectColumns) SELECT $selectColumns FROM $tableName',
    );

    // 3. 删除原表
    await db.execute('DROP TABLE $tableName');

    // 4. 重命名临时表
    await db.execute('ALTER TABLE $tempTableName RENAME TO $tableName');

    await Log.d(
      'Successfully recreated table $tableName without columns: ${columnsToRemove.join(', ')}',
      tag: 'DatabaseService',
    );
  }

  /// 修复数据库中的文件路径（简化版）
  ///
  /// 修复逻辑：
  /// 1. 绝对路径 → 相对路径转换
  /// 2. 路径格式规范化（确保以 media/ 开头）
  /// 3. 验证文件是否存在，不存在则删除记录
  ///
  /// 返回：修复报告
  Future<Map<String, dynamic>> repairFilePaths() async {
    if (!_isInitialized) await initialize();
    if (_database == null) throw Exception('Database not initialized');

    await Log.i(
      'Starting file path repair',
      tag: 'DatabaseService',
    );

    final report = <String, dynamic>{
      'totalChecked': 0,
      'fixed': 0,
      'deleted': 0,
      'unchanged': 0,
    };

    try {
      // 获取所有需要验证的记录（image、audio、video、file）
      final mediaTypes = [
        ClipType.image.name,
        ClipType.audio.name,
        ClipType.video.name,
        ClipType.file.name,
      ];

      final items = await _database!.query(
        ClipConstants.clipItemsTable,
        where: 'type IN (${mediaTypes.map((_) => '?').join(',')})',
        whereArgs: mediaTypes,
      );

      report['totalChecked'] = items.length;

      if (items.isEmpty) {
        await Log.i(
          'No media items to repair',
          tag: 'DatabaseService',
        );
        return report;
      }

      final supportDir = await PathService.instance
          .getApplicationSupportDirectory();
      final itemsToUpdate = <Map<String, dynamic>>[];
      final itemsToDelete = <String>[];

      for (final item in items) {
        final id = item['id']! as String;
        final type = item['type']! as String;
        final filePathRaw = item['file_path'] as String?;

        // file_path为空，直接删除
        if (filePathRaw == null || filePathRaw.isEmpty) {
          itemsToDelete.add(id);
          report['deleted'] = (report['deleted'] as int) + 1;
          continue;
        }

        // 修复路径格式：绝对路径转相对路径，规范化格式
        String? fixedPath = filePathRaw;

        // 如果是绝对路径，转换为相对路径
        if (filePathRaw.startsWith('/') ||
            RegExp('^[A-Za-z]:').hasMatch(filePathRaw)) {
          if (filePathRaw.startsWith(supportDir.path)) {
            fixedPath = filePathRaw.substring(supportDir.path.length + 1);
          } else {
            // 绝对路径但不在文档目录下，删除
            itemsToDelete.add(id);
            report['deleted'] = (report['deleted'] as int) + 1;
            continue;
          }
        }

        // 规范化路径：移除开头的 / 或 ./
        fixedPath = fixedPath.replaceFirst(RegExp(r'^\.?/'), '');

        // 确保以 media/ 开头
        if (!fixedPath.startsWith(ClipConstants.mediaDir)) {
          // 如果已经包含 images/ 或 files/，直接补 media/ 前缀
          if (fixedPath.startsWith('images/')) {
            fixedPath = '${ClipConstants.mediaDir}/$fixedPath';
          } else if (fixedPath.startsWith('files/')) {
            fixedPath = '${ClipConstants.mediaDir}/$fixedPath';
          } else {
            // 否则根据类型补全完整路径
            if (type == ClipType.image.name) {
              fixedPath = '${ClipConstants.mediaImagesDir}/$fixedPath';
            } else {
              fixedPath = '${ClipConstants.mediaFilesDir}/$fixedPath';
            }
          }
        }

        // 验证文件是否存在
        final absolutePath = join(supportDir.path, fixedPath);
        final file = File(absolutePath);
        if (file.existsSync()) {
          if (fixedPath != filePathRaw) {
            // 路径已修复，需要更新
            itemsToUpdate.add({
              'id': id,
              'file_path': fixedPath,
            });
            report['fixed'] = (report['fixed'] as int) + 1;
          } else {
            // 路径正确，无需修改
            report['unchanged'] = (report['unchanged'] as int) + 1;
          }
        } else {
          // 文件不存在，删除记录
          itemsToDelete.add(id);
          report['deleted'] = (report['deleted'] as int) + 1;
        }
      }

      // 批量更新数据库
      if (itemsToUpdate.isNotEmpty) {
        await _database!.transaction((txn) async {
          for (final item in itemsToUpdate) {
            await txn.update(
              ClipConstants.clipItemsTable,
              {'file_path': item['file_path']},
              where: 'id = ?',
              whereArgs: [item['id']],
            );
          }
        });

        await Log.i(
          'Updated file paths',
          tag: 'DatabaseService',
          fields: {'count': itemsToUpdate.length},
        );
      }

      // 批量删除无效记录
      if (itemsToDelete.isNotEmpty) {
        await _database!.delete(
          ClipConstants.clipItemsTable,
          where: 'id IN (${itemsToDelete.map((_) => '?').join(',')})',
          whereArgs: itemsToDelete,
        );

        await Log.i(
          'Deleted invalid records',
          tag: 'DatabaseService',
          fields: {'count': itemsToDelete.length},
        );
      }

      await Log.i(
        'File path repair completed',
        tag: 'DatabaseService',
        fields: report,
      );

      return report;
    } on Exception catch (e) {
      await Log.e(
        'File path repair failed',
        tag: 'DatabaseService',
        error: e,
      );
      rethrow;
    }
  }
}
