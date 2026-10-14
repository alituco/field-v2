import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import 'profile.dart';
import 'profile_repository.dart';
import '../ui/fieldrush_toast.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({
    super.key,
    required this.profile,
    required this.profileRepository,
  });

  final PlayerProfile profile;
  final ProfileRepository profileRepository;

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _usernameController;
  late final TextEditingController _bioController;
  late final TextEditingController _avatarUrlController;
  final _imagePicker = ImagePicker();
  Uint8List? _selectedAvatarBytes;
  String _selectedAvatarExtension = 'jpg';
  String _selectedAvatarContentType = 'image/jpeg';
  bool _isSaving = false;
  bool _isPickingImage = false;

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController(
      text: widget.profile.displayName,
    );
    _usernameController = TextEditingController(text: widget.profile.username);
    _bioController = TextEditingController(text: widget.profile.bio);
    _avatarUrlController = TextEditingController(
      text: widget.profile.avatarUrl ?? '',
    );
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _usernameController.dispose();
    _bioController.dispose();
    _avatarUrlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final displayName = _displayNameController.text.trim();
    final username = _usernameController.text.trim().toLowerCase();
    final bio = _bioController.text.trim();
    var avatarUrl = _avatarUrlController.text.trim();

    final validationError = _validate(bio: bio, avatarUrl: avatarUrl);
    if (validationError != null) {
      showFieldrushToast(context, validationError);
      return;
    }

    setState(() => _isSaving = true);
    try {
      final selectedAvatarBytes = _selectedAvatarBytes;
      if (selectedAvatarBytes != null) {
        avatarUrl = await widget.profileRepository.uploadCurrentUserAvatar(
          bytes: selectedAvatarBytes,
          fileExtension: _selectedAvatarExtension,
          contentType: _selectedAvatarContentType,
        );
        _avatarUrlController.text = avatarUrl;
      }

      await widget.profileRepository.updateCurrentProfile(
        ProfileUpdate(
          displayName: displayName,
          username: username,
          bio: bio,
          avatarUrl: avatarUrl,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      showFieldrushToast(
        context,
        userFacingError(
          error,
          fallback: 'We could not save your profile. Try again.',
        ),
      );
    }
  }

  Future<void> _pickAvatar() async {
    if (_isSaving || _isPickingImage) return;

    setState(() => _isPickingImage = true);
    try {
      final pickedImage = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 88,
      );
      if (pickedImage == null) return;

      final bytes = await pickedImage.readAsBytes();
      if (!mounted) return;

      setState(() {
        _selectedAvatarBytes = bytes;
        _selectedAvatarExtension = _fileExtensionFromName(pickedImage.name);
        _selectedAvatarContentType = _contentTypeForAvatar(
          extension: _selectedAvatarExtension,
          mimeType: pickedImage.mimeType,
        );
      });
    } catch (error) {
      if (!mounted) return;
      showFieldrushToast(
        context,
        userFacingError(
          error,
          fallback: 'We could not open that photo. Try another one.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isPickingImage = false);
      }
    }
  }

  void _removeAvatar() {
    setState(() {
      _selectedAvatarBytes = null;
      _avatarUrlController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: const FieldPageHeader(title: 'Edit Profile', showBack: true),
        child: ListView(
          padding: fieldHeaderAwarePadding(context, top: 16, bottom: 36),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: fieldGray100),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: fieldGray900.withValues(alpha: 0.035),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  _EditAvatarPreview(
                    displayNameController: _displayNameController,
                    avatarUrlController: _avatarUrlController,
                    selectedAvatarBytes: _selectedAvatarBytes,
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _isSaving || _isPickingImage
                            ? null
                            : _pickAvatar,
                        style: FilledButton.styleFrom(
                          backgroundColor: fieldGray900,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        icon: const Icon(Icons.photo_library_rounded, size: 18),
                        label: Text(
                          _isPickingImage ? 'Opening' : 'Choose Photo',
                        ),
                      ),
                      if (_selectedAvatarBytes != null ||
                          _avatarUrlController.text.trim().isNotEmpty) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _isSaving ? null : _removeAvatar,
                          tooltip: 'Remove photo',
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 20),
                  _ProfileTextField(
                    controller: _displayNameController,
                    label: 'Name',
                    readOnly: true,
                  ),
                  const SizedBox(height: 14),
                  _ProfileTextField(
                    controller: _usernameController,
                    label: 'Username',
                    prefixText: '@',
                    readOnly: true,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Manage your name and username in Account settings. '
                    'Your public name uses your first name and last initial.',
                    style: TextStyle(color: fieldGray500, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  _ProfileTextField(
                    controller: _bioController,
                    label: 'Bio',
                    maxLength: 160,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 54,
              child: FilledButton(
                onPressed: _isSaving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: fieldGray900,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: _isSaving
                    ? const Text('SAVING PROFILE…')
                    : const Text(
                        'SAVE PROFILE',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditAvatarPreview extends StatelessWidget {
  const _EditAvatarPreview({
    required this.displayNameController,
    required this.avatarUrlController,
    required this.selectedAvatarBytes,
  });

  final TextEditingController displayNameController;
  final TextEditingController avatarUrlController;
  final Uint8List? selectedAvatarBytes;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([displayNameController, avatarUrlController]),
      builder: (context, _) {
        final name = displayNameController.text.trim();
        final avatarUrl = avatarUrlController.text.trim();
        final initials = _initials(name.isEmpty ? 'Player' : name);
        final selectedBytes = selectedAvatarBytes;

        return Container(
          width: 92,
          height: 92,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [fieldEmerald500, fieldBlue600],
            ),
            boxShadow: [
              BoxShadow(
                color: fieldEmerald500.withValues(alpha: 0.20),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipOval(
            child: selectedBytes != null
                ? Image.memory(selectedBytes, fit: BoxFit.cover)
                : avatarUrl.isEmpty
                ? Center(
                    child: Text(
                      initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  )
                : Image.network(
                    avatarUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Center(
                      child: Text(
                        initials,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _ProfileTextField extends StatelessWidget {
  const _ProfileTextField({
    required this.controller,
    required this.label,
    this.prefixText,
    this.maxLength,
    this.maxLines = 1,
    this.textInputAction,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final String label;
  final String? prefixText;
  final int? maxLength;
  final int maxLines;
  final TextInputAction? textInputAction;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLength: maxLength,
      maxLines: maxLines,
      textInputAction: textInputAction,
      readOnly: readOnly,
      style: const TextStyle(
        color: fieldGray900,
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
      decoration: InputDecoration(
        labelText: label,
        prefixText: prefixText,
        filled: true,
        fillColor: fieldGray100,
        counterStyle: const TextStyle(color: fieldGray400, fontSize: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: fieldEmerald500, width: 1.4),
        ),
      ),
    );
  }
}

String? _validate({required String bio, required String avatarUrl}) {
  if (bio.length > 160) return 'Bio must be 160 characters or fewer.';
  final parsedAvatarUrl = Uri.tryParse(avatarUrl);
  if (avatarUrl.isNotEmpty &&
      (parsedAvatarUrl == null ||
          !parsedAvatarUrl.hasScheme ||
          !['http', 'https'].contains(parsedAvatarUrl.scheme))) {
    return 'Avatar URL is not valid.';
  }
  return null;
}

String _fileExtensionFromName(String name) {
  final parts = name.split('.');
  if (parts.length < 2) return 'jpg';
  return parts.last.toLowerCase();
}

String _contentTypeForAvatar({required String extension, String? mimeType}) {
  if (mimeType == 'image/jpeg' ||
      mimeType == 'image/png' ||
      mimeType == 'image/webp') {
    return mimeType!;
  }

  return switch (extension.toLowerCase()) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => 'image/jpeg',
  };
}

String _initials(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return '?';
  return words.take(2).map((word) => word.substring(0, 1)).join().toUpperCase();
}
