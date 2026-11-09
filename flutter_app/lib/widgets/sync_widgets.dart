import 'package:flutter/material.dart';

import '../src/sync/google_auth.dart';
import '../src/sync/sync_service.dart';

/// Icon, colour and short label of a [SyncPhase].
({IconData icon, Color color, String label}) syncPhaseStyle(SyncPhase phase) => switch (phase) {
  SyncPhase.synced => (icon: Icons.cloud_done_outlined, color: const Color(0xFF81C995), label: 'Synced'),
  SyncPhase.syncing => (icon: Icons.sync, color: const Color(0xFF8AB4F8), label: 'Syncing…'),
  SyncPhase.pending => (icon: Icons.cloud_upload_outlined, color: Colors.white70, label: 'Pending'),
  SyncPhase.offline => (icon: Icons.cloud_off_outlined, color: const Color(0xFFFDD663), label: 'Offline'),
  SyncPhase.error => (icon: Icons.error_outline, color: const Color(0xFFF28B82), label: 'Sync error'),
  SyncPhase.signingIn => (icon: Icons.login, color: Colors.white54, label: 'Signing in…'),
  SyncPhase.signedOut || SyncPhase.unavailable => (icon: Icons.cloud_off, color: Colors.white38, label: 'Local only'),
};

/// "just now", "4 min ago", "at 14:05".
String describeLastSync(DateTime? t, {DateTime? now}) {
  if (t == null) return 'not yet backed up';
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 45) return 'backed up just now';
  if (d.inMinutes < 60) return 'backed up ${d.inMinutes.clamp(1, 59)} min ago';
  final hh = t.hour.toString().padLeft(2, '0'), mm = t.minute.toString().padLeft(2, '0');
  return 'backed up at $hh:$mm';
}

String _tooltip(SyncService sync) {
  final account = sync.account;
  final lines = <String>[
    if (account != null) 'Google Drive backup · ${account.email}' else 'Not signed in: notebooks are saved on this device only',
    if (account != null) describeLastSync(sync.lastSynced),
    if (sync.message != null) sync.message!,
  ];
  return lines.join('\n');
}

/// Subtle backup status for the editor's status bar ("Synced", "Syncing…", "Offline").
/// Tapping it backs up right away.
class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({super.key, required this.sync});

  final SyncService sync;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final style = syncPhaseStyle(sync.phase);
        final text = Theme.of(context).textTheme.labelMedium?.copyWith(color: style.color);
        return Tooltip(
          message: _tooltip(sync),
          waitDuration: const Duration(milliseconds: 400),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: sync.isSignedIn ? sync.syncNow : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PhaseIcon(phase: sync.phase, size: 14, color: style.color),
                  const SizedBox(width: 5),
                  Text(style.label, style: text),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Top-right account control of the home screen: "Sign in with Google", or the user's
/// avatar with a backup status badge and a menu (Back up now / Sign out).
class AccountButton extends StatelessWidget {
  const AccountButton({super.key, required this.sync, this.compact = false});

  final SyncService sync;

  /// Icon-only sign-in button (narrow screens).
  final bool compact;

  Future<void> _signIn(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (sync.phase == SyncPhase.unavailable || !sync.auth.isConfigured) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.cloud_off),
          title: const Text('Google backup is not set up'),
          content: Text(sync.auth.setupHint),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
      return;
    }
    try {
      final ok = await sync.signIn();
      if (ok) {
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Signed in as ${sync.account?.email}. Notebooks now back up to Google Drive › EasyNotes.'),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text('Google sign-in failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final account = sync.account;
        if (sync.phase == SyncPhase.signingIn) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        if (account == null) {
          final signedOutWithMessage = sync.phase == SyncPhase.signedOut && sync.message != null;
          if (compact) {
            return IconButton(
              tooltip: signedOutWithMessage ? sync.message : 'Sign in with Google',
              icon: Icon(signedOutWithMessage ? Icons.sync_problem : Icons.account_circle_outlined),
              onPressed: () => _signIn(context),
            );
          }
          return Tooltip(
            message: signedOutWithMessage ? sync.message! : 'Back up your notebooks to Google Drive',
            child: OutlinedButton.icon(
              onPressed: () => _signIn(context),
              icon: Icon(signedOutWithMessage ? Icons.sync_problem : Icons.account_circle_outlined),
              label: const Text('Sign in with Google'),
            ),
          );
        }
        return _AccountMenu(sync: sync, account: account);
      },
    );
  }
}

enum _AccountAction { syncNow, signOut }

class _AccountMenu extends StatelessWidget {
  const _AccountMenu({required this.sync, required this.account});

  final SyncService sync;
  final GoogleAccount account;

  @override
  Widget build(BuildContext context) {
    final style = syncPhaseStyle(sync.phase);
    return PopupMenuButton<_AccountAction>(
      tooltip: '${account.displayName} · ${style.label}',
      position: PopupMenuPosition.under,
      color: const Color(0xFF2C2C2E),
      onSelected: (a) async {
        switch (a) {
          case _AccountAction.syncNow:
            await sync.syncNow();
          case _AccountAction.signOut:
            await sync.signOut();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<_AccountAction>(
          enabled: false,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _Avatar(account: account, radius: 18),
            title: Text(account.displayName, style: const TextStyle(color: Colors.white)),
            subtitle: Text(
              [account.email, '${style.label} · ${describeLastSync(sync.lastSynced)}', ?sync.message].join('\n'),
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _AccountAction.syncNow,
          child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.cloud_sync_outlined), title: Text('Back up now')),
        ),
        const PopupMenuItem(
          value: _AccountAction.signOut,
          child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.logout), title: Text('Sign out')),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _Avatar(account: account, radius: 17),
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(color: Color(0xFF1E1E1E), shape: BoxShape.circle),
                child: _PhaseIcon(phase: sync.phase, size: 12, color: style.color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.account, required this.radius});

  final GoogleAccount account;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final photo = account.photoUrl;
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFF3C4A63),
      foregroundImage: photo == null ? null : NetworkImage(photo),
      onForegroundImageError: photo == null ? null : (_, _) {},
      child: Text(account.initials, style: TextStyle(fontSize: radius * 0.75, color: Colors.white)),
    );
  }
}

/// Phase icon; spins while syncing.
class _PhaseIcon extends StatefulWidget {
  const _PhaseIcon({required this.phase, required this.size, required this.color});

  final SyncPhase phase;
  final double size;
  final Color color;

  @override
  State<_PhaseIcon> createState() => _PhaseIconState();
}

class _PhaseIconState extends State<_PhaseIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void initState() {
    super.initState();
    _update();
  }

  @override
  void didUpdateWidget(_PhaseIcon old) {
    super.didUpdateWidget(old);
    _update();
  }

  void _update() {
    if (widget.phase == SyncPhase.syncing) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(syncPhaseStyle(widget.phase).icon, size: widget.size, color: widget.color);
    return widget.phase == SyncPhase.syncing ? RotationTransition(turns: _spin, child: icon) : icon;
  }
}
