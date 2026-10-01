// server.js
const express = require('express');
const bodyParser = require('body-parser');
const crypto = require('crypto');
const path = require('path');

// Crea el servidor HTTP que atiende la app móvil y el monitor web.
const app = express();
// Permite elegir otro puerto para pruebas sin cambiar el puerto normal 3000.
const PORT = Number(process.env.PORT || 3000);
// Credenciales del monitor; se pueden cambiar mediante variables de entorno.
const MONITOR_USER = process.env.MONITOR_USER || 'admin';
const MONITOR_PASSWORD = process.env.MONITOR_PASSWORD || 'admin';
// Clave que se usa para firmar las sesiones del monitor.
const SESSION_SECRET = process.env.SESSION_SECRET || crypto.randomBytes(32).toString('hex');
// Registros temporales del proceso: al reiniciar, emergencias y chats se vacían.
const emergencias = [];
const chatsPorEmergencia = new Map();
// Respuestas SSE abiertas para informar al monitor de alertas y mensajes nuevos.
const clientesEnVivo = new Set();

// Convierte cuerpos JSON entrantes en objetos disponibles en req.body.
app.use(bodyParser.json({ limit: '10mb' }));

// Envía un evento en vivo a cada monitor conectado y elimina conexiones cerradas.
function emitirEvento(evento) {
  for (const cliente of clientesEnVivo) {
    if (cliente.destroyed || cliente.writableEnded) {
      clientesEnVivo.delete(cliente);
      continue;
    }
    try {
      cliente.write(evento);
    } catch (error) {
      clientesEnVivo.delete(cliente);
      console.error('Se descartó una conexión SSE cerrada:', error.message);
    }
  }
}

// Crea un token firmado con vencimiento para mantener la sesión del operador.
function createSessionToken(username) {
  const payload = Buffer.from(JSON.stringify({ username, expiresAt: Date.now() + 8 * 60 * 60 * 1000 })).toString('base64url');
  const signature = crypto.createHmac('sha256', SESSION_SECRET).update(payload).digest('base64url');
  return `${payload}.${signature}`;
}

// Valida la firma, el usuario y la fecha de vencimiento de la cookie de sesión.
function isAuthenticated(req) {
  const token = req.headers.cookie?.match(/(?:^|; )monitor_session=([^;]+)/)?.[1];
  if (!token) return false;

  const [payload, signature] = token.split('.');
  if (!payload || !signature) return false;

  const expectedSignature = crypto.createHmac('sha256', SESSION_SECRET).update(payload).digest('base64url');
  if (signature.length !== expectedSignature.length ||
      !crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expectedSignature))) {
    return false;
  }

  try {
    const session = JSON.parse(Buffer.from(payload, 'base64url').toString());
    return session.username === MONITOR_USER && session.expiresAt > Date.now();
  } catch (_) {
    return false;
  }
}

// Sirve el formulario de inicio de sesión del monitor.
app.get('/login', (_req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'login.html'));
});

// Comprueba las credenciales del operador y crea su cookie de sesión.
app.post('/api/login', (req, res) => {
  if (!MONITOR_PASSWORD) {
    return res.status(503).json({ mensaje: 'Configura MONITOR_PASSWORD antes de iniciar el servidor.' });
  }

  const { usuario, password } = req.body;
  if (usuario !== MONITOR_USER || password !== MONITOR_PASSWORD) {
    return res.status(401).json({ mensaje: 'Usuario o contraseña incorrectos.' });
  }

  res.setHeader('Set-Cookie', `monitor_session=${createSessionToken(usuario)}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800`);
  return res.status(200).json({ mensaje: 'Inicio de sesión correcto.' });
});

// Invalida en el navegador la cookie de sesión del operador.
app.post('/api/logout', (_req, res) => {
  res.setHeader('Set-Cookie', 'monitor_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0');
  res.status(204).end();
});

// Deja pasar el reporte móvil y el chat; protege las demás rutas del monitor.
app.use((req, res, next) => {
  if (req.path === '/api/emergencia' || /^\/api\/emergencias\/\d+\/chat$/.test(req.path)) return next();
  if (isAuthenticated(req)) return next();
  if (req.path.startsWith('/api/')) return res.status(401).json({ mensaje: 'Inicio de sesión requerido.' });
  return res.redirect('/login');
});

// Publica los archivos HTML, CSS y recursos del monitor.
app.use(express.static(path.join(__dirname, 'public')));

// Mantiene una conexión SSE para enviar actualizaciones inmediatas al monitor.
app.get('/api/emergencias/en-vivo', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  res.write(`event: inicial\ndata: ${JSON.stringify(emergencias)}\n\n`);
  clientesEnVivo.add(res);

// Elimina la conexión en vivo cuando el navegador cierra el flujo.
  res.on('close', () => clientesEnVivo.delete(res));
  res.on('error', () => clientesEnVivo.delete(res));
});

// Devuelve los mensajes guardados para una emergencia existente.
app.get('/api/emergencias/:id/chat', (req, res) => {
  const emergencyId = Number(req.params.id);
  if (!emergencias.some((emergencia) => emergencia.id === emergencyId)) {
    return res.status(404).json({ mensaje: 'No se encontró esta emergencia.' });
  }
  return res.json(chatsPorEmergencia.get(emergencyId) || []);
});

// Valida, guarda y anuncia un mensaje nuevo asociado a una emergencia.
app.post('/api/emergencias/:id/chat', (req, res) => {
  const emergencyId = Number(req.params.id);
  if (!emergencias.some((emergencia) => emergencia.id === emergencyId)) {
    return res.status(404).json({ mensaje: 'No se encontró esta emergencia.' });
  }

  // Restringe el texto y permite mensajes que contengan solo un archivo.
  const body = req.body && typeof req.body === 'object' ? req.body : {};
  const texto = typeof body.texto === 'string' ? body.texto.trim() : '';
  const adjunto = body.adjunto && typeof body.adjunto === 'object'
    ? body.adjunto
    : null;
  const contenidoBase64 = adjunto?.contenidoBase64;
  if ((!texto && !adjunto) || texto.length > 1000) {
    return res.status(400).json({ mensaje: 'Escribe un mensaje o adjunta un archivo.' });
  }
  if (adjunto && (typeof contenidoBase64 !== 'string' || contenidoBase64.length > 8 * 1024 * 1024)) {
    return res.status(400).json({ mensaje: 'El archivo adjunto no es válido o es demasiado grande.' });
  }

  // Conserva como máximo 200 mensajes por conversación en memoria.
  const mensajes = chatsPorEmergencia.get(emergencyId) || [];
  const mensaje = {
    emergenciaId: emergencyId,
    usuario: String(body.usuario || 'Usuario').trim().slice(0, 60) || 'Usuario',
    texto,
    adjunto: adjunto
      ? {
          nombre: String(adjunto.nombre || 'archivo').slice(0, 120),
          tipo: adjunto.tipo === 'imagen' ? 'imagen' : 'documento',
          // Conserva el MIME del navegador para que el monitor abra cada archivo con su tipo correcto.
          mimeType: typeof adjunto.mimeType === 'string' ? adjunto.mimeType.slice(0, 100) : null,
          contenidoBase64,
        }
      : null,
    timestamp: new Date().toISOString(),
  };
  mensajes.push(mensaje);
  if (mensajes.length > 200) mensajes.shift();
  chatsPorEmergencia.set(emergencyId, mensajes);

  const evento = `event: chat\ndata: ${JSON.stringify(mensaje)}\n\n`;
  emitirEvento(evento);
  return res.status(201).json(mensaje);
});

// Ruta para recibir emergencias
// Recibe el reporte móvil, lo guarda y lo anuncia a los monitores conectados.
app.post('/api/emergencia', (req, res) => {
  const { latitud, longitud, usuario, dispositivo, timestamp } = req.body;
  const emergencia = {
    id: Date.now(),
    latitud,
    longitud,
    usuario: usuario || 'Usuario desconocido',
    dispositivo: dispositivo || 'Dispositivo desconocido',
    timestamp: timestamp || new Date().toISOString(),
  };

  emergencias.unshift(emergencia);
  if (emergencias.length > 100) emergencias.pop();

  const evento = `event: emergencia\ndata: ${JSON.stringify(emergencia)}\n\n`;
  emitirEvento(evento);

  res.status(200).send({ mensaje: 'Emergencia registrada en la página', emergenciaId: emergencia.id });
});

// Devuelve errores de rutas como JSON y registra los detalles en la consola.
app.use((error, req, res, next) => {
  console.error(`Error procesando ${req.method} ${req.path}:`, error);
  if (res.headersSent) return next(error);
  const status = Number.isInteger(error.status) ? error.status : 500;
  return res.status(status).json({
    mensaje: status >= 500 ? 'Error interno del servidor.' : error.message,
  });
});

// Escucha en todas las interfaces IPv4 para aceptar conexiones de la red local.
app.listen(PORT, '0.0.0.0', () => {
  console.log(`Servidor activo en el puerto ${PORT}; desde la red local usa http://<IP-del-PC>:${PORT}`);
});
