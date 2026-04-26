# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerManager::ErrorCode do
  describe '.classify' do
    it 'returns ApiError#code Symbol verbatim (covers AccessDeniedError subclass too)' do
      err = CgminerApiClient::AccessDeniedError.new('45: Access denied', cgminer_code: 45)
      expect(described_class.classify(err)).to eq(:access_denied)
    end

    it 'maps a base ApiError with cgminer_code: 45 to :access_denied via api_client' do
      err = CgminerApiClient::ApiError.new('45: Access denied', cgminer_code: 45)
      expect(described_class.classify(err)).to eq(:access_denied)
    end

    it 'synthesizes :timeout for CgminerApiClient::TimeoutError (no wire code available)' do
      expect(described_class.classify(CgminerApiClient::TimeoutError.new('connect timeout')))
        .to eq(:timeout)
    end

    it 'synthesizes :connection_error for CgminerApiClient::ConnectionError' do
      expect(described_class.classify(CgminerApiClient::ConnectionError.new('refused')))
        .to eq(:connection_error)
    end

    it 'falls through to :unexpected for any non-CgminerApiClient StandardError' do
      expect(described_class.classify(StandardError.new('out of left field')))
        .to eq(:unexpected)
    end

    it 'guards against duck-typed #code methods that do not return a Symbol' do
      stray = Struct.new(:code).new(500) # mimics e.g. an HTTP-status-bearing object
      expect(described_class.classify(stray)).to eq(:unexpected)
    end
  end
end
