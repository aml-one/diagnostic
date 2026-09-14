import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ai/deepseek_client.dart';
import '../core/app_version.dart';
import '../services/settings_store.dart';
import '../state/deepseek_providers.dart';
import '../theme/desktop_theme.dart';
import '../widgets/desktop_chrome.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _key = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  bool _testing = false;
  bool _saved = false;
  String? _saveError;
  String? _testMessage;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final stored = await ref.read(deepSeekApiKeyProvider.future);
    if (!mounted) return;
    setState(() => _key.text = stored);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saveError = null;
      _saved = false;
      _testMessage = null;
    });
    try {
      await ref.read(deepSeekApiKeyProvider.notifier).save(_key.text);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = true;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not save the key on this PC.';
      });
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testMessage = null;
      _testOk = false;
    });
    try {
      await ref.read(deepSeekApiKeyProvider.notifier).test(_key.text);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = true;
        _testMessage = 'Key works.';
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testMessage = err is DeepSeekException
            ? err.message
            : 'Could not test the key.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = AmlTheme.mutedOf(context);
    final keyAsync = ref.watch(deepSeekApiKeyProvider);
    final stored = keyAsync.valueOrNull ?? '';
    final loading = keyAsync.isLoading && _key.text.isEmpty && !_saving;
    final busy = _saving || _testing;

    return SettingsPageScaffold(
      title: 'Settings',
      body: loading
          ? const Center(
              child: BirdLoader(size: 72, semanticsLabel: 'Loading settings'),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Family rule: the About hero stays at the top, unchanged.
                const SettingsAboutHero(
                  productName: 'Diagnostic',
                  versionLabel: 'v$kAppVersion',
                  creditLabel: 'AmL One World',
                  semanticsLabel: 'Diagnostic',
                ),
                const SizedBox(height: 16),
                DesktopContent(
                  maxWidth: Desk.formWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const DesktopSectionLabel(label: 'AI diagnosis'),
                      const SizedBox(height: 6),
                      DesktopPanel(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DesktopPanelHeader(
                              icon: Icons.key_rounded,
                              accent: AmlTheme.violet,
                              title: 'DeepSeek API key',
                              subtitle:
                                  'Used to summarize ANR traces. Stored in '
                                  'Windows Credential Manager — never in the '
                                  'repo.',
                              trailing: DesktopTag(
                                label: stored.trim().isEmpty
                                    ? 'not set'
                                    : 'stored',
                                color: stored.trim().isEmpty
                                    ? AmlTheme.amber
                                    : AmlTheme.mint,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Text(
                                  'Current',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: muted,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    maskDeepSeekApiKey(stored),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Desk.mono(
                                      size: 11.5,
                                      weight: FontWeight.w700,
                                      color: stored.trim().isEmpty
                                          ? muted
                                          : AmlTheme.mint,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _key,
                              obscureText: _obscure,
                              autocorrect: false,
                              enableSuggestions: false,
                              keyboardType: TextInputType.visiblePassword,
                              textInputAction: TextInputAction.done,
                              style: Desk.mono(size: 13),
                              onChanged: (_) => setState(() {
                                _saved = false;
                                _saveError = null;
                                _testMessage = null;
                              }),
                              onSubmitted: (_) => _save(),
                              inputFormatters: [
                                FilteringTextInputFormatter.deny(RegExp(r'\s')),
                              ],
                              decoration: InputDecoration(
                                labelText: 'API key',
                                hintText: 'sk-…',
                                suffixIcon: DesktopIconAction(
                                  tooltip: _obscure ? 'Show key' : 'Hide key',
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                  icon: _obscure
                                      ? Icons.visibility_rounded
                                      : Icons.visibility_off_rounded,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                FilledButton(
                                  onPressed: busy ? null : _save,
                                  child: Text(_saving ? 'Saving…' : 'Save key'),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  onPressed: busy ? null : _test,
                                  child: Text(
                                    _testing ? 'Testing…' : 'Test key',
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _StatusLine(
                                    message: _statusMessage(),
                                    ok: _statusOk(),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  String? _statusMessage() {
    if (_saveError != null) return _saveError;
    if (_testMessage != null) return _testMessage;
    if (_saved) {
      return _key.text.trim().isEmpty ? 'Cleared.' : 'Saved on this PC.';
    }
    return null;
  }

  bool _statusOk() {
    if (_saveError != null) return false;
    if (_testMessage != null) return _testOk;
    return true;
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.message, required this.ok});

  final String? message;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    final color = ok ? AmlTheme.mint : Desk.danger;
    return Row(
      children: [
        Icon(
          ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
          size: 15,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            message!,
            maxLines: 2,
            style: TextStyle(
              fontSize: 12,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
