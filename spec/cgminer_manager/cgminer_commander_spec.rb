# frozen_string_literal: true

RSpec.describe CgminerManager::FleetQueryResult do
  let(:ok_entry)  { CgminerManager::FleetQueryEntry.new(miner: 'a', ok: true,  response: { foo: 1 }, error: nil) }
  let(:err_entry) { CgminerManager::FleetQueryEntry.new(miner: 'b', ok: false, response: nil,        error: RuntimeError.new('boom')) }

  it 'counts ok / failed and reports all_ok?' do
    mixed = described_class.new(entries: [ok_entry, err_entry])
    all_ok = described_class.new(entries: [ok_entry])

    expect(mixed.ok_count).to eq(1)
    expect(mixed.failed_count).to eq(1)
    expect(mixed.all_ok?).to be false
    expect(all_ok.all_ok?).to be true
  end
end

RSpec.describe CgminerManager::FleetWriteResult do
  let(:ok_entry)     { CgminerManager::FleetWriteEntry.new(miner: 'a', status: :ok,     response: 'saved', error: nil) }
  let(:failed_entry) { CgminerManager::FleetWriteEntry.new(miner: 'b', status: :failed, response: nil,     error: RuntimeError.new('boom')) }

  it 'counts ok / failed and reports any_failed?' do
    result = described_class.new(entries: [ok_entry, failed_entry])
    expect(result.ok_count).to eq(1)
    expect(result.failed_count).to eq(1)
    expect(result.any_failed?).to be true
    expect(result.all_ok?).to be false
  end
end

RSpec.describe CgminerManager::CgminerCommander do
  let(:miner_a) { instance_double(CgminerApiClient::Miner, host: '10.0.0.1', port: 4028) }
  let(:miner_b) { instance_double(CgminerApiClient::Miner, host: '10.0.0.2', port: 4028) }

  before do
    allow(miner_a).to receive(:to_s).and_return('10.0.0.1:4028')
    allow(miner_b).to receive(:to_s).and_return('10.0.0.2:4028')
  end

  describe '#version' do
    it 'fans out :version queries and wraps results in FleetQueryResult' do
      expect(miner_a).to receive(:query).with(:version).and_return({ 'CGMiner' => '4.11.1' })
      expect(miner_b).to receive(:query).with(:version).and_return({ 'CGMiner' => '4.10.0' })

      result = described_class.new(miners: [miner_a, miner_b]).version

      expect(result.entries.map(&:miner)).to eq(['10.0.0.1:4028', '10.0.0.2:4028'])
      expect(result.all_ok?).to be true
      expect(result.entries.first.response).to eq({ 'CGMiner' => '4.11.1' })
    end

    it 'marks ConnectionError entries as not-ok without aborting the whole fan-out' do
      expect(miner_a).to receive(:query).with(:version).and_raise(CgminerApiClient::ConnectionError.new('refused'))
      expect(miner_b).to receive(:query).with(:version).and_return({ 'CGMiner' => '4.11.1' })

      result = described_class.new(miners: [miner_a, miner_b]).version

      expect(result.ok_count).to eq(1)
      expect(result.failed_count).to eq(1)
      expect(result.entries.first.error).to be_a(CgminerApiClient::ConnectionError)
    end
  end

  describe '#stats and #devs' do
    it 'dispatches the correct RPC verb' do
      expect(miner_a).to receive(:query).with(:stats).and_return([{ 'ID' => 'BMM0' }])
      expect(miner_a).to receive(:query).with(:devs).and_return([{ 'Name' => 'BMM', 'ID' => 0 }])

      commander = described_class.new(miners: [miner_a])
      expect(commander.stats.entries.first.response).to eq([{ 'ID' => 'BMM0' }])
      expect(commander.devs.entries.first.response.first['Name']).to eq('BMM')
    end
  end

  describe '#zero!' do
    it 'sends :zero with "all","false" args and returns a FleetWriteResult' do
      expect(miner_a).to receive(:query).with(:zero, 'all', 'false')

      result = described_class.new(miners: [miner_a]).zero!

      expect(result).to be_a(CgminerManager::FleetWriteResult)
      expect(result.all_ok?).to be true
    end
  end

  describe '#save!, #restart!, #quit!' do
    %i[save restart quit].each do |verb|
      it "dispatches :#{verb} and succeeds on any non-error response" do
        expect(miner_a).to receive(:query).with(verb)

        result = described_class.new(miners: [miner_a]).public_send("#{verb}!")
        expect(result.all_ok?).to be true
      end
    end

    it 'marks TimeoutError entries as failed without raising' do
      expect(miner_a).to receive(:query).with(:restart).and_raise(CgminerApiClient::TimeoutError.new('took too long'))

      result = described_class.new(miners: [miner_a]).restart!

      expect(result.any_failed?).to be true
      expect(result.entries.first.error).to be_a(CgminerApiClient::TimeoutError)
    end
  end

  describe '#raw!' do
    it 'splits comma-separated args into positional query params' do
      expect(miner_a).to receive(:query).with(:pgaset, '0', 'clock', '690').and_return({})

      result = described_class.new(miners: [miner_a]).raw!(command: 'pgaset', args: '0,clock,690')

      expect(result.all_ok?).to be true
    end

    it 'calls the query with no args when args is nil or empty' do
      expect(miner_a).to receive(:query).with(:version).twice.and_return({})

      commander = described_class.new(miners: [miner_a])
      expect(commander.raw!(command: 'version', args: nil).all_ok?).to be true
      expect(commander.raw!(command: 'version', args: '').all_ok?).to be true
    end

    it 'propagates ApiError as a :failed entry with the raised error attached' do
      expect(miner_a).to receive(:query).with(:bogus).and_raise(CgminerApiClient::ApiError.new('invalid command'))

      result = described_class.new(miners: [miner_a]).raw!(command: 'bogus')

      expect(result.entries.first.status).to eq(:failed)
      expect(result.entries.first.error.message).to include('invalid command')
    end
  end

  describe 'thread fan-out' do
    it 'invokes the block for every miner even with thread_cap of 1' do
      expect(miner_a).to receive(:query).with(:version).and_return({ 'CGMiner' => '4.11.1' })
      expect(miner_b).to receive(:query).with(:version).and_return({ 'CGMiner' => '4.11.1' })

      result = described_class.new(miners: [miner_a, miner_b], thread_cap: 1).version

      expect(result.entries.size).to eq(2)
    end

    it 'preserves per-miner result ordering regardless of completion order' do
      expect(miner_a).to receive(:query).with(:version) do
        sleep 0.05
        { 'CGMiner' => 'A' }
      end
      expect(miner_b).to receive(:query).with(:version).and_return({ 'CGMiner' => 'B' })

      result = described_class.new(miners: [miner_a, miner_b], thread_cap: 4).version

      expect(result.entries.map(&:miner)).to eq(['10.0.0.1:4028', '10.0.0.2:4028'])
    end
  end
end
