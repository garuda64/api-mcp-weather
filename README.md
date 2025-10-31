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
