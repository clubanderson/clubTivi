import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _SettingsSection(
            title: 'EPG',
            children: [
              ListTile(
                leading: const Icon(Icons.source_rounded),
                title: const Text('EPG Sources'),
                subtitle: const Text('Manage XMLTV feeds (epg.best, etc.)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('EPG Mappings'),
                subtitle: const Text('Channel ↔ EPG mapping manager'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('Auto-Refresh'),
                subtitle: const Text('Every 12 hours'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
            ],
          ),
          _SettingsSection(
            title: 'Playback',
            children: [
              ListTile(
                leading: const Icon(Icons.speed_rounded),
                title: const Text('Buffer Size'),
                subtitle: const Text('Auto'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.swap_horizontal_circle_rounded),
                title: const Text('Failover Mode'),
                subtitle: const Text('Cold (switch on buffering)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
            ],
          ),
          _SettingsSection(
            title: 'Remote Control',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.web_rounded),
                title: const Text('Web Remote'),
                subtitle: const Text('Allow control from phone browser'),
                value: false,
                onChanged: (value) {},
              ),
              ListTile(
                leading: const Icon(Icons.gamepad_rounded),
                title: const Text('Button Mapping'),
                subtitle: const Text('Customize remote buttons'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
            ],
          ),
          _SettingsSection(
            title: 'About',
            children: [
              const ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('clubTivi'),
                subtitle: Text('v0.1.0 • Open Source • Apache-2.0'),
              ),
              ListTile(
                leading: const Icon(Icons.code_rounded),
                title: const Text('Source Code'),
                subtitle: const Text('github.com/clubanderson/clubTivi'),
                onTap: () {},
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 0.5,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}
