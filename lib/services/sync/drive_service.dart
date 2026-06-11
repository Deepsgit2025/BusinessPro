import 'dart:convert';

import 'package:http/http.dart' as http;

/// Talks to Google Drive's v3 REST API directly over HTTP. Used on **both**
/// Android and Windows — neither platform needs the googleapis package, and
/// Windows has no google_sign_in at all, so a bare bearer token (obtained via
/// Google Sign-In on Android, handed to Windows over the QR link) is all this
/// needs.
///
/// Scope is `drive.file`: the app only ever sees files it created, so the sync
/// folder and its JSON files are isolated from the user's other Drive content.
class DriveService {
  static const _baseUrl = 'https://www.googleapis.com/drive/v3';
  static const _uploadUrl = 'https://www.googleapis.com/upload/drive/v3';
  static const _folderName = 'BusinessPro Sync';

  String? _accessToken;
  String? _folderId;

  /// Whether a token has been supplied. (Does not check expiry — the caller
  /// refreshes the token before syncing.)
  bool get hasToken => _accessToken != null && _accessToken!.isNotEmpty;

  void setToken(String token) => _accessToken = token;

  void clear() {
    _accessToken = null;
    _folderId = null;
  }

  Map<String, String> get _authHeader => {
        'Authorization': 'Bearer $_accessToken',
      };

  Map<String, String> get _jsonHeaders => {
        ..._authHeader,
        'Content-Type': 'application/json',
      };

  /// Thrown for any non-2xx Drive response so the engine can log + abort the run
  /// without crashing the app.
  static Never _fail(String op, http.Response res) {
    throw DriveException(
        'Drive $op failed (${res.statusCode}): ${res.body}', res.statusCode);
  }

  // ── FOLDER ─────────────────────────────────────────────────────────────────

  /// Finds the "BusinessPro Sync" folder, creating it on first use. The id is
  /// cached for the life of this service instance.
  Future<String> getOrCreateFolder() async {
    if (_folderId != null) return _folderId!;

    final query = Uri.encodeQueryComponent(
        "name='$_folderName' and mimeType='application/vnd.google-apps.folder' "
        'and trashed=false');
    final res = await http.get(
      Uri.parse('$_baseUrl/files?q=$query&fields=files(id,name)&spaces=drive'),
      headers: _jsonHeaders,
    );
    if (res.statusCode != 200) _fail('folder lookup', res);

    final files = (jsonDecode(res.body)['files'] as List?) ?? const [];
    if (files.isNotEmpty) {
      _folderId = files.first['id'] as String;
      return _folderId!;
    }

    final createRes = await http.post(
      Uri.parse('$_baseUrl/files'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'name': _folderName,
        'mimeType': 'application/vnd.google-apps.folder',
      }),
    );
    if (createRes.statusCode != 200 && createRes.statusCode != 201) {
      _fail('folder create', createRes);
    }
    _folderId = jsonDecode(createRes.body)['id'] as String;
    return _folderId!;
  }

  // ── UPLOAD ─────────────────────────────────────────────────────────────────

  /// Writes [content] to `fileName` inside the sync folder, replacing the file
  /// in place if it already exists (so the changes file is a single rolling
  /// document, not an ever-growing pile).
  Future<void> uploadFile(String fileName, String content) async {
    final existingId = await _findFile(fileName);
    if (existingId != null) {
      final res = await http.patch(
        Uri.parse('$_uploadUrl/files/$existingId?uploadType=media'),
        headers: {..._authHeader, 'Content-Type': 'application/json'},
        body: utf8.encode(content),
      );
      if (res.statusCode != 200) _fail('upload (update)', res);
    } else {
      await _createFile(fileName, content);
    }
  }

  /// Creates a new file in two reliable steps instead of a hand-built multipart
  /// body (which Drive parses strictly and can accept with a 200 while silently
  /// dropping the content): (1) POST metadata with the parent folder to mint an
  /// empty file, (2) PATCH its media to write the content. Returns nothing; the
  /// file is then findable by name on the next sync.
  Future<void> _createFile(String fileName, String content) async {
    final folderId = await getOrCreateFolder();

    // 1. Create the (empty) file with its name + parent folder.
    final createRes = await http.post(
      Uri.parse('$_baseUrl/files?fields=id'),
      headers: _jsonHeaders,
      body: jsonEncode({
        'name': fileName,
        'parents': [folderId],
        'mimeType': 'application/json',
      }),
    );
    if (createRes.statusCode != 200 && createRes.statusCode != 201) {
      _fail('upload (create metadata)', createRes);
    }
    final fileId = jsonDecode(createRes.body)['id'] as String;

    // 2. Write its content.
    final mediaRes = await http.patch(
      Uri.parse('$_uploadUrl/files/$fileId?uploadType=media'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: utf8.encode(content),
    );
    if (mediaRes.statusCode != 200) _fail('upload (write media)', mediaRes);
  }

  // ── DOWNLOAD ─────────────────────────────────────────────────────────────

  /// Returns the text content of `fileName`, or null if it doesn't exist yet
  /// (the paired device hasn't uploaded anything).
  Future<String?> downloadFile(String fileName) async {
    final fileId = await _findFile(fileName);
    if (fileId == null) return null;
    final res = await http.get(
      Uri.parse('$_baseUrl/files/$fileId?alt=media'),
      headers: _authHeader,
    );
    if (res.statusCode == 200) return utf8.decode(res.bodyBytes);
    if (res.statusCode == 404) return null;
    _fail('download', res);
  }

  // ── HELPERS ──────────────────────────────────────────────────────────────

  /// The Drive file id of `fileName` inside the sync folder, or null.
  Future<String?> _findFile(String fileName) async {
    final folderId = await getOrCreateFolder();
    final query = Uri.encodeQueryComponent(
        "name='$fileName' and '$folderId' in parents and trashed=false");
    final res = await http.get(
      Uri.parse('$_baseUrl/files?q=$query&fields=files(id,name)&spaces=drive'),
      headers: _jsonHeaders,
    );
    if (res.statusCode != 200) _fail('file lookup', res);
    final files = (jsonDecode(res.body)['files'] as List?) ?? const [];
    return files.isEmpty ? null : files.first['id'] as String;
  }

  /// Total bytes used by files in the sync folder (shown in sync settings).
  Future<int> folderStorageBytes() async {
    final folderId = await getOrCreateFolder();
    final query =
        Uri.encodeQueryComponent("'$folderId' in parents and trashed=false");
    final res = await http.get(
      Uri.parse('$_baseUrl/files?q=$query&fields=files(size)&spaces=drive'),
      headers: _jsonHeaders,
    );
    if (res.statusCode != 200) return 0;
    final files = (jsonDecode(res.body)['files'] as List?) ?? const [];
    var total = 0;
    for (final f in files) {
      total += int.tryParse((f['size'] as String?) ?? '0') ?? 0;
    }
    return total;
  }
}

/// Raised on any non-success Drive response. Carries the HTTP status so the
/// caller can treat 401 (token expired) differently from other failures.
class DriveException implements Exception {
  final String message;
  final int statusCode;
  const DriveException(this.message, this.statusCode);

  bool get isAuthError => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}
