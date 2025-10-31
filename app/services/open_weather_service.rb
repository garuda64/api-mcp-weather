require "httparty"

class OpenWeatherService
  include HTTParty
  base_uri "https://api.openweathermap.org/data/2.5"

  def initialize(api_key:)
    @api_key = api_key
  end

  def current_by_city(city:, units: "metric", lang: "es")
    query = { q: city, appid: @api_key, units: units, lang: lang }
    self.class.get("/weather", query: query)
  end

  def current_by_coords(lat:, lon:, units: "metric", lang: "es")
    query = { lat: lat, lon: lon, appid: @api_key, units: units, lang: lang }
    self.class.get("/weather", query: query)
  end

  def forecast_by_city(city:, units: "metric", lang: "es")
    query = { q: city, appid: @api_key, units: units, lang: lang }
    self.class.get("/forecast", query: query)
  end

  def forecast_by_coords(lat:, lon:, units: "metric", lang: "es")
    query = { lat: lat, lon: lon, appid: @api_key, units: units, lang: lang }
    self.class.get("/forecast", query: query)
  end
end