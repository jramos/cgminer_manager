# frozen_string_literal: true

require 'spec_helper'

# Pure unit specs for the view-model builders extracted out of HttpApp.
# No Rack::Test, no Sinatra boot — the whole point of the extraction is
# that these functions only depend on their kwargs.
RSpec.describe CgminerManager::ViewModels do
  let(:configured_miners) do
    [
      ['10.0.0.1', 4028, 'rig-a'],
      ['10.0.0.2', 4028, nil]
    ].freeze
  end

  describe '.build_view_miner_pool' do
    it 'threads labels through from configured_miners into each ViewMiner' do
      monitor_miners = [
        { id: '10.0.0.1:4028', host: '10.0.0.1', port: 4028, available: true },
        { id: '10.0.0.2:4028', host: '10.0.0.2', port: 4028, available: false }
      ]
      pool = described_class.build_view_miner_pool(monitor_miners, configured_miners: configured_miners)

      expect(pool.miners.length).to eq(2)
      expect(pool.miners.first.label).to eq('rig-a')
      expect(pool.miners.first.available).to be(true)
      expect(pool.miners.last.label).to be_nil
      expect(pool.miners.last.available).to be(false)
    end

    it 'returns an empty pool for a nil monitor result' do
      pool = described_class.build_view_miner_pool(nil, configured_miners: configured_miners)
      expect(pool.miners).to be_empty
    end
  end
end
