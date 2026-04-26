# frozen_string_literal: true

module CgminerManager
  # Classifies a rescued exception into a single-symbol vocabulary
  # for log-side dispatch. cgminer_api_client::ApiError (v0.4.0+)
  # carries its own #code Symbol; transport-layer errors don't, so
  # synthesize a parallel symbol so consumers can `case .code`
  # uniformly. The six values match cgminer_monitor's
  # docs/log_schema.md `code` standard-key entry.
  #
  # Branch ordering: ApiError-shaped errors win via the duck-typed
  # #code Symbol guard (covers AccessDeniedError subclass too);
  # transport-only errors fall through to the synthesized values.
  module ErrorCode
    def self.classify(error)
      return error.code if error.respond_to?(:code) && error.code.is_a?(Symbol)
      return :timeout if error.is_a?(CgminerApiClient::TimeoutError)
      return :connection_error if error.is_a?(CgminerApiClient::ConnectionError)

      :unexpected
    end
  end
end
