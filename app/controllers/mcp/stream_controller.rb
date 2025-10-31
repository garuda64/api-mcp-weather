require "securerandom"

module Mcp
  class StreamController < ApplicationController
    include ActionController::Live

    # GET /mcp/stream — open HTTP streaming (NDJSON) transport
    def stream
      response.headers["Content-Type"] = "application/x-ndjson"
      response.headers["Cache-Control"] = "no-cache"
      response.headers["X-Accel-Buffering"] = "no" # for Nginx

      origin = request.headers["Origin"]
      if origin.present?
        host = request.base_url
        unless origin.start_with?(host)
          write_json_line(response.stream, { event: "origin-rejected" })
          response.stream.close
          head :forbidden and return
        end
      end

      session_id = request.headers["Mcp-Session-Id"].presence || SecureRandom.uuid
      response.headers["Mcp-Session-Id"] = session_id

      Mcp::SessionRegistry.register(session_id, response.stream)

      # Announce session start
      write_json_line(response.stream, { event: "mcp-session", sessionId: session_id })

      # Keep the connection alive
      begin
        loop do
          write_json_line(response.stream, { event: "keepalive", ts: Time.now.utc.iso8601 })
          sleep 20
        end
      rescue IOError
        # Client disconnected
      ensure
        Mcp::SessionRegistry.unregister(session_id)
        response.stream.close
      end
    end

    # POST /mcp/stream/messages — handle JSON-RPC and push responses to stream
    def messages
      session_id = request.headers["Mcp-Session-Id"].presence
      payload = request.raw_post.to_s

      begin
        msg = JSON.parse(payload)
      rescue JSON::ParserError
        render json: { error: { code: "invalid_json", message: "Body must be valid JSON" } }, status: :bad_request and return
      end

      if msg.is_a?(Array)
        render json: { error: { code: "batch_not_supported", message: "Batch requests not supported in this server" } }, status: :bad_request and return
      end

      unless msg.is_a?(Hash) && msg["jsonrpc"] == "2.0" && msg.key?("method")
        render json: { error: { code: "invalid_request", message: "Must be a JSON-RPC 2.0 request" } }, status: :bad_request and return
      end

      id = msg["id"]
      method = msg["method"].to_s
      params = msg["params"] || {}

      begin
        case method
        when "initialize"
          result = {
            server: { name: "mcp-time-server", version: "1.0.0" },
            capabilities: { tools: { list: true, call: true } }
          }
          jsonrpc_response = { jsonrpc: "2.0", id: id, result: result }
        when "tools/list", "tools.list"
          jsonrpc_response = { jsonrpc: "2.0", id: id, result: [time_tool_descriptor] }
        when "tools/call", "tools.call"
          name = params["name"].to_s
          args = (params["arguments"] || {})
          unless name == "time"
            raise StandardError.new("Unknown tool: #{name}")
          end

          content = call_time_tool(args)
          jsonrpc_response = { jsonrpc: "2.0", id: id, result: { content: content } }
        else
          raise StandardError.new("Unknown method: #{method}")
        end
      rescue => e
        jsonrpc_response = { jsonrpc: "2.0", id: id, error: { code: -32000, message: e.message } }
      end

      if session_id && (stream = Mcp::SessionRegistry.fetch(session_id))
        begin
          write_json_line(stream, jsonrpc_response)
          head :accepted and return
        rescue IOError, ActionController::Live::ClientDisconnected
          # Stream is gone; fall back to direct JSON response
        end
      end

      render json: jsonrpc_response, status: :ok
    end

    private

    def write_json_line(stream, payload)
      stream.write(payload.to_json + "\n")
    end

    def time_tool_descriptor
      {
        name: "time",
        description: "Devuelve la hora actual en UTC.",
        inputSchema: {
          type: "object",
          properties: {
            format: { type: "string", description: "Opcional: iso8601 | rfc2822 | epoch" }
          }
        }
      }
    end

    def call_time_tool(args)
      fmt = (args["format"] || "iso8601").to_s
      t = Time.now.utc

      json = {
        utcIso: t.iso8601,
        epochSeconds: t.to_i,
        rfc2822: t.rfc2822
      }

      text = case fmt
             when "rfc2822" then "Hora UTC: #{t.rfc2822}"
             when "epoch" then "Hora UTC (epoch): #{t.to_i}"
             else "Hora UTC: #{t.iso8601}"
             end

      [
        { type: "json", json: json },
        { type: "text", text: text }
      ]
    end
  end
end