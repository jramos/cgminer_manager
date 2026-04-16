# frozen_string_literal: true

require 'stringio'
require 'json'

RSpec.describe CgminerManager::Logger do
  let(:io) { StringIO.new }

  before do
    described_class.output = io
    described_class.format = 'json'
    described_class.level  = 'info'
  end

  describe '.info' do
    it 'writes one JSON line with level, ts, and the provided fields' do
      described_class.info(event: 'ready', pid: 123)
      entry = JSON.parse(io.string.lines.first, symbolize_names: true)

      expect(entry[:level]).to eq('info')
      expect(entry[:event]).to eq('ready')
      expect(entry[:pid]).to eq(123)
      expect(entry[:ts]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe '.debug' do
    context 'when level=info' do
      it 'does not emit' do
        described_class.debug(event: 'noise')
        expect(io.string).to eq('')
      end
    end

    context 'when level=debug' do
      it 'does emit' do
        described_class.level = 'debug'
        described_class.debug(event: 'noise')
        expect(io.string).not_to be_empty
      end
    end
  end

  describe 'text format' do
    before { described_class.format = 'text' }

    it 'formats as "ts LEVEL event k=v k=v"' do
      described_class.info(event: 'ready', pid: 123)
      expect(io.string).to match(/\A\S+ INFO ready pid=123/)
    end
  end

  describe 'thread safety' do
    it 'does not interleave lines under concurrent writers' do
      described_class.format = 'json'
      threads = 20.times.map do |i|
        Thread.new { 50.times { described_class.info(event: 'tick', i: i) } }
      end
      threads.each(&:join)

      lines = io.string.lines
      expect(lines.size).to eq(20 * 50)
      lines.each do |line|
        expect { JSON.parse(line) }.not_to raise_error
      end
    end
  end
end
