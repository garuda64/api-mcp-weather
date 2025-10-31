require "securerandom"

module Mcp
  class SseController < ApplicationController
    include ActionController::Live

    # GET /mcp/sse — open SSE stream for MCP legacy HTTP+SSE transport
    def stream
      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no" # for Nginx

      # Simple origin validation (MCP spec recommends validating Origin to mitigate DNS rebinding)
      origin = request.headers["Origin"]
      # Allow if no Origin or same host; extend as needed with allowlist
      if origin.present?
        host = request.base_url
        unless origin.start_with?(host)
          response.stream.write(": origin rejected\n\n")
          response.stream.close
          head :forbidden and return
        end
      end

      session_id = request.headers["Mcp-Session-Id"].presence || SecureRandom.uuid
      response.headers["Mcp-Session-Id"] = session_id

      Mcp::SessionRegistry.register(session_id, response.stream)

      # Announce session start
      sse_event(response.stream, "mcp-session", { sessionId: session_id })

      # Keep the connection alive
      begin
        loop do
          response.stream.write(": keepalive\n\n")
          sleep 20
        end
      rescue IOError
        # Client disconnected
      ensure
        Mcp::SessionRegistry.unregister(session_id)
        response.stream.close
      end
    end

    # POST /mcp/sse/messages — handle client->server JSON-RPC and push responses to SSE stream
    def messages
      session_id = request.headers["Mcp-Session-Id"].presence
      payload = request.raw_post.to_s

      begin
        msg = JSON.parse(payload)
      rescue JSON::ParserError
        render json: { error: { code: "invalid_json", message: "Body must be valid JSON" } }, status: :bad_request and return
      end

      if msg.is_a?(Array)
        # For simplicity, handle only single request for now
        render json: { error: { code: "batch_not_supported", message: "Batch requests not supported in this MVP" } }, status: :bad_request and return
      end

      unless msg.is_a?(Hash) && msg["jsonrpc"] == "2.0" && msg.key?("method")
        render json: { error: { code: "invalid_request", message: "Must be a JSON-RPC 2.0 request" } }, status: :bad_request and return
      end

      id = msg["id"]
      method = msg["method"].to_s
      params = msg["params"] || {}

      # Build response
      begin
        case method
        when "initialize"
          result = {
            server: { name: "api-mcp-weather", version: "1.0.0" },
            capabilities: { tools: { list: true, call: true } }
          }
          jsonrpc_response = { jsonrpc: "2.0", id: id, result: result }
        when "tools/list", "tools.list"
          tool = weather_tool_descriptor
          jsonrpc_response = { jsonrpc: "2.0", id: id, result: [tool] }
        when "tools/call", "tools.call"
          name = params["name"].to_s
          args = (params["arguments"] || {})
          unless name == "weather"
            raise StandardError.new("Unknown tool: #{name}")
          end

          content = call_weather_tool(args)
          jsonrpc_response = { jsonrpc: "2.0", id: id, result: { content: content } }
        else
          raise StandardError.new("Unknown method: #{method}")
        end
      rescue => e
        jsonrpc_response = {
          jsonrpc: "2.0",
          id: id,
          error: { code: -32000, message: e.message }
        }
      end

      if session_id && (stream = Mcp::SessionRegistry.fetch(session_id))
        begin
          sse_event(stream, "message", jsonrpc_response)
          head :accepted and return
        rescue IOError
          # Stream is gone; fall back to direct JSON response
        end
      end

      # Fallback: return JSON directly if no SSE session available
      render json: jsonrpc_response, status: :ok
    end

    private

    def sse_event(stream, event_name, payload)
      stream.write("event: #{event_name}\n")
      stream.write("data: #{payload.to_json}\n\n")
    end

    def weather_tool_descriptor
      {
        name: "weather",
        description: "Obtiene el clima actual desde OpenWeatherMap y devuelve un JSON normalizado.",
        inputSchema: {
          type: "object",
          properties: {
            apiKey: { type: "string", description: "API key de OpenWeatherMap" },
            prompt: { type: "string", description: "Texto opcional para ajustar el resumen" },
            city:   { type: "string", description: "Nombre de la ciudad" },
            lat:    { type: "number", description: "Latitud" },
            lon:    { type: "number", description: "Longitud" },
            units:  { type: "string", enum: ["metric", "imperial", "standard"], default: "metric" },
            lang:   { type: "string", default: "es" }
          },
          anyOf: [ { required: ["city"] }, { required: ["lat", "lon"] } ],
          required: ["apiKey"]
        }
      }
    end

    def call_weather_tool(args)
      api_key = args["apiKey"] || args["api_key"]
      prompt = args["prompt"]
      units  = (args["units"] || "metric").to_s
      lang   = (args["lang"] || "es").to_s
      city   = args["city"]
      lat    = args["lat"]
      lon    = args["lon"]

      raise StandardError.new("apiKey es requerido") unless api_key.present?
      unless city.present? || (lat.present? && lon.present?)
        raise StandardError.new("Debe enviar city o lat/lon")
      end

      service = OpenWeatherService.new(api_key: api_key)
      response = if city.present?
        service.current_by_city(city: city, units: units, lang: lang)
      else
        service.current_by_coords(lat: lat, lon: lon, units: units, lang: lang)
      end

      if response.code != 200
        raise StandardError.new((response.parsed_response["message"] rescue "Error consultando OpenWeatherMap"))
      end

      data = response.parsed_response

      # Pronóstico para calcular min/máx diario
      forecast_resp = if city.present?
        service.forecast_by_city(city: city, units: units, lang: lang)
      else
        service.forecast_by_coords(lat: lat, lon: lon, units: units, lang: lang)
      end

      daily_min = nil
      daily_max = nil
      daily_samples = 0
      forecast_date_local = nil
      if forecast_resp&.code == 200
        forecast = forecast_resp.parsed_response
        tz_offset = forecast.dig("city", "timezone") || data["timezone"] || 0
        today_local_date = (Time.now.utc + tz_offset).to_date
        list = forecast["list"] || []
        day_entries = list.select do |e|
          dt = e["dt"]
          ((Time.at(dt).utc + tz_offset).to_date) == today_local_date
        end
        daily_samples = day_entries.size
        forecast_date_local = today_local_date.to_s
        max_candidates = day_entries.map { |e| e.dig("main", "temp_max") || e.dig("main", "temp") }.compact
        min_candidates = day_entries.map { |e| e.dig("main", "temp_min") || e.dig("main", "temp") }.compact
        daily_max = max_candidates.max
        daily_min = min_candidates.min
      end

      normalized = normalize_for_ai(data, prompt: prompt, units: units, lang: lang,
                                    daily_min: daily_min, daily_max: daily_max,
                                    daily_samples: daily_samples, forecast_date_local: forecast_date_local)

      # Return MCP content array; include both JSON and a text summary for agent convenience
      [
        { type: "json", json: normalized },
        { type: "text", text: normalized[:textSummary] }
      ]
    end

    # Copia del normalizador de WeatherController
    def normalize_for_ai(data, prompt:, units:, lang:, daily_min: nil, daily_max: nil, daily_samples: 0, forecast_date_local: nil)
      main = data["main"] || {}
      wind = data["wind"] || {}
      clouds = data["clouds"] || {}
      weather0 = (data["weather"] || []).first || {}
      name = data["name"]
      country = data.dig("sys", "country")
      tz_offset = data["timezone"]

      units_tag = case units
      when "metric" then "C"
      when "imperial" then "F"
      else "K"
      end

      summary_text_parts = [
        "Clima actual en #{name}, #{country}: #{weather0["description"]}",
        "Temp: #{main["temp"]}°#{units_tag} (sensación #{main["feels_like"]})",
        "Máx: #{main["temp_max"]}°#{units_tag}, Mín: #{main["temp_min"]}°#{units_tag}",
        "Humedad: #{main["humidity"]}%, Viento: #{wind["speed"]} m/s, Nubes: #{clouds["all"]}%"
      ]
      if daily_min && daily_max
        summary_text_parts << "Máx día: #{daily_max}°#{units_tag}, Mín día: #{daily_min}°#{units_tag}"
      end
      summary_text = summary_text_parts.join('. ')

      prompt_text = prompt.present? ? "Prompt: #{prompt}. " : ""

      {
        schemaVersion: "1.0",
        provider: "openweathermap",
        query: {
          city: name,
          country: country,
          lat: data.dig("coord", "lat"),
          lon: data.dig("coord", "lon"),
          units: units,
          lang: lang,
          prompt: prompt
        },
        location: {
          name: name,
          country: country,
          lat: data.dig("coord", "lat"),
          lon: data.dig("coord", "lon"),
          timezoneOffsetSeconds: tz_offset
        },
        current: {
          conditionCode: weather0["id"],
          conditionText: weather0["main"],
          conditionDescription: weather0["description"],
          icon: weather0["icon"],
          temperature: main["temp"],
          feelsLike: main["feels_like"],
          maxTemperature: main["temp_max"],
          minTemperature: main["temp_min"],
          dayMaxTemperature: daily_max,
          dayMinTemperature: daily_min,
          pressure: main["pressure"],
          humidity: main["humidity"],
          visibilityMeters: data["visibility"],
          wind: {
            speedMetersPerSecond: wind["speed"],
            degrees: wind["deg"],
            gust: wind["gust"]
          },
          cloudsPercent: clouds["all"]
        },
        daily: {
          dateLocal: forecast_date_local,
          maxTemperature: daily_max,
          minTemperature: daily_min,
          samples: daily_samples
        },
        meta: {
          retrievedAt: Time.now.utc.iso8601,
          sourceUrl: "https://api.openweathermap.org/data/2.5/weather",
          units: units
        },
        aiContext: [
          { key: "weather.summary", value: summary_text },
          { key: "weather.condition", value: weather0["description"] },
          { key: "weather.temperature", value: main["temp"] },
          { key: "weather.tempMax", value: main["temp_max"] },
          { key: "weather.tempMin", value: main["temp_min"] },
          { key: "weather.dayTempMax", value: daily_max },
          { key: "weather.dayTempMin", value: daily_min }
        ],
        textSummary: "#{prompt_text}#{summary_text}"
      }
    end
  end
end