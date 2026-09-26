import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_tokens.dart';

/// Sign-in and sign-up, with the role chosen at sign-up.
///
/// The two roles are not cosmetic: an owner can register a store and list
/// places, a customer can only review. The role is written once and the database
/// refuses any later change, so this screen is the only place it is decided.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();

  bool _signingUp = false;
  bool _busy = false;
  bool _obscure = true;
  UserRole _role = UserRole.customer;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_signingUp) {
        await widget.auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          displayName: _name.text.trim(),
          role: _role,
        );
      } else {
        await widget.auth.signIn(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTokens.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTokens.s24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Wordmark(),
                    const SizedBox(height: AppTokens.s32),

                    // Segmented sign-in / sign-up.
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: AppTokens.surfaceMuted,
                        borderRadius: BorderRadius.circular(AppTokens.radiusButton),
                      ),
                      child: Row(
                        children: [
                          _Segment(
                            label: 'Sign in',
                            selected: !_signingUp,
                            onTap: () => setState(() {
                              _signingUp = false;
                              _error = null;
                            }),
                          ),
                          _Segment(
                            label: 'Create account',
                            selected: _signingUp,
                            onTap: () => setState(() {
                              _signingUp = true;
                              _error = null;
                            }),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppTokens.s24),

                    if (_signingUp) ...[
                      _Field(
                        controller: _name,
                        label: 'Your name',
                        icon: Icons.person_outline_rounded,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: AppTokens.s12),
                    ],

                    _Field(
                      controller: _email,
                      label: 'Email',
                      icon: Icons.mail_outline_rounded,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppTokens.s12),
                    _Field(
                      controller: _password,
                      label: 'Password',
                      icon: Icons.lock_outline_rounded,
                      obscure: _obscure,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      suffix: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 20,
                          color: AppTokens.textMuted,
                        ),
                      ),
                    ),

                    if (_signingUp) ...[
                      const SizedBox(height: AppTokens.s20),
                      Text('I am a…', style: AppTokens.titleSm),
                      const SizedBox(height: AppTokens.s8),
                      _RoleCard(
                        role: UserRole.customer,
                        selected: _role == UserRole.customer,
                        onTap: () => setState(() => _role = UserRole.customer),
                      ),
                      const SizedBox(height: AppTokens.s8),
                      _RoleCard(
                        role: UserRole.owner,
                        selected: _role == UserRole.owner,
                        onTap: () => setState(() => _role = UserRole.owner),
                      ),
                    ],

                    if (_error != null) ...[
                      const SizedBox(height: AppTokens.s16),
                      _ErrorNote(_error!),
                    ],

                    const SizedBox(height: AppTokens.s24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTokens.accent,
                        disabledBackgroundColor: AppTokens.accent.withValues(alpha: 0.5),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTokens.radiusButton),
                        ),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              _signingUp ? 'Create account' : 'Sign in',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                    ),

                    const SizedBox(height: AppTokens.s16),
                    Text(
                      'Anyone can browse and review. Store owners can list their '
                      'places after registering a business.',
                      style: AppTokens.metadata,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            color: AppTokens.accent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.map_rounded, color: Colors.white, size: 30),
        ),
        const SizedBox(height: AppTokens.s12),
        const Text('RevMap', style: AppTokens.titleLg),
        const SizedBox(height: 2),
        Text('Find places worth trusting', style: AppTokens.caption),
      ],
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.label, required this.selected, this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppTokens.background : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTokens.radiusButton - 3),
            boxShadow: selected ? AppTokens.controlShadow : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: selected ? AppTokens.textPrimary : AppTokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.role, required this.selected, this.onTap});
  final UserRole role;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(AppTokens.s16),
        decoration: BoxDecoration(
          color: selected ? AppTokens.accentSoft : AppTokens.background,
          borderRadius: BorderRadius.circular(AppTokens.radiusButton),
          border: Border.all(
            color: selected ? AppTokens.accent : AppTokens.hairline,
            width: selected ? 1.8 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              role == UserRole.owner
                  ? Icons.storefront_rounded
                  : Icons.person_rounded,
              size: 22,
              color: selected ? AppTokens.accent : AppTokens.textMuted,
            ),
            const SizedBox(width: AppTokens.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(role.label, style: AppTokens.titleSm),
                  const SizedBox(height: 1),
                  Text(role.blurb, style: AppTokens.metadata),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, size: 20, color: AppTokens.accent),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.suffix,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onFieldSubmitted: onSubmitted,
      autocorrect: false,
      style: AppTokens.body,
      decoration: InputDecoration(
        hintText: label,
        prefixIcon: Icon(icon, size: 20, color: AppTokens.textMuted),
        suffixIcon: suffix,
        filled: true,
        fillColor: AppTokens.surfaceMuted,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppTokens.s16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusButton),
          borderSide: BorderSide.none,
        ),
      ),
      validator: (v) {
        final value = (v ?? '').trim();
        if (_isSignUpField(label) && value.isEmpty) return 'Required';
        if (label == 'Email' &&
            !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) {
          return 'Enter a valid email address';
        }
        if (label == 'Password' && value.length < 6) {
          return 'At least 6 characters';
        }
        return null;
      },
    );
  }

  /// "Your name" is the only field that only matters when signing up.
  static bool _isSignUpField(String label) => label == 'Your name';
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.s12),
      decoration: BoxDecoration(
        color: AppTokens.dangerSoft,
        borderRadius: BorderRadius.circular(AppTokens.radiusButton),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 18, color: AppTokens.danger),
          const SizedBox(width: AppTokens.s8),
          Expanded(
            child: Text(
              message,
              style: AppTokens.caption.copyWith(color: AppTokens.danger),
            ),
          ),
        ],
      ),
    );
  }
}
