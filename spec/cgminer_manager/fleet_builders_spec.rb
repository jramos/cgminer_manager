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
      expect(CgminerApiClient::Miner).to have_received(:new).with('10.0.0.1', 4028).ordered
      expect(CgminerApiClient::Miner).to have_received(:new).with('10.0.0.2', 4029).ordered
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
      expect(CgminerApiClient::Miner).to have_received(:new).with('10.0.0.1', 4028)
      expect(CgminerManager::PoolManager).to have_received(:new).with(have_attributes(length: 1))
    end
  end

  describe '.commander_for_all' do
    it 'constructs a CgminerCommander with the given thread_cap' do
      described_class.commander_for_all(configured_miners: configured_miners, thread_cap: 2)
      expect(CgminerManager::CgminerCommander).to have_received(:new)
        .with(miners: have_attributes(length: 2), thread_cap: 2)
    end

    it 'defaults a nil thread_cap to 1' do
      described_class.commander_for_all(configured_miners: configured_miners, thread_cap: nil)
      expect(CgminerManager::CgminerCommander).to have_received(:new).with(miners: anything, thread_cap: 1)
    end
  end

  describe '.commander_for' do
    it 'parses host:port ids into commander miners' do
      described_class.commander_for(%w[10.0.0.1:4028], thread_cap: 2)
      expect(CgminerApiClient::Miner).to have_received(:new).with('10.0.0.1', 4028)
      expect(CgminerManager::CgminerCommander).to have_received(:new)
        .with(miners: have_attributes(length: 1), thread_cap: 2)
    end
  end
end
