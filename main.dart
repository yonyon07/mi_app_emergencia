import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

// Permite cambiar el servidor al compilar con --dart-define=API_BASE_URL=... .
const _configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');
// Dirección predeterminada que permite al emulador Android llegar al equipo anfitrión.
const _emulatorApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:3000',
);
// Dirección efectiva usada por las solicitudes de emergencias y del chat.
String _apiBaseUrl = _emulatorApiBaseUrl;

/// Punto de entrada: inicia la aplicación Flutter.
void main() {
  runApp(const EmergenciaConectaApp());
}

/// Configura el nombre y la pantalla inicial de la aplicación.
class EmergenciaConectaApp extends StatelessWidget {
  const EmergenciaConectaApp({super.key});

  /// Construye el contenedor principal de Flutter.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Emergencia Conecta',
      home: const EmergenciaHomePage(),
    );
  }
}

/// Pantalla donde se identifica al usuario y se reporta su emergencia.
class EmergenciaHomePage extends StatefulWidget {
  const EmergenciaHomePage({super.key});

  /// Crea el estado que administra ubicación, usuario y emergencia más reciente.
  @override
  State<EmergenciaHomePage> createState() => _EmergenciaHomePageState();
}

class _EmergenciaHomePageState extends State<EmergenciaHomePage> {
  // Controla el nombre escrito por el usuario en el formulario.
  final _usuarioController = TextEditingController();
  // Nombre del teléfono que se adjunta a cada alerta.
  String _dispositivo = 'Cargando dispositivo...';
  // Identificador devuelto por el servidor para abrir el chat relacionado.
  int? _ultimaEmergenciaId;
  // Evita reportar antes de terminar la selección del nombre y dirección del dispositivo.
  late final Future<void> _deviceInfoReady;

  /// Obtiene el nombre del teléfono al crear la pantalla.
  @override
  void initState() {
    super.initState();
    _deviceInfoReady = _loadDeviceName();
  }

  /// Lee la información del Android y determina la dirección de servidor adecuada.
  Future<void> _loadDeviceName() async {
    String deviceName;
    try {
      final deviceInfo = await DeviceInfoPlugin().androidInfo;
      deviceName = '${deviceInfo.manufacturer} ${deviceInfo.model}'.trim();
      // En un teléfono físico se usa la IP LAN del PC; API_BASE_URL puede reemplazarla.
      if (_configuredApiBaseUrl.isEmpty && deviceInfo.isPhysicalDevice) {
        _apiBaseUrl = 'http://192.168.31.247:3000';
      }
    } catch (_) {
      deviceName = 'Dispositivo desconocido';
      if (_configuredApiBaseUrl.isEmpty) {
        _apiBaseUrl = 'http://192.168.31.247:3000';
      }
    }
    if (!mounted) return;
    setState(() {
      _dispositivo = deviceName;
    });
  }

  /// Valida nombre y permisos, obtiene GPS y registra la alerta en el backend.
  Future<void> _getLocation() async {
    await _deviceInfoReady;
    final usuario = _usuarioController.text.trim();
    if (usuario.isEmpty) {
      _showMessage('Escribe el nombre del usuario.');
      return;
    }

    // La ubicación requiere que el servicio del teléfono esté encendido.
    if (!await Geolocator.isLocationServiceEnabled()) {
      _showMessage('Activa el GPS para continuar.');
      return;
    }

    // Solicita permiso de ubicación solo cuando todavía no se ha concedido.
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _showMessage('Permiso de ubicación denegado.');
      return;
    }

    // Lee una posición precisa; si falla, avisa y no intenta registrar la alerta.
    late final Position position;
    // Envía al servidor los datos de usuario, dispositivo, coordenadas y hora.
    try {
      position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (_) {
      _showMessage('No se pudo obtener la ubicación del emulador.');
      return;
    }

    try {
      final response = await http
          .post(
            Uri.parse('$_apiBaseUrl/api/emergencia'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'latitud': position.latitude,
              'longitud': position.longitude,
              'usuario': usuario,
              'dispositivo': _dispositivo,
              'timestamp': DateTime.now().toIso8601String(),
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      // Guarda el ID para que el botón de chat abra la conversación correcta.
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final result = jsonDecode(response.body) as Map<String, dynamic>;
        final emergencyId = result['emergenciaId'];
        if (emergencyId is num) {
          setState(() => _ultimaEmergenciaId = emergencyId.toInt());
        }
      }
      _showMessage(
        response.statusCode >= 200 && response.statusCode < 300
            ? 'Emergencia reportada correctamente.'
            : 'El servidor rechazo la emergencia (${response.statusCode}).',
      );
    } catch (_) {
      _showMessage(
        'No se pudo conectar con $_apiBaseUrl. Verifica que el servidor esté activo y que el teléfono esté en la misma Wi-Fi.',
      );
    }
  }

  /// Muestra avisos breves en la parte inferior de la pantalla.
  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Abre la conversación asociada a la última alerta aceptada por el servidor.
  void _abrirChat() {
    final emergencyId = _ultimaEmergenciaId;
    if (emergencyId == null) return;
    final usuario = _usuarioController.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          emergencyId: emergencyId,
          usuario: usuario.isEmpty ? 'Usuario' : usuario,
        ),
      ),
    );
  }

  /// Libera el controlador del campo de usuario al cerrar la pantalla.
  @override
  void dispose() {
    _usuarioController.dispose();
    super.dispose();
  }

  /// Dibuja el formulario y sus acciones principales.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Emergencia Conecta'),
        backgroundColor: Colors.redAccent,
        actions: [
          IconButton(
            tooltip: 'Abrir chat de la última emergencia',
            onPressed: _ultimaEmergenciaId == null ? null : _abrirChat,
            icon: const Icon(Icons.chat_bubble_outline),
          ),
        ],
      ),
      // Permite desplazar el formulario cuando el teclado reduce la altura disponible.
      body: SingleChildScrollView(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Campo donde la persona escribe el nombre que aparecerá en la alerta.
                TextField(
                  controller: _usuarioController,
                  decoration: const InputDecoration(
                    labelText: 'Nombre del usuario',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.done,
                ),
                const SizedBox(height: 20),
                // Solicita GPS y reporta la emergencia al tocar este botón.
                ElevatedButton.icon(
                  onPressed: _getLocation,
                  icon: const Icon(Icons.emergency),
                  label: const Text('Reportar emergencia'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 40,
                      vertical: 20,
                    ),
                    textStyle: const TextStyle(fontSize: 20),
                  ),
                ),
                const SizedBox(height: 20), // espacio entre botón y texto
                // Para crear párrafos separados, usa un Text por párrafo y un SizedBox entre ellos.
                const Text(
                  'Creado Por Miguel Leal.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                    fontFamily: 'Times New Roman',
                  ),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 20), // espacio entre botón y texto
                const Text(
                  'Recuerde que usar esta aplicación no reemplaza la atención de los servicios de emergencia.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                    fontFamily: 'Times New Roman',
                  ),
                  textAlign: TextAlign.right,
                ),

                const SizedBox(height: 20), // espacio entre botón y texto
                const Text(
                  'En caso que no reciba respuesta, llame al 911 o al número local de emergencias.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                    fontFamily: 'Times New Roman',
                  ),
                  textAlign: TextAlign.right,
                ),

                const SizedBox(height: 20), // espacio entre botón y texto
                const Text(
                  'Recuerde que usar alerta falsa puede tener consecuencias legales.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                    fontFamily: 'Times New Roman',
                  ),
                  textAlign: TextAlign.right,
                ),

                const SizedBox(height: 20), // espacio entre botón y texto
                const Text(
                  'Solo use esta aplicación para emergencias reales.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                    fontFamily: 'Times New Roman',
                  ),
                  textAlign: TextAlign.right,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pantalla de conversación vinculada a una emergencia específica.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.emergencyId, required this.usuario});

  // ID que el backend usa para separar esta conversación de las demás.
  final int emergencyId;
  // Nombre que se adjunta a los mensajes enviados desde este teléfono.
  final String usuario;

  /// Crea el estado local para cargar, enviar y actualizar los mensajes.
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  // Mensajes recibidos del servidor y mostrados en la lista.
  final List<Map<String, dynamic>> _mensajes = [];
  // Controla el texto que se va a enviar.
  final TextEditingController _controller = TextEditingController();
  // Consulta periódica para mostrar mensajes nuevos sin cerrar la pantalla.
  Timer? _actualizador;
  // Texto de error que se presenta al fallar una operación del chat.
  String? _error;
  // Impide enviar más de una solicitud al mismo tiempo.
  bool _enviando = false;
  // Archivo seleccionado para adjuntarlo al próximo mensaje.
  Uint8List? _adjuntoBytes;
  String? _adjuntoNombre;
  String? _adjuntoTipo;

  // URL del chat de la emergencia seleccionada.
  String get _chatUrl =>
      '$_apiBaseUrl/api/emergencias/${widget.emergencyId}/chat';

  /// Convierte la respuesta de error del servidor en un texto comprensible.
  String _errorDeRespuesta(http.Response response, String fallback) {
    try {
      final body = jsonDecode(response.body);
      final mensaje = body is Map<String, dynamic> ? body['mensaje'] : null;
      if (mensaje is String && mensaje.isNotEmpty) return mensaje;
    } catch (_) {
      // Usa el estado HTTP cuando el servidor no devuelve JSON.
    }
    if (response.statusCode == 404) {
      return 'La emergencia ya no está registrada. Reporta una nueva emergencia.';
    }
    return '$fallback (HTTP ${response.statusCode})';
  }

  /// Carga el historial al abrir el chat y programa su actualización periódica.
  @override
  void initState() {
    super.initState();
    _cargarMensajes();
    _actualizador = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _cargarMensajes(mostrarError: false),
    );
  }

  /// Obtiene los mensajes actuales de la emergencia desde el backend.
  Future<void> _cargarMensajes({bool mostrarError = true}) async {
    try {
      final response = await http.get(Uri.parse(_chatUrl));
      if (!mounted) return;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        setState(() {
          _error = _errorDeRespuesta(response, 'No se pudo cargar el chat');
        });
        return;
      }
      final mensajes = (jsonDecode(response.body) as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final huboCambios =
          _mensajes.length != mensajes.length ||
          (_mensajes.isNotEmpty &&
              mensajes.isNotEmpty &&
              _mensajes.last['timestamp'] != mensajes.last['timestamp']);
      // Evita reconstruir las imágenes en cada consulta si el chat no cambió.
      if (!huboCambios && _error == null) return;
      setState(() {
        if (huboCambios) {
          _mensajes
            ..clear()
            ..addAll(mensajes);
        }
        _error = null;
      });
    } catch (_) {
      if (!mounted || !mostrarError) return;
      setState(() => _error = 'Error de conexión al cargar el chat.');
    }
  }

  /// Envía el texto escrito y vuelve a cargar el historial si el servidor lo acepta.
  Future<void> _enviarMensaje() async {
    final texto = _controller.text.trim();
    if ((texto.isEmpty && _adjuntoBytes == null) || _enviando) return;
    setState(() {
      _enviando = true;
      _error = null;
    });
    try {
      final adjunto = _adjuntoBytes == null
          ? null
          : {
              'nombre': _adjuntoNombre ?? 'archivo',
              'tipo': _adjuntoTipo ?? 'documento',
              'contenidoBase64': base64Encode(_adjuntoBytes!),
            };
      final response = await http.post(
        Uri.parse(_chatUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'usuario': widget.usuario,
          'texto': texto,
          'adjunto': adjunto,
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        setState(() {
          _error = _errorDeRespuesta(response, 'No se pudo enviar el mensaje');
        });
        return;
      }
      _controller.clear();
      setState(() {
        _adjuntoBytes = null;
        _adjuntoNombre = null;
        _adjuntoTipo = null;
      });
      await _cargarMensajes();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Error de conexión al enviar el mensaje.');
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  /// Abre la cámara del dispositivo para seleccionar una imagen.
  Future<void> _abrirCamara() async {
    final imagen = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 75,
      maxWidth: 1280,
    );
    if (imagen == null || !mounted) return;
    final bytes = await imagen.readAsBytes();
    if (!mounted) return;
    setState(() {
      _adjuntoBytes = bytes;
      _adjuntoNombre = imagen.name;
      _adjuntoTipo = 'imagen';
    });
  }

  /// Abre el selector del dispositivo para elegir un archivo.
  Future<void> _abrirArchivos() async {
    final resultado = await FilePicker.pickFiles();
    if (resultado.isEmpty || !mounted) return;
    final archivo = resultado.first;
    final bytes = await archivo.readAsBytes();
    if (!mounted) return;
    setState(() {
      _adjuntoBytes = bytes;
      _adjuntoNombre = archivo.name;
      _adjuntoTipo = 'documento';
    });
  }

  /// Muestra la imagen o el nombre del documento guardado en un mensaje.
  Widget _verAdjunto(Map<String, dynamic> mensaje) {
    final adjunto = mensaje['adjunto'];
    if (adjunto is! Map<String, dynamic>) return const SizedBox.shrink();
    final contenido = adjunto['contenidoBase64'];
    final nombre = adjunto['nombre'] as String? ?? 'archivo';
    if (adjunto['tipo'] == 'imagen' && contenido is String) {
      try {
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Image.memory(
            base64Decode(contenido),
            height: 180,
            width: 240,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, error, stackTrace) =>
                const Text('Imagen no disponible'),
          ),
        );
      } catch (_) {
        return const Text('Imagen no disponible');
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined),
          const SizedBox(width: 8),
          Flexible(child: Text(nombre)),
        ],
      ),
    );
  }

  /// Dibuja los mensajes, el campo de escritura y cualquier error actual.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Chat de Emergencia")),
      body: Column(
        children: [
          // Lista desplazable con texto y autor de cada mensaje del chat.
          Expanded(
            child: ListView.builder(
              itemCount: _mensajes.length,
              itemBuilder: (context, index) {
                final mensaje = _mensajes[index];
                final texto = mensaje['texto'] as String? ?? '';
                return ListTile(
                  title: Text(mensaje['usuario'] as String? ?? 'usuario'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (texto.isNotEmpty) Text(texto),
                      _verAdjunto(mensaje),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_adjuntoBytes != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Icon(Icons.attachment),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_adjuntoNombre ?? 'Archivo adjunto')),
                  IconButton(
                    tooltip: 'Quitar archivo',
                    onPressed: () => setState(() {
                      _adjuntoBytes = null;
                      _adjuntoNombre = null;
                      _adjuntoTipo = null;
                    }),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          // Mantiene adjuntos y envío junto al campo para dejar más espacio visible al chat.
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Tomar foto',
                  icon: const Icon(Icons.camera_alt, color: Colors.blue),
                  onPressed: _enviando ? null : _abrirCamara,
                ),
                IconButton(
                  tooltip: 'Adjuntar archivo',
                  icon: const Icon(Icons.attach_file, color: Colors.green),
                  onPressed: _enviando ? null : _abrirArchivos,
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: "Escribe tu mensaje...",
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _enviarMensaje(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _enviando ? null : _enviarMensaje,
                ),
              ],
            ),
          ),
          // Muestra errores de conexión o rechazo del servidor sin cerrar el chat.
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
    );
  }

  /// Detiene la consulta periódica y libera el controlador al salir del chat.
  @override
  void dispose() {
    _actualizador?.cancel();
    _controller.dispose();
    super.dispose();
  }
}
