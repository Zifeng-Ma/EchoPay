import 'dart:async';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class BackendConfig {
  static String get baseUrl {
    final fromEnv = dotenv.isInitialized
        ? dotenv.env['BACKEND_URL']?.trim()
        : null;
    final raw = fromEnv == null || fromEnv.isEmpty
        ? 'http://localhost:8000'
        : fromEnv;
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  static Exception connectionException(Object error) {
    final url = baseUrl;
    final reason = error is TimeoutException
        ? 'the request timed out'
        : error is SocketException || error is http.ClientException
        ? 'the connection was refused'
        : error.toString();

    return Exception(
      'Could not reach the EchoPay backend at $url: $reason. '
      'Start the agent with `cd agent && uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000`, '
      'then make sure BACKEND_URL in app/.env points to this machine.',
    );
  }
}
