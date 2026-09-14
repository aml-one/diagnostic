import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ai/deepseek_client.dart';
import '../core/app_version.dart';
import '../services/settings_store.dart';
import '../state/deepseek_providers.dart';

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
    final ink = AmlTheme.inkOf(context);
    final keyAsync = ref.watch(deepSeekApiKeyProvider);
    final stored = keyAsync.valueOrNull ?? '';
    final loading = keyAsync.isLoading && _key.text.isEmpty && !_saving;
    return SettingsPageScaffold(
      title: 'Settings',
      body: loading
          ? const Center(
              child: BirdLoader(
                size: 96,
                semanticsLabel: 'Loading settings',
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const SettingsAboutHero(
                  productName: 'Diagnostic',
                  versionLabel: 'v$kAppVersion',
                  creditLabel: 'AmL One World',
                  semanticsLabel: 'Diagnostic',
                ),
                const SizedBox(height: 20),
                SettingsSurface(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          settingsPastelIcon(Icons.key_rounded, 'spark'),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'DeepSeek API key',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Used to summarize ANR traces. Stored in Windows '
                        'Credential Manager — never in the repo.',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: AmlTheme.mutedOf(context),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        maskDeepSeekApiKey(stored),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: stored.trim().isEmpty
                              ? AmlTheme.mutedOf(context)
                              : AmlTheme.mint,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _key,
                        obscureText: _obscure,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.visiblePassword,
                        textInputAction: TextInputAction.done,
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
                          suffixIcon: IconButton(
                            tooltip: _obscure ? 'Show key' : 'Hide key',
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_rounded
                                  : Icons.visibility_off_rounded,
                            ),
                          ),
                        ),
                      ),
                      if (_saveError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _saveError!,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFE85D75),
                          ),
                        ),
                      ] else if (_saved) ...[
                        const SizedBox(height: 8),
                        Text(
                          _key.text.trim().isEmpty
                              ? 'Cleared.'
                              : 'Saved on this PC.',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AmlTheme.mint,
                          ),
                        ),
                      ],
                      if (_testMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _testMessage!,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _testOk
                                ? AmlTheme.mint
                                : const Color(0xFFE85D75),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: _saving || _testing ? null : _save,
                              child: Text(
                                _saving ? 'Saving…' : 'Save API key',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _saving || _testing ? null : _test,
                              child: Text(_testing ? 'Testing…' : 'Test key'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
