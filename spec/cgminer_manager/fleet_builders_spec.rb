# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerManager::FleetBuilders do
  let(:configured_miners) do
    [['10.0.0.1', 4028, 'rig-a'], ['10.0.0.2', 4029, nil]].freeze
  end

  before do
    allow(CgminerApiClient::Miner).to receive(:new).and_call_original
    allow(CgminerManager::PoolManager).to receive(:new).and_return(:fake_pool)
    allow(CgminerManager::CgminerCommander).to receive(:new).and_return(:fake_commander)
  end

  describe '.pool_manager_for_all' do
    it 'constructs a PoolManager with Miners from configured_miners and the given thread_cap' do
      result = described_class.pool_manager_for_all(configured_miners: configured_miners, thread_cap: 4)
      expect(result).to eq(:fake_pool)
      expect(CgminerApiClient::Miner).to have_received(:new).with('10.0.0.1', 4028, on_wire: nil).ordered
      expect(CgminerApiClient::Miner).to have_received(:new).with('10.0.0.2', 4029, on_wire: nil).ordered
      expect(CgminerManager::PoolManager).to have_received(:new)
        .with(have_attributes(length: 2), thread_cap: 4)
    end

    it 'defaults a nil thread_cap to 1' do
      described_class.pool_manager_for_all(configured_miners: configured_miners, thread_cap: nil)
      expect(CgminerManager::PoolManager).to have_received(:new).with(anything, thread_cap: 1)
    end
  end

  describe '.pool_manager_for' do
    it 'parses host:port ids into Miners' do
      described_class.pool_manager_for(%w[10.0.0.1:4028])
      expect(CgminerApiClient::Miner).to have_received(:new).with('10.0.0.1', 4028, on_wire: nil)
      expect(CgminerManager::PoolManager).to have_received(:new).with(have_attributes(length: 1))
    end
  end

  describe '.commander_for_all' do
    it 'constructs a CgminerCommander with the given thread_cap' do
      described_class.commander_for_all(configured_miners: configured_miners, thread_cap: 2)
      expect(CgminerManager::CgminerCommander).to have_received(:new)
        .with(miners: have_attributes(length: 2), thread_cap: 2, request_id: nil)
    end

    it 'defaults a nil thread_cap to 1' do
      described_class.commander_for_all(configured_miners: configured_miners, thread_cap: nil)
      expect(CgminerManager::CgminerCommander).to have_received(:new)
        .with(miners: anything, thread_cap: 1, request_id: nil)
    end
  end

  describe '.commander_for' do
    it 'parses host:port ids into commander miners' do
      described_class.commander_for(%w[10.0.0.1:4028], thread_cap: 2)
      expect(CgminerApiClient::Miner).to have_received(:new).with('10.0.0.1', 4028, on_wire: nil)
      expect(CgminerManager::CgminerCommander).to have_received(:new)
        .with(miners: have_attributes(length: 1), thread_cap: 2, request_id: nil)
    end
  end

  describe 'request_id wiring (cgminer.wire closure)' do
    let(:captured_on_wires) { [] }

    before do
      allow(CgminerApiClient::Miner).to receive(:new) do |_h, _p, on_wire: nil|
        captured_on_wires << on_wire
        :fake_miner
      end
    end

    it 'builds an on_wire closure that emits cgminer.wire with the request_id' do
      described_class.commander_for_all(
        configured_miners: configured_miners, thread_cap: 2, request_id: 'fleet-trace-001'
      )
      expect(captured_on_wires.size).to eq(2)
      expect(captured_on_wires).to all(be_a(Proc))

      log_events = []
      allow(CgminerManager::Logger).to receive(:debug) { |entry| log_events << entry }
      captured_on_wires.first.call(:request, '10.0.0.1', 4028, '{"command":"version"}')

      expect(log_events.first).to include(
        event: 'cgminer.wire',
        request_id: 'fleet-trace-001',
        direction: :request,
        miner: '10.0.0.1:4028'
      )
    end

    it 'passes nil on_wire when request_id is nil (no wire-telemetry overhead)' do
      described_class.commander_for_all(
        configured_miners: configured_miners, thread_cap: 1, request_id: nil
      )
      expect(captured_on_wires).to eq([nil, nil])
    end

    it 'reuses the same closure across all per-request Miner instances (fan-out concurrency safety)' do
      described_class.pool_manager_for_all(
        configured_miners: configured_miners, thread_cap: 2, request_id: 'shared-trace'
      )
      # Same Proc identity across all 2 Miner constructions — closure
      # has no mutable state, safe to share across ThreadedFanOut workers.
      expect(captured_on_wires.uniq.size).to eq(1)
    end
  end

  describe '.build_wire_logger' do
    it 'returns nil when request_id is nil' do
      expect(described_class.build_wire_logger(nil)).to be_nil
    end

    it 'returns a Proc when request_id is present' do
      expect(described_class.build_wire_logger('x')).to be_a(Proc)
    end
  end
end
