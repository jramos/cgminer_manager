# frozen_string_literal: true

RSpec.describe CgminerManager::PoolManager::PoolActionResult do
  let(:entry_ok) do
    CgminerManager::PoolManager::MinerEntry.new(
      miner: '10.0.0.1:4028', command_status: :ok, command_reason: nil,
      save_status: :ok, save_reason: nil
    )
  end

  let(:entry_failed) do
    CgminerManager::PoolManager::MinerEntry.new(
      miner: '10.0.0.2:4028', command_status: :failed,
      command_reason: RuntimeError.new('boom'),
      save_status: :skipped, save_reason: nil
    )
  end

  describe '#all_ok?' do
    it 'is true when every entry is ok' do
      result = described_class.new(entries: [entry_ok])
      expect(result.all_ok?).to be true
    end

    it 'is false when any entry is not ok' do
      result = described_class.new(entries: [entry_ok, entry_failed])
      expect(result.all_ok?).to be false
    end
  end

  describe '#any_failed?' do
    it 'is true when any entry failed' do
      result = described_class.new(entries: [entry_ok, entry_failed])
      expect(result.any_failed?).to be true
    end
  end

  describe '#successful' do
    it 'filters to entries with :ok command_status' do
      result = described_class.new(entries: [entry_ok, entry_failed])
      expect(result.successful.map(&:miner)).to eq(['10.0.0.1:4028'])
    end
  end
end

RSpec.describe CgminerManager::PoolManager do
  let(:miner_id) { '10.0.0.1:4028' }
  let(:miner) do
    instance_double(CgminerApiClient::Miner, host: '10.0.0.1', port: 4028)
  end

  before do
    allow(miner).to receive(:to_s).and_return(miner_id)
  end

  describe '#disable_pool' do
    context 'when the command succeeds and pool flips to Disabled' do
      it 'returns PoolActionResult with command_status :ok and save_status :ok' do
        expect(miner).to receive(:disablepool).with(1)
        expect(miner).to receive(:query).with(:pools).and_return(
          [{ 'POOL' => 1, 'STATUS' => 'Disabled' }]
        )
        expect(miner).to receive(:query).with(:save)

        pm = described_class.new([miner])
        result = pm.disable_pool(pool_index: 1)

        entry = result.entries.first
        expect(entry.command_status).to eq(:ok)
        expect(entry.save_status).to eq(:ok)
      end
    end
  end
end
