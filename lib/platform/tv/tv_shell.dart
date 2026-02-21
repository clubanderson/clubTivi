import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/remote/input_manager.dart';

/// 10-foot TV UI shell — optimized for remote control navigation.
///
/// Key design principles:
/// - Large text and touch targets (minimum 48dp)
/// - High contrast for viewing distance
/// - D-pad focus navigation (no pointer/mouse needed)
/// - Sidebar navigation with content area
/// - Focus ring visible on all interactive elements
class TvShell extends StatefulWidget {
  final Widget child;

  const TvShell({super.key, required this.child});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  int _selectedNav = 0;
  bool _sidebarExpanded = false;

  static const _navItems = [
    _NavItem(icon: Icons.live_tv_rounded, label: 'Live TV', route: '/'),
    _NavItem(icon: Icons.calendar_view_week_rounded, label: 'Guide', route: '/guide'),
    _NavItem(icon: Icons.dns_rounded, label: 'Providers', route: '/providers'),
    _NavItem(icon: Icons.link_rounded, label: 'EPG Map', route: '/epg-mapping'),
    _NavItem(icon: Icons.settings_rounded, label: 'Settings', route: '/settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return InputHandler(
      onAction: _handleAction,
      child: Row(
        children: [
          // Sidebar nav
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _sidebarExpanded ? 200 : 64,
            color: const Color(0xFF0D0D14),
            child: Column(
              children: [
                const SizedBox(height: 24),
                // Logo
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _sidebarExpanded
                      ? const Text(
                          'clubTivi',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF6C5CE7),
                          ),
                        )
                      : const Icon(
                          Icons.live_tv_rounded,
                          color: Color(0xFF6C5CE7),
                          size: 28,
                        ),
                ),
                const SizedBox(height: 32),
                // Nav items
                ...List.generate(_navItems.length, (index) {
                  final item = _navItems[index];
                  final selected = _selectedNav == index;
                  return _TvNavButton(
                    icon: item.icon,
                    label: item.label,
                    selected: selected,
                    expanded: _sidebarExpanded,
                    onTap: () => setState(() => _selectedNav = index),
                  );
                }),
              ],
            ),
          ),
          // Content area
          Expanded(child: widget.child),
        ],
      ),
    );
  }

  void _handleAction(AppAction action) {
    switch (action) {
      case AppAction.navigateLeft:
        if (!_sidebarExpanded) {
          setState(() => _sidebarExpanded = true);
        }
      case AppAction.navigateRight:
        if (_sidebarExpanded) {
          setState(() => _sidebarExpanded = false);
        }
      case AppAction.navigateUp:
        if (_sidebarExpanded && _selectedNav > 0) {
          setState(() => _selectedNav--);
        }
      case AppAction.navigateDown:
        if (_sidebarExpanded && _selectedNav < _navItems.length - 1) {
          setState(() => _selectedNav++);
        }
      default:
        break;
    }
  }
}

class _TvNavButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  const _TvNavButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? const Color(0xFF6C5CE7).withValues(alpha: 0.2)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected ? const Color(0xFF6C5CE7) : Colors.white54,
                  size: 24,
                ),
                if (expanded) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white54,
                        fontSize: 15,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  final String route;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.route,
  });
}

/// Focus-aware card for TV grid items (channels, VOD, etc.).
/// Shows a highlighted border when focused via D-pad navigation.
class TvFocusCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final double width;
  final double height;

  const TvFocusCard({
    super.key,
    required this.child,
    this.onSelect,
    this.width = 200,
    this.height = 120,
  });

  @override
  State<TvFocusCard> createState() => _TvFocusCardState();
}

class _TvFocusCardState extends State<TvFocusCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (hasFocus) => setState(() => _focused = hasFocus),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onSelect?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: widget.width,
        height: widget.height,
        transform: _focused
            ? (Matrix4.identity()..setEntry(0, 0, 1.05)..setEntry(1, 1, 1.05))
            : Matrix4.identity(),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _focused ? const Color(0xFF6C5CE7) : Colors.transparent,
            width: 2,
          ),
          color: const Color(0xFF1A1A2E),
        ),
        child: widget.child,
      ),
    );
  }
}
