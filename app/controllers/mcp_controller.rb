require "securerandom"

class McpController < ApplicationController
  include ActionController::Live

  # GET /mcp — SSE stream endpoint (HTTP streamable)
  def stream
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
    # Avoid buffering by Rack middlewares
    response.headers["Last-Modified"] = Time.now.httpdate

    # Create/ensure MCP server with SSE transport and register tools
    server = McpServer.instance

    # Track this stream to allow pushing responses when clients call tools
    session_id = request.headers["Mcp-Session-Id"].presence || SecureRandom.uuid
    response.headers["Mcp-Session-Id"] = session_id

    Mcp::SessionRegistry.register(session_id, response.stream)

    begin
      # Initial event to signal readiness (optional for clients)
      response.stream.write("event: ready\n")
      response.stream.write("data: {\"endpoint\":\"/mcp/messages\"}\n\n")

      # Keep the connection alive with ping every 15 seconds
      loop do
        response.stream.write(": ping\n\n")
        sleep 15
      end
    rescue ActionController::Live::ClientDisconnected, IOError
      # client disconnected
    ensure
      Mcp::SessionRegistry.unregister(session_id)
      response.stream.close
    end
  end

  # POST /mcp/messages — optional JSON-RPC handler that responds via SSE when possible
  def messages
    session_id = request.headers["Mcp-Session-Id"].presence
    payload = request.raw_post.to_s

    begin
      request_obj = JSON.parse(payload)
    rescue JSON::ParserError
      render json: { error: { code: "invalid_json", message: "Body must be valid JSON" } }, status: :bad_request and return
    end

    unless request_obj.is_a?(Hash) && request_obj["jsonrpc"] == "2.0" && request_obj.key?("method")
      render json: { error: { code: "invalid_request", message: "Must be a JSON-RPC 2.0 request" } }, status: :bad_request and return
    end

    response_obj = McpServer.handle_json_rpc(request_obj)

    if session_id && (stream = Mcp::SessionRegistry.fetch(session_id))
      begin
        stream.write("event: message\n")
        stream.write("data: #{response_obj.to_json}\n\n")
        head :accepted and return
      rescue IOError, ActionController::Live::ClientDisconnected
        # stream unavailable, fallback to direct JSON
      end
    end

    render json: response_obj, status: :ok
  end
end