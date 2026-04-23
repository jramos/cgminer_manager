# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerManager::AdminLogging do
  describe '.session_id_hash' do
    it 'returns a 12-char hex digest of the session id' do
      hash = described_class.session_id_hash('a-full-rack-session-id')
      expect(hash).to match(/\A[0-9a-f]{12}\z/)
    end

    it 'returns a stable 12-char digest for a nil session id' do
      hash = described_class.session_id_hash(nil)
      expect(hash).to match(/\A[0-9a-f]{12}\z/)
    end
  end

  describe '.command_log_entry' do
    let(:entry) do
      described_class.command_log_entry(
        event: 'admin.raw_command', command: 'version', scope: 'all',
        request_id: 'req-123', session_id_hash: 'abc123abc123',
        remote_ip: '127.0.0.1', user_agent: 'curl/8', user: 'operator',
        args: 'foo,bar'
      )
    end

    it 'carries the fixed keys' do
      expect(entry).to include(
        event: 'admin.raw_command', request_id: 'req-123',
        user: 'operator', remote_ip: '127.0.0.1', user_agent: 'curl/8',
        session_id_hash: 'abc123abc123', command: 'version', scope: 'all'
      )
    end

    it 'merges **extra AFTER the fixed keys so args:/scope: callers survive' do
      expect(entry[:args]).to eq('foo,bar')
    end
  end

  describe '.result_log_entry' do
    it 'pulls ok_count/failed_count off a FleetWriteResult-shaped value' do
      result = instance_double(CgminerManager::FleetWriteResult, ok_count: 3, failed_count: 1)
      started = Time.now - 0.25
      entry = described_class.result_log_entry(
        command: 'restart', scope: 'all', result: result,
        started_at: started, request_id: 'req-123'
      )
      expect(entry).to include(
        event: 'admin.result',
        request_id: 'req-123',
        command: 'restart',
        scope: 'all',
        ok_count: 3,
        failed_count: 1
      )
      expect(entry[:duration_ms]).to be_between(200, 2000)
    end
  end
end
