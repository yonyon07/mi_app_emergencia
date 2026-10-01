# Emergencia Conecta

Aplicación Flutter para reportar emergencias y conectarse a un backend Node.js local.

## Iniciar en la red local

El backend Node.js debe estar activo en la computadora mientras se usa la app.
Conecta la computadora y el teléfono a la misma red Wi-Fi.

Antes de probar, confirma:

- Node.js y npm están instalados.
- La IPv4 Wi-Fi del PC es `192.168.31.247` o la actualizarás en `API_BASE_URL`.

1. Desde la carpeta del proyecto, ejecuta `npm start` en PowerShell. Si es la
	 primera vez, ejecuta antes `npm install`.
2. Deja esa terminal abierta; el servidor debe indicar que está activo en el
	 puerto `3000`.
3. En el navegador del teléfono abre `http://192.168.31.247:3000/login`. Si ves
	 la página de inicio de sesión, el teléfono alcanza el servidor.
4. En otra terminal, inicia Flutter con `flutter run` y prueba el reporte.

El servidor escucha en las interfaces de red del PC. La URL predeterminada de
la app para un teléfono físico es `http://192.168.31.247:3000`; para el
emulador Android se usa `http://10.0.2.2:3000`.

## Si el teléfono no abre la página

- Confirma que `npm start` sigue ejecutándose y que ambos dispositivos están
	conectados a la misma Wi-Fi.
- En Windows, ejecuta `ipconfig` y busca la IPv4 del adaptador Wi-Fi. Si no es
	`192.168.31.247`, inicia Flutter con `flutter run --dart-define=API_BASE_URL=http://DIRECCION-IP:3000`.
- Si la página abre en el PC pero no en el teléfono, permite Node.js o las
	conexiones entrantes al puerto `3000` en el firewall de Windows.
- No uses `localhost` en el teléfono: esa dirección se refiere al propio
	teléfono, no a la computadora.
