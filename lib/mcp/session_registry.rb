require "mutex_m"

module Mcp
  # Minimal in-memory session registry to correlate SSE streams with POST /messages.
  # NOTE: This is process-local and not suitable for multi-process deployments.
  class SessionRegistry
    extend Mutex_m

    @streams = {}
    @initialized = false

    class << self
      def ensure_init
        return if @initialized
        mu_initialize
        @initialized = true
      end

      def register(session_id, stream)
        ensure_init
        synchronize do
          @streams[session_id] = stream
        end
      end

      def fetch(session_id)
        ensure_init
        synchronize do
          @streams[session_id]
        end
      end

      def unregister(session_id)
        ensure_init
        synchronize do
          @streams.delete(session_id)
        end
      end
    end
  end
end