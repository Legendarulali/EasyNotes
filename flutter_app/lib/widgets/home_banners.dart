import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../src/app_version.dart';
import '../src/services/update_service.dart';
import '../src/sync/sync_service.dart';
import 'sync_widgets.dart';

const Color _bannerColor = Color(0xFF242A33);
const Color _bannerBorder = Color(0xFF34404F);
const Color _accent = Color(0xFF8AB4F8);
const Color _warning = Color(0xFFFDD663);

/// Thin strip above the library while an empty library is being filled from the Google
/// Drive backup. Nothing is blocked meanwhile; notebooks appear as they arrive.
class RestoreBanner extends StatelessWidget {
  const RestoreBanner({super.key, required this.sync});

  final SyncService sync;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) {
      if (sync.phase != SyncPhase.restoring) return const SizedBox.shrink();
      final progress = sync.restoreProgress;
      final total = progress?.total ?? 0;
      final done = progress?.done ?? 0;
      return Semantics(
        liveRegion: true,
        child: Container(
          key: const ValueKey('restore-banner'),
          decoration: const BoxDecoration(
            color: _bannerColor,
            border: Border(bottom: BorderSide(color: _bannerBorder)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.cloud_download_outlined, size: 18, color: _accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      total > 0
                          ? 'Restoring notes from Google Drive… $done of $total'
                          : 'Restoring notes from Google Drive…',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(minHeight: 2, value: total > 0 ? done / total : null),
            ],
          ),
        ),
      );
    },
  );
}

/// Dismissible notice of a newer release on GitHub. On Windows the update means
/// replacing the app folder by hand, so it also asks to back the notes up to Google
/// Drive first, with a "Sync now" button when signed in.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.updates, required this.sync, required this.libraryPath, this.windows});

  final UpdateService updates;
  final SyncService sync;

  /// Where the notebooks are stored (shown in the Windows warning).
  final String libraryPath;

  /// Show the Windows warning (defaults to the platform this runs on).
  final bool? windows;

  Future<void> _syncNow(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await sync.syncNow();
    final ok = sync.phase == SyncPhase.synced;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            ok ? 'Your notes are backed up to Google Drive.' : (sync.message ?? 'The backup did not finish. Try again.'),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([updates, sync]),
    builder: (context, _) {
      final update = updates.available;
      if (update == null) return const SizedBox.shrink();
      final onWindows = windows ?? Platform.isWindows;
      final busy = sync.phase == SyncPhase.syncing || sync.phase == SyncPhase.restoring;
      final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70);
      return Container(
        key: const ValueKey('update-banner'),
        decoration: const BoxDecoration(
          color: _bannerColor,
          border: Border(bottom: BorderSide(color: _bannerBorder)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.system_update_alt, size: 20, color: _accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'EasyNotes ${update.version} is available',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white),
                  ),
                  Text('You have version $appVersion.', style: small),
                  if (onWindows) ...[
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 18, color: _warning),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Back up first: ${sync.isSignedIn ? 'sync your notes to Google Drive' : 'sign in with Google (top right) and sync your notes'} '
                            'before you download the new version and replace the EasyNotes app folder. Your '
                            'notebooks are kept in $libraryPath, outside the app folder, so replacing it should '
                            'not touch them, but a fresh backup keeps them safe if anything goes wrong.',
                            style: small?.copyWith(color: const Color(0xFFF1E3B0)),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (onWindows && sync.isSignedIn) ...[
                        FilledButton.tonalIcon(
                          onPressed: busy ? null : () => _syncNow(context),
                          icon: busy
                              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.cloud_sync_outlined),
                          label: const Text('Sync now'),
                        ),
                        Text(describeLastSync(sync.lastSynced), style: small),
                      ],
                      TextButton.icon(
                        onPressed: () => launchUrl(update.url, mode: LaunchMode.externalApplication),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('View release'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, size: 20, color: Colors.white60),
              onPressed: updates.dismiss,
            ),
          ],
        ),
      );
    },
  );
}
