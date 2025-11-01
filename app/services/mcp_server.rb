# frozen_string_literal: true

begin
  require "mcp_on_ruby"
rescue LoadError
  # Gem not available at load time; controller will still function for SSE keepalive.
end

class McpServer
  class << self
    def instance
      @instance ||= begin
        if defined?(MCPOnRuby::Server)
          srv = MCPOnRuby::Server.new(transport: :sse)
          # Register tool if gem provides an API; fallback is manual handling below.
          if srv.respond_to?(:register_tool)
            srv.register_tool(GetUtcTimeTool.new)
          end
          srv
        else
          Object.new # placeholder
        end
      end
    end

    # Minimal JSON-RPC 2.0 handling specifically for get_utc_time
    def handle_json_rpc(msg)
      id = msg["id"]
      method = msg["method"].to_s
      params = msg["params"] || {}

      case method
      when "initialize"
        result = {
          server: { name: "mcp-on-ruby-time-server", version: "1.0.0" },
          capabilities: { tools: { list: true, call: true } }
        }
        { jsonrpc: "2.0", id: id, result: result }
      when "tools/list", "tools.list"
        { jsonrpc: "2.0", id: id, result: [tool_descriptor] }
      when "tools/call", "tools.call"
        name = params["name"].to_s
        args = (params["arguments"] || {})

        unless name == "get_utc_time"
          return { jsonrpc: "2.0", id: id, error: { code: -32601, message: "Unknown tool: #{name}" } }
        end

        content = call_get_utc_time(args)
        { jsonrpc: "2.0", id: id, result: { content: content } }
      else
        { jsonrpc: "2.0", id: id, error: { code: -32601, message: "Unknown method: #{method}" } }
      end
    rescue => e
      { jsonrpc: "2.0", id: id, error: { code: -32000, message: e.message } }
    end

    private

    def tool_descriptor
      {
        name: "get_utc_time",
        description: "Devuelve la hora actual en UTC (ISO 8601).",
        inputSchema: { type: "object", properties: {} }
      }
    end

    def call_get_utc_time(_args)
      iso = GetUtcTimeTool.new.call
      [
        { type: "text", text: iso }
      ]
    end
  end
end