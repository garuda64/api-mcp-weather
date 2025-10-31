module Mcp
  class WeatherController < ApplicationController
    def create
      api_key = params[:apiKey] || params[:api_key]
      prompt = params[:prompt]
      units = (params[:units] || "metric").to_s
      lang = (params[:lang] || "es").to_s
      city = params[:city]
      lat = params[:lat]
      lon = params[:lon]

      unless api_key.present?
        return render json: { error: { code: "missing_api_key", message: "apiKey es requerido" } }, status: :bad_request
      end

      unless city.present? || (lat.present? && lon.present?)
        return render json: { error: { code: "missing_location", message: "Debe enviar city o lat/lon" } }, status: :bad_request
      end

      service = OpenWeatherService.new(api_key: api_key)
      response = if city.present?
        service.current_by_city(city: city, units: units, lang: lang)
      else
        service.current_by_coords(lat: lat, lon: lon, units: units, lang: lang)
      end

      if response.code != 200
        return render json: {
          error: { code: response.code, message: (response.parsed_response["message"] rescue "Error consultando OpenWeatherMap") },
          provider: "openweathermap",
          meta: { source: (response.request.last_uri.to_s rescue "https://api.openweathermap.org"), retrievedAt: Time.now.utc.iso8601 }
        }, status: :bad_gateway
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

      render json: normalize_for_ai(data, prompt: prompt, units: units, lang: lang, daily_min: daily_min, daily_max: daily_max, daily_samples: daily_samples, forecast_date_local: forecast_date_local), status: :ok
    end

    private

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