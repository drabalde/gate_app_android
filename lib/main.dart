import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const TuyaLampApp());
}

class TuyaLampApp extends StatelessWidget {
  const TuyaLampApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Controle de Portão',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const ConfigPage(),
    );
  }
}

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class GateControlPage extends StatefulWidget {
  const GateControlPage({super.key});

  @override
  State<GateControlPage> createState() => _GateControlPageState();
}

class _GateControlPageState extends State<GateControlPage> {
  String? clientId;
  String? clientSecret;
  String? deviceId;
  double pulseDuration = 1.0;
  String? accessToken;
  int? tokenExpiry;
  bool isLoading = false;
  bool? isOn;

  @override
  void initState() {
    super.initState();
    _loadConfigAndToken();
  }

  Future<void> _loadConfigAndToken() async {
    final prefs = await SharedPreferences.getInstance();
    clientId = prefs.getString('client_id');
    clientSecret = prefs.getString('client_secret');
    deviceId = prefs.getString('device_id');
    pulseDuration = (prefs.getDouble('pulse') ?? 1.0);
    accessToken = prefs.getString('access_token');
    tokenExpiry = prefs.getInt('token_expiry');
    await _ensureValidToken();
    await getDeviceStatus();
  }

  Future<void> _ensureValidToken() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (accessToken == null || tokenExpiry == null || now >= tokenExpiry!) {
      await _getAccessToken();
    }
  }

  String sha256Hash(String data) {
    return sha256.convert(utf8.encode(data)).toString();
  }

  String generateSign(String payload, String secret) {
    final hmacSha256 = Hmac(sha256, utf8.encode(secret));
    final digest = hmacSha256.convert(utf8.encode(payload));
    return digest.toString().toUpperCase();
  }

  Future<void> _getAccessToken() async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final nonce = const Uuid().v4();
      final contentSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
      final uriPath = "/v1.0/token?grant_type=1";
      final stringToSign = "GET\n$contentSHA256\n\n$uriPath";
      final payload = clientId! + timestamp + nonce + stringToSign;
      final sign = generateSign(payload, clientSecret!);

      final response = await http.get(
        Uri.parse('https://openapi.tuyaus.com/v1.0/token?grant_type=1'),
        headers: {
          'client_id': clientId!,
          'sign': sign,
          't': timestamp,
          'sign_method': 'HMAC-SHA256',
          'nonce': nonce,
        },
      );

      final data = jsonDecode(response.body);
      if (data['success'] == true) {
        final prefs = await SharedPreferences.getInstance();
        final expiresIn = (data['result']['expire_time'] ?? 7200 * 1000);
        final expiryTime = DateTime.now().millisecondsSinceEpoch + expiresIn.toInt();
        setState(() {
          accessToken = data['result']['access_token'];
          tokenExpiry = expiryTime.toInt();
        });
        await prefs.setString('access_token', accessToken!);
        await prefs.setInt('token_expiry', tokenExpiry!);
      } else {
        _showError(data['msg'] ?? 'Erro desconhecido');
      }
    } catch (e) {
      _showError('Erro ao obter token: $e');
    }
  }

  Future<void> getDeviceStatus() async {
    if (accessToken == null || deviceId == null) return;
    await _ensureValidToken();
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final nonce = const Uuid().v4();
      final uriPath = "/v1.0/iot-03/devices/$deviceId/status";
      final stringToSign = "GET\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n\n$uriPath";
      final payload = clientId! + accessToken! + timestamp + nonce + stringToSign;
      final sign = generateSign(payload, clientSecret!);
      final response = await http.get(
        Uri.parse('https://openapi.tuyaus.com$uriPath'),
        headers: {
          'client_id': clientId!,
          'access_token': accessToken!,
          'sign': sign,
          'sign_method': 'HMAC-SHA256',
          't': timestamp,
          'nonce': nonce,
        },
      );

      final data = jsonDecode(response.body);
      if (data['success'] == true) {
        final statusList = data['result'] as List<dynamic>;
        final switchStatus = statusList.firstWhere(
          (e) => e['code'] == 'switch_1',
          orElse: () => null,
        );
        setState(() => isOn = switchStatus?['value']);
      } else {
        _showError(data['msg'] ?? 'Erro ao obter status');
      }
    } catch (e) {
      _showError('Erro de conexão ao obter status: $e');
    }
  }

  Future<void> sendCommand(bool turnOn) async {
    await _ensureValidToken();
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final nonce = const Uuid().v4();
      final uriPath = '/v1.0/iot-03/devices/$deviceId/commands';
      final url = 'https://openapi.tuyaus.com$uriPath';

      final commandBody = jsonEncode({
        "commands": [
          {"code": "switch_1", "value": turnOn}
        ]
      });

      final contentSha256 = sha256Hash(commandBody);
      final stringToSign = "POST\n$contentSha256\n\n$uriPath";
      final signPayload = clientId! + accessToken! + timestamp + nonce + stringToSign;
      final signature = generateSign(signPayload, clientSecret!);

      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'client_id': clientId!,
          'access_token': accessToken!,
          'sign': signature,
          'sign_method': 'HMAC-SHA256',
          't': timestamp,
          'nonce': nonce,
        },
        body: commandBody,
      );

      final data = jsonDecode(response.body);
      if (data['success'] != true) {
        _showError(data['msg'] ?? 'Erro ao enviar comando');
      }
    } catch (e) {
      _showError('Erro ao enviar comando: $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> pulseGate() async {
    if (accessToken == null) return;
    setState(() => isLoading = true);
    await sendCommand(true);
    await Future.delayed(Duration(milliseconds: (pulseDuration * 1000).toInt()));
    await sendCommand(false);
    await getDeviceStatus();
    setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    Color statusColor;
    String statusText;
    if (isOn == null) {
      statusColor = Colors.grey;
      statusText = 'Desconhecido';
    } else if (isOn == true) {
      statusColor = Colors.green;
      statusText = 'Ligado';
    } else {
      statusColor = Colors.red;
      statusText = 'Desligado';
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A237E), Color(0xFF7986CB)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(13),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(backgroundColor: statusColor, radius: 8),
                      const SizedBox(width: 8),
                      Text('Status: $statusText'),
                    ],
                  ),
                ),
                const SizedBox(height: 30),
                Text('Tempo do Pulso: ${pulseDuration.toStringAsFixed(1)} segundos', style: const TextStyle(color: Colors.white)),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    backgroundColor: Colors.indigo,
                  ),
                  onPressed: isLoading ? null : pulseGate,
                  child: isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Acionar', style: TextStyle(fontSize: 16, color: Colors.white)),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: isLoading ? null : getDeviceStatus,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Atualizar Status'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                  ),
                ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const ConfigPage()),
                  ),
                  child: const Text('Alterar configurações', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfigPageState extends State<ConfigPage> {
  final _formKey = GlobalKey<FormState>();
  final _clientIdController = TextEditingController();
  final _clientSecretController = TextEditingController();
  final _deviceIdController = TextEditingController();
  final _pulseController = TextEditingController(text: '1');
  bool isSaving = false;
  bool canEditCredentials = false;
  bool _showClientId = false;
  bool _showClientSecret = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _clientIdController.text = prefs.getString('client_id') ?? '';
    _clientSecretController.text = prefs.getString('client_secret') ?? '';
    _deviceIdController.text = prefs.getString('device_id') ?? '';
    _pulseController.text = prefs.get('pulse') is int
      ? (prefs.getInt('pulse') ?? 1).toStringAsFixed(1)
      : (prefs.getDouble('pulse') ?? 1.0).toStringAsFixed(1);
  }

  Future<void> _saveConfig() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => isSaving = true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('client_id', _clientIdController.text);
    await prefs.setString('client_secret', _clientSecretController.text);
    await prefs.setString('device_id', _deviceIdController.text);
    await prefs.setDouble('pulse', double.parse(_pulseController.text));

    if (!mounted) return;
    await Future.delayed(const Duration(milliseconds: 100)); // pequena espera
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const GateControlPage()),
      );
    }
  }

  void _toggleEdit() {
    setState(() => canEditCredentials = !canEditCredentials);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configurar Portão')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Credenciais'),
                  TextButton(
                    onPressed: _toggleEdit,
                    child: Text(canEditCredentials ? 'Bloquear' : 'Editar'),
                  )
                ],
              ),
              TextFormField(
                controller: _clientIdController,
                decoration: InputDecoration(
                  labelText: 'Client ID',
                  suffixIcon: IconButton(
                    icon: Icon(_showClientId ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showClientId = !_showClientId),
                  ),
                ),
                enabled: canEditCredentials,
                obscureText: !_showClientId,
                validator: (v) => v == null || v.isEmpty ? 'Obrigatório' : null,
              ),
              TextFormField(
                controller: _clientSecretController,
                decoration: InputDecoration(
                  labelText: 'Client Secret',
                  suffixIcon: IconButton(
                    icon: Icon(_showClientSecret ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showClientSecret = !_showClientSecret),
                  ),
                ),
                enabled: canEditCredentials,
                obscureText: !_showClientSecret,
                validator: (v) => v == null || v.isEmpty ? 'Obrigatório' : null,
              ),
              const SizedBox(height: 10),
              const Divider(),
              TextFormField(
                controller: _deviceIdController,
                decoration: const InputDecoration(labelText: 'Device ID'),
                validator: (v) => v == null || v.isEmpty ? 'Obrigatório' : null,
              ),
              TextFormField(
                controller: _pulseController,
                decoration: const InputDecoration(labelText: 'Tempo do pulso (0.5 a 10 segundos)'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  final val = double.tryParse(v ?? '');
                  if (val == null || val < 0.5 || val > 10) {
                    return 'Informe um número entre 0.5 e 10';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: isSaving ? null : _saveConfig,
                child: isSaving ? const CircularProgressIndicator() : const Text('Salvar e Ir para Controle'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}