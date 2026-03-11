import 'dart:async';
import 'dart:ui' as ui;

import 'package:clip_flow/core/models/clip_item.dart';
import 'package:clip_flow/core/models/user_preferences.dart';
import 'package:clip_flow/core/services/observability/logger/logger.dart';
import 'package:clip_flow/core/services/platform/index.dart';
import 'package:clip_flow/core/utils/clip_item_card_util.dart';
import 'package:clip_flow/features/classic/presentation/widgets/clip_item_card.dart';
import 'package:clip_flow/features/classic/presentation/widgets/search_bar.dart';
import 'package:clip_flow/l10n/gen/s.dart';
import 'package:clip_flow/shared/providers/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 紧凑模式页面
///
/// 提供紧凑的剪贴板历史浏览界面，支持：
/// - 全屏半透明背景
/// - 水平居中的卡片列表
/// - 键盘和鼠标导航
/// - 实时预览和切换
class CompactModePage extends ConsumerStatefulWidget {
  /// 构造器
  const CompactModePage({super.key});

  @override
  ConsumerState<CompactModePage> createState() => _CompactModePageState();
}

class _CompactModePageState extends ConsumerState<CompactModePage> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  int _selectedIndex = 0;
  List<ClipItem> _displayItems = [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadData());
    _scrollController.addListener(_handleScrollActivity);
    // 自动滚动到选中项
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToSelectedIndex();

      // 在页面初始化时检查并启动自动隐藏监控
      if (!mounted) return;
      final autoHideEnabled = ref.read(userPreferencesProvider).autoHideEnabled;
      if (autoHideEnabled) {
        ref.read(autoHideServiceProvider).startMonitoring();
        unawaited(
          Log.i(
            'CompactModePage initialized, auto-hide monitoring started',
            tag: 'CompactModePage',
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScrollActivity);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 处理用户交互，重置自动隐藏定时器
  void _onUserInteraction() {
    ref.read(autoHideServiceProvider).onUserInteraction();
  }

  void _handleScrollActivity() {
    if (!mounted) {
      return;
    }
    _onUserInteraction();
  }

  Future<void> _loadData() async {
    // 获取所有剪贴板历史数据
    final allItems = ref.read(clipboardHistoryProvider);
    setState(() {
      _displayItems = allItems.toList();
      _selectedIndex = _displayItems.isNotEmpty ? 0 : -1;
    });
  }

  void _filterItems(String query) {
    final allItems = ref.read(clipboardHistoryProvider);
    final filtered = query.isEmpty
        ? allItems.toList()
        : allItems.where((item) {
            final content = item.content?.toLowerCase() ?? '';
            return content.contains(query.toLowerCase());
          }).toList();

    setState(() {
      _displayItems = filtered;
      _selectedIndex = filtered.isNotEmpty ? 0 : -1;
    });

    // 滚动到新的选中项
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToSelectedIndex();
    });
  }

  void _navigateLeft() {
    if (_displayItems.isNotEmpty && _selectedIndex > 0) {
      setState(() {
        _selectedIndex--;
      });
      _scrollToSelectedIndex();
    }
  }

  void _navigateRight() {
    if (_displayItems.isNotEmpty && _selectedIndex < _displayItems.length - 1) {
      setState(() {
        _selectedIndex++;
      });
      _scrollToSelectedIndex();
    }
  }

  void _scrollToSelectedIndex() {
    if (_scrollController.hasClients &&
        _selectedIndex >= 0 &&
        _displayItems.isNotEmpty) {
      const cardWidth = 280.0;
      const cardMargin = 32.0; // 16 + 16 horizontal margin
      const totalCardWidth = cardWidth + cardMargin;
      final screenWidth = MediaQuery.of(context).size.width;
      final targetOffset =
          (_selectedIndex * totalCardWidth) -
          (screenWidth / 2) +
          (totalCardWidth / 2);

      unawaited(
        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  /// 构建紧凑模式专用的卡片，带选中效果
  Widget _buildCompactModeCard(ClipItem item, int index) {
    final isSelected = index == _selectedIndex;

    return Container(
      width: 280,
      margin: const EdgeInsets.fromLTRB(15, 15, 15, 15),
      child: MouseRegion(
        onEnter: (_) {
          setState(() {
            _selectedIndex = index;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          transform: Matrix4.diagonal3Values(
            isSelected ? 1.05 : 1.0,
            isSelected ? 1.05 : 1.0,
            1,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Theme.of(
                        context,
                      ).primaryColor.withValues(alpha: 0.4),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 15,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: isSelected ? 1.0 : 0.7,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isSelected
                        ? Theme.of(context).primaryColor.withValues(alpha: 0.5)
                        : Colors.transparent,
                    width: 3,
                  ),
                ),
                child: ClipItemCard(
                  key: ValueKey(item.id),
                  item: item,
                  displayMode: DisplayMode.compact,
                  onTap: () {
                    setState(() {
                      _selectedIndex = index;
                    });
                    // 点击图片时复制图片
                    unawaited(
                      ClipItemUtil.handleItemTap(item, ref, context: context),
                    );
                  },
                  onDelete: () {
                    unawaited(
                      ClipItemUtil.handleItemDelete(
                        item,
                        ref,
                        context: context,
                      ),
                    );
                  },
                  onFavoriteToggle: () {
                    unawaited(
                      ClipItemUtil.handleFavoriteToggle(
                        item,
                        ref,
                        context: context,
                      ),
                    );
                  },
                  searchQuery: _searchController.text,
                  enableOcrCopy: true,
                  onOcrTextTap: () {
                    // 点击OCR文字时只复制文字
                    unawaited(
                      ClipItemUtil.handleOcrTextTap(
                        item,
                        ref,
                        context: context,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ), // 关闭 AnimatedContainer
      ), // 关闭 MouseRegion
    ); // 关闭 Container
  }

  Widget _buildWindowHeader(S l10n) {
    return Container(
      margin: const EdgeInsets.fromLTRB(23, 16, 23, 10),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.5,
          ),
          child: Row(
            children: [
              // 搜索框在左边
              Expanded(
                child: _buildSearchBar(l10n),
              ),
              const SizedBox(width: 16),
              // 返回按钮在右边
              _buildBackAction(l10n),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBackAction(S l10n) {
    return IconButton(
      icon: const Icon(Icons.view_sidebar_rounded, size: 20),
      tooltip: l10n.headerActionBackTraditional,
      onPressed: () async {
        await _switchToClassic();
      },
    );
  }

  Widget _buildSearchBar(S l10n) {
    return EnhancedSearchBar(
      controller: _searchController,
      hintText: l10n.searchHint,
      onChanged: (query) {
        _onUserInteraction();
        _filterItems(query);
      },
      onClear: () {
        _onUserInteraction();
        _searchController.clear();
        _filterItems('');
      },
      dense: true,
    );
  }

  Future<void> _switchToClassic() async {
    ref.read(userPreferencesProvider.notifier).setUiMode(UiMode.classic);
    if (!mounted) {
      return;
    }
    await WindowManagementService.instance.applyUISettings(
      UiMode.classic,
      context: context,
      userPreferences: ref.read(userPreferencesProvider),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 监听剪贴板变化和历史列表变化
    ref
      ..listen<AsyncValue<ClipItem>>(clipboardStreamProvider, (previous, next) {
        next.whenData((clipItem) {
          // 将新的剪贴板项目添加到历史记录
          ref.read(clipboardHistoryProvider.notifier).addItem(clipItem);
        });
      })
      ..listen<List<ClipItem>>(clipboardHistoryProvider, (previous, next) {
        if (!mounted) return;
        setState(() {
          _displayItems = next.toList();
          _selectedIndex = _displayItems.isNotEmpty ? 0 : -1;
        });
        // 滚动到新的选中项
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToSelectedIndex();
        });
      });

    final l10n = S.of(context)!;

    // 包装在 MouseRegion 和 Listener 中以捕获用户交互
    return MouseRegion(
      onHover: (_) => _onUserInteraction(),
      child: Listener(
        onPointerDown: (_) => _onUserInteraction(),
        onPointerMove: (_) => _onUserInteraction(),
        onPointerSignal: (_) => _onUserInteraction(), // 捕获滚动事件
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): _navigateLeft,
            const SingleActivator(LogicalKeyboardKey.arrowRight):
                _navigateRight,
            const SingleActivator(LogicalKeyboardKey.enter): () {
              if (_selectedIndex >= 0 && _displayItems.isNotEmpty) {
                unawaited(
                  ClipItemUtil.handleItemTap(
                    _displayItems[_selectedIndex],
                    ref,
                    context: context,
                  ),
                );
              }
            },
            const SingleActivator(LogicalKeyboardKey.space): () {
              if (_selectedIndex >= 0 && _displayItems.isNotEmpty) {
                unawaited(
                  ClipItemUtil.handleItemTap(
                    _displayItems[_selectedIndex],
                    ref,
                    context: context,
                  ),
                );
              }
            },
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(context).pop(),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Container(
                width: double.infinity,
                height: double.infinity,
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.black.withValues(alpha: 0.8)
                      : Colors.white.withValues(alpha: 0.85),
                ),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: 20,
                    sigmaY: 20,
                    tileMode: ui.TileMode.decal,
                  ),
                  child: Column(
                    children: [
                      _buildWindowHeader(l10n),

                      // 紧凑模式的剪贴板浏览 - 居中显示，支持键盘导航
                      Expanded(
                        child: _displayItems.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.content_paste_search,
                                      size: 64,
                                      color:
                                          Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white.withValues(alpha: 0.6)
                                          : Colors.black.withValues(alpha: 0.6),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      S.of(context)!.searchEmptyTitle,
                                      style: TextStyle(
                                        color:
                                            Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? Colors.white
                                            : Colors.black,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : Center(
                                child: Container(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 15,
                                  ),
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    controller: _scrollController,
                                    itemCount: _displayItems.length,
                                    padding: const EdgeInsets.only(bottom: 15),
                                    itemBuilder: (context, index) {
                                      final item = _displayItems[index];
                                      return _buildCompactModeCard(item, index);
                                    },
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ), // 关闭 CallbackShortcuts
      ), // 关闭 Listener
    ); // 关闭 MouseRegion
  }
}
