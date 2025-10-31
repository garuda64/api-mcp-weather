# API MCP Weather (Rails)

API en Rails enfocada en MCP que consulta OpenWeatherMap usando la `apiKey` enviada y opcionalmente un `prompt`, devolviendo una respuesta JSON normalizada, apta para modelos de IA.

## Requisitos
- Ruby 3.3 (en contenedor se usa la versión definida en `Dockerfile`).
- Bundler.
- Docker opcional para evitar problemas de gems en Windows.

## Puesta en marcha

### Opción A: Docker (recomendada en Windows)
1. Construir la imagen:
   - `docker build -t api_mcp_weather .`
2. Ejecutar el contenedor:
   - `docker run -d -p 3000:80 --name api_mcp_weather api_mcp_weather`
3. Probar salud:
   - `curl http://localhost:3000/up`

### Producción: RAILS_MASTER_KEY
En producción, Rails necesita descifrar `config/credentials.yml.enc` para obtener `secret_key_base`. Debes proporcionar la clave maestra vía `RAILS_MASTER_KEY` (contenido de `config/master.key`).

- PowerShell (Windows):
  - Cargar la clave maestra en la sesión:
    - ``$env:RAILS_MASTER_KEY = (Get-Content -Raw .\config\master.key)``
  - Ejecutar el contenedor en producción:
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
  - Define `RAILS_MASTER_KEY` en tu `.env` o gestor de secretos de la plataforma.

Si no cuentas con `config/master.key`, genera credentials y clave maestra:
- `bin/rails credentials:edit` (en tu máquina de desarrollo) creará `config/master.key` y actualizará `config/credentials.yml.enc` con `secret_key_base`.
- Nunca publiques `config/master.key` ni la hornees en la imagen; pásala como variable/secreto en producción.

### Opción B: Local (si bundler/gems están OK)
1. Instalar dependencias:
   - `bundle install`
2. Levantar servidor:
   - `bin/rails server`

## Endpoint MCP

- Método: `POST`
- Ruta: `/mcp/weather`
- Cuerpo (JSON):
```
{
  "apiKey": "<tu_api_key_de_openweathermap>",
  "prompt": "opcional, texto libre",
  "city": "Madrid",            // alternativa: usar lat/lon
  "lat": 40.4168,
  "lon": -3.7038,
  "units": "metric",           // opciones: metric | imperial | standard
  "lang": "es"                 // por defecto 'es'
}
```

### Respuesta
- JSON normalizado con campos pensados para consumo por LLMs:
  - `schemaVersion`, `provider`, `query`, `location`
  - `current` (temperatura, sensación, humedad, presión, viento, nubes)
  - `meta` (fuente, unidades, timestamp)
  - `aiContext` (pares clave/valor útiles)
  - `textSummary` (resumen determinístico, opcionalmente usando el `prompt`)

### Ejemplo de llamada

```
curl -X POST http://localhost:3000/mcp/weather \
  -H "Content-Type: application/json" \
  -d '{
    "apiKey":"<API_KEY>",
    "city":"Buenos Aires",
    "prompt":"dame resumen breve"
  }'
```

## Notas
- Si prefieres no enviar `city`, usa `lat` y `lon`.
- El `prompt` no invoca ningún modelo; solo ajusta el `textSummary` y se retorna como metadato.
- CORS está habilitado para facilitar consumo desde clientes MCP y frontends.
