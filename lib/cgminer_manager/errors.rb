# frozen_string_literal: true

module CgminerManager
  class Error < StandardError; end
  class ConfigError < Error; end

  class MonitorError < Error
    class ConnectionError < MonitorError; end

    class ApiError < MonitorError
      attr_reader :status, :body

      def initialize(msg = nil, status: nil, body: nil)
        super(msg)
        @status = status
        @body = body
      end
    end
  end

  module PoolManagerError
    class DidNotConverge < Error; end
  end
end
