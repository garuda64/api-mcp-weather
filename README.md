# MCP Time Server (Rails)

Servidor MCP mínimo compatible con transporte HTTP+SSE y una herramienta `get_utc_time` que devuelve la hora actual en UTC.

## Requisitos
- Ruby 3.3 (la imagen usa la versión definida en `Dockerfile`).
- Bundler.
- Docker opcional (recomendado en Windows).

## Puesta en marcha

### Opción A: Docker (recomendada)
1. Construir la imagen:
   - `docker build -t api_mcp_weather .`
2. Ejecutar el contenedor:
   - `docker run -d -p 3000:80 --name api_mcp_weather api_mcp_weather`
3. Probar salud:
   - `curl http://localhost:3000/up`

### Producción: RAILS_MASTER_KEY
Rails en producción necesita descifrar `config/credentials.yml.enc` para obtener `secret_key_base`. Proporciona la clave maestra vía `RAILS_MASTER_KEY` (contenido de `config/master.key`).

- PowerShell (Windows):
  - ``$env:RAILS_MASTER_KEY = (Get-Content -Raw .\config\master.key)``
  - ``docker run -d -p 80:80 --name api_mcp_weather -e RAILS_MASTER_KEY=$env:RAILS_MASTER_KEY api_mcp_weather``
- Linux/macOS:
  - ``docker run -d -p 80:80 --name api_mcp_weather -e RAILS_MASTER_KEY="$(cat config/master.key)" api_mcp_weather``
- Docker Compose (ejemplo):
```
services:
  api:
    image: api_mcp_weather
    ports:
      - "80:80"
    environment:
      RAILS_MASTER_KEY: ${RAILS_MASTER_KEY}
```

## MCP vía HTTP+SSE

- Endpoint SSE (GET): `GET /mcp`
  - Devuelve `text/event-stream` y mantiene la conexión abierta.
  - Envía keepalive `: ping` cada 15 segundos.
  - Incluye `Mcp-Session-Id` en la respuesta; úsalo en los `POST`.
- Mensajes (POST): `POST /mcp/messages`
  - Recibe solicitudes JSON-RPC 2.0: `initialize`, `tools/list`, `tools/call`.
  - Con `Mcp-Session-Id` en el header, responde vía SSE y retorna `202 Accepted`.
  - Sin SSE, retorna la respuesta JSON directamente con `200 OK`.

### Herramienta disponible
- `get_utc_time`: devuelve la hora actual en UTC (ISO 8601).
  - `inputSchema`: objeto vacío.
  - Respuesta de `tools/call` (contenido):
    - `text`: `"<ISO8601>"`.

## Ejemplos

### 1) Abrir el stream SSE
```
curl -i -N http://localhost:3000/mcp
```
Copiar el `Mcp-Session-Id` del header.

### 2) Inicializar y listar herramientas (vía SSE)
```
curl -X POST http://localhost:3000/mcp/messages \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SID>" \
  -d '{"jsonrpc":"2.0","id":"1","method":"initialize"}'

curl -X POST http://localhost:3000/mcp/messages \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SID>" \
  -d '{"jsonrpc":"2.0","id":"2","method":"tools/list"}'
```

### 3) Llamar la herramienta `get_utc_time` (vía SSE)
```
curl -X POST http://localhost:3000/mcp/messages \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: <SID>" \
  -d '{"jsonrpc":"2.0","id":"3","method":"tools/call","params":{"name":"get_utc_time","arguments":{}}}'
```

### 4) Fallback JSON (sin SSE)
```
curl -X POST http://localhost:3000/mcp/messages \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"A","method":"initialize"}'

curl -X POST http://localhost:3000/mcp/messages \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"B","method":"tools/list"}'

curl -X POST http://localhost:3000/mcp/messages \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"C","method":"tools/call","params":{"name":"get_utc_time","arguments":{}}}'
```

## n8n (MCP Client Tool)
- Campo “SSE Endpoint”: `http://localhost:3000/mcp`.
- El cliente usará `Mcp-Session-Id` del stream y enviará `POST` a `/mcp/messages`.
- La herramienta `get_utc_time` no requiere credenciales.

## Seguridad
- Considera validar `Origin` y añadir autenticación si expones públicamente.
- Este servidor mantiene sesiones en memoria (no apto para múltiples procesos sin un registro compartido).
