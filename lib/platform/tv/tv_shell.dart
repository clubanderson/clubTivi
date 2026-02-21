import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

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
  bool _sidebarFocused = false;

  static const _navItems = [
    _NavItem(icon: Icons.live_tv_rounded, label: 'Live TV', route: '/'),
    _NavItem(icon: Icons.calendar_view_week_rounded, label: 'Guide', route: '/guide'),
    _NavItem(icon: Icons.dns_rounded, label: 'Providers', route: '/providers'),
    _NavItem(icon: Icons.link_rounded, label: 'EPG Map', route: '/epg-mapping'),
    _NavItem(icon: Icons.settings_rounded, label: 'Settings', route: '/settings'),
  ];

  void _navigateTo(int index) {
    if (index == _selectedNav) return;
    setState(() => _selectedNav = index);
    context.go(_navItems[index].route);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Sidebar nav — uses FocusTraversalGroup so D-pad stays within sidebar
        FocusTraversalGroup(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _sidebarFocused ? 200 : 64,
            color: const Color(0xFF0D0D14),
            child: Column(
              children: [
                const SizedBox(height: 24),
                // Logo
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _sidebarFocused
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
                // Nav items — each wrapped in Focus for D-pad
                ...List.generate(_navItems.length, (index) {
                  final item = _navItems[index];
                  final selected = _selectedNav == index;
                  return _TvNavButton(
                    icon: item.icon,
                    label: item.label,
                    selected: selected,
                    expanded: _sidebarFocused,
                    autofocus: index == 0,
                    onSelect: () => _navigateTo(index),
                    onFocusChange: (hasFocus) {
                      if (hasFocus) {
                        setState(() => _sidebarFocused = true);
                      }
                    },
                  );
                }),
              ],
            ),
          ),
        ),
        // Content area — separate FocusTraversalGroup
        Expanded(
          child: FocusTraversalGroup(
            child: Focus(
              onFocusChange: (hasFocus) {
                if (hasFocus) {
                  setState(() => _sidebarFocused = false);
                }
              },
              canRequestFocus: false,
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }
}

class _TvNavButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool expanded;
  final bool autofocus;
  final VoidCallback onSelect;
  final ValueChanged<bool> onFocusChange;

  const _TvNavButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.expanded,
    this.autofocus = false,
    required this.onSelect,
    required this.onFocusChange,
  });

  @override
  State<_TvNavButton> createState() => _TvNavButtonState();
}

class _TvNavButtonState extends State<_TvNavButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = widget.selected || _focused;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (hasFocus) {
          setState(() => _focused = hasFocus);
          widget.onFocusChange(hasFocus);
        },
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            widget.onSelect();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: widget.onSelect,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: isHighlighted
                  ? const Color(0xFF6C5CE7).withValues(alpha: 0.2)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _focused
                    ? const Color(0xFF6C5CE7)
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  color: isHighlighted
                      ? const Color(0xFF6C5CE7)
                      : Colors.white54,
                  size: 24,
                ),
                if (widget.expanded) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: isHighlighted ? Colors.white : Colors.white54,
                        fontSize: 15,
                        fontWeight: isHighlighted
                            ? FontWeight.w600
                            : FontWeight.normal,
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
