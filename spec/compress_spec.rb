# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'support/round_trip'

RSpec.describe Bi2zip::Compress do
  describe 'round-trip on the standard fixture set' do
    Bi2zipSupport::RoundTrip.fixtures.each do |name, bytes|
      it "round-trips #{name}" do
        _, restored = Bi2zipSupport::RoundTrip.round_trip(bytes)
        expect(restored.bytes).to eq(bytes)
      end
    end
  end

  describe 'non-default parts' do
    [4, 8, 16].each do |parts|
      it "round-trips with parts=#{parts}" do
        bytes = Random.new(parts).bytes(parts * 7 + 3).bytes
        _, restored = Bi2zipSupport::RoundTrip.round_trip(bytes, parts: parts)
        expect(restored.bytes).to eq(bytes)
      end
    end
  end

  describe 'algorithm subsets' do
    it 'round-trips with only :eq enabled' do
      bytes = Random.new(11).bytes(300).bytes
      _, restored = Bi2zipSupport::RoundTrip.round_trip(bytes, algorithms: %i[eq])
      expect(restored.bytes).to eq(bytes)
    end

    it 'round-trips with only :eq and :lgray enabled' do
      bytes = Random.new(12).bytes(400).bytes
      _, restored = Bi2zipSupport::RoundTrip.round_trip(bytes, algorithms: %i[eq lgray])
      expect(restored.bytes).to eq(bytes)
    end
  end

  describe 'fixed zlb' do
    [4, 12].each do |zlb|
      it "round-trips with zlb=#{zlb}" do
        bytes = Random.new(zlb + 100).bytes(500).bytes
        _, restored = Bi2zipSupport::RoundTrip.round_trip(bytes, zlb: zlb)
        expect(restored.bytes).to eq(bytes)
      end
    end

    it 'uses the supplied zlb on every pass' do
      # parts is pinned because under the new :auto default the tuner may
      # pick a parts value that produces zero passes (and an empty zlb set).
      bytes = Array.new(120, 0)
      result = described_class.call(bytes: bytes, parts: 12, zlb: 5)
      expect(result.passes.map(&:zlb).uniq).to eq([5])
    end
  end

  it 'is deterministic: same input twice gives byte-identical output' do
    bytes = Random.new(11).bytes(512).bytes
    a = described_class.call(bytes: bytes)
    b = described_class.call(bytes: bytes)
    expect(a.bytes).to eq(b.bytes)
  end

  describe 'pass selection' do
    it 'always begins with an :eq pass when eq produces matches' do
      bytes = Array.new(48, 0x00) # all-zero columns: every adjacent pair is equal
      result = described_class.call(bytes: bytes)
      expect(result.passes.first.name).to eq(:eq)
    end

    it 'records zero passes when eq has no matches on a tiny input' do
      result = described_class.call(bytes: [], parts: 12)
      expect(result.passes).to be_empty
    end

    it 'honours max_passes as an upper bound' do
      bytes = Random.new(20).bytes(2000).bytes
      result = described_class.call(bytes: bytes, max_passes: 2)
      expect(result.passes.size).to be <= 2
    end

    it 'picks :inv when eq cannot match but inv can' do
      # Every byte = 0x55 (0b01010101): each stripe is alternating 01010101...
      # so adjacent columns are bit-wise inverses. eq cannot match a single
      # column; inv matches at every column.
      bytes = [0x55] * 48
      result = described_class.call(bytes: bytes, algorithms: %i[eq inv])
      expect(result.passes.first.name).to eq(:inv)
      _, restored = Bi2zipSupport::RoundTrip.round_trip(bytes, algorithms: %i[eq inv])
      expect(restored.bytes).to eq(bytes)
    end
  end

  describe 'max_passes: :auto' do
    it 'stops adding passes once the next pass would not reduce total size' do
      bytes = Random.new(41).bytes(500).bytes
      auto = described_class.call(bytes: bytes, parts: 12, max_passes: :auto)
      one_more = described_class.call(
        bytes: bytes, parts: 12, max_passes: auto.passes.size + 1,
      )
      # 1-step lookahead: adding one more pass should not shrink total size.
      expect(one_more.bytes.bytesize).to be >= auto.bytes.bytesize
    end

    it 'round-trips with max_passes: :auto' do
      bytes = Random.new(42).bytes(400).bytes
      _, restored = Bi2zipSupport::RoundTrip.round_trip(bytes, parts: 12, max_passes: :auto)
      expect(restored.bytes).to eq(bytes)
    end

    it 'is the default for max_passes' do
      bytes = Random.new(43).bytes(200).bytes
      default = described_class.call(bytes: bytes, parts: 12)
      auto = described_class.call(bytes: bytes, parts: 12, max_passes: :auto)
      expect(default.passes.size).to eq(auto.passes.size)
      expect(default.bytes).to eq(auto.bytes)
    end

    it 'beats or matches a fixed cap on a representative input' do
      bytes = Random.new(44).bytes(800).bytes
      auto = described_class.call(bytes: bytes, parts: 12, max_passes: :auto)
      capped = described_class.call(bytes: bytes, parts: 12, max_passes: 10)
      expect(auto.bytes.bytesize).to be <= capped.bytes.bytesize
    end

    it 'never exceeds MAX_PASSES_RANGE.max passes' do
      bytes = Array.new(240, 0x00)
      result = described_class.call(bytes: bytes, parts: 12, max_passes: :auto)
      expect(result.passes.size).to be <= Bi2zip::Compress::MAX_PASSES_RANGE.max
    end
  end

  describe 'parts: :auto' do
    it 'picks the parts value that minimises total output' do
      bytes = Random.new(31).bytes(400).bytes
      auto = described_class.call(bytes: bytes, parts: :auto)
      brute = Bi2zip::Compress::PARTS_RANGE.map do |parts|
        described_class.call(bytes: bytes, parts: parts)
      end
      brute_min = brute.map { |r| r.bytes.bytesize }.min
      expect(auto.bytes.bytesize).to eq(brute_min)
      expect(Bi2zip::Compress::PARTS_RANGE).to cover(auto.parts)
    end

    it 'round-trips with parts: :auto' do
      bytes = Random.new(32).bytes(300).bytes
      _, restored = Bi2zipSupport::RoundTrip.round_trip(bytes, parts: :auto)
      expect(restored.bytes).to eq(bytes)
    end

    it 'is the default for parts' do
      bytes = Random.new(33).bytes(200).bytes
      default = described_class.call(bytes: bytes)
      auto = described_class.call(bytes: bytes, parts: :auto)
      expect(default.parts).to eq(auto.parts)
      expect(default.bytes).to eq(auto.bytes)
    end
  end

  describe 'validation' do
    it 'rejects parts out of range (0, 3, 17)' do
      expect { described_class.call(bytes: [], parts: 0) }.to raise_error(ArgumentError, /parts/)
      expect { described_class.call(bytes: [], parts: 3) }.to raise_error(ArgumentError, /parts/)
      expect { described_class.call(bytes: [], parts: 17) }.to raise_error(ArgumentError, /parts/)
    end

    it 'accepts parts: :auto' do
      expect { described_class.call(bytes: [], parts: :auto) }.not_to raise_error
    end

    it 'rejects zlb out of range (0, 3, 17)' do
      expect { described_class.call(bytes: [], zlb: 0) }.to raise_error(ArgumentError, /zlb/)
      expect { described_class.call(bytes: [], zlb: 3) }.to raise_error(ArgumentError, /zlb/)
      expect { described_class.call(bytes: [], zlb: 17) }.to raise_error(ArgumentError, /zlb/)
    end

    it 'rejects max_passes out of range (0, 11)' do
      expect { described_class.call(bytes: [], max_passes: 0) }.to raise_error(ArgumentError, /max_passes/)
      expect { described_class.call(bytes: [], max_passes: 11) }.to raise_error(ArgumentError, /max_passes/)
    end

    it 'accepts max_passes: :auto' do
      expect { described_class.call(bytes: [], max_passes: :auto) }.not_to raise_error
    end

    it 'rejects unknown algorithm names' do
      expect { described_class.call(bytes: [], algorithms: %i[eq totally_bogus]) }
        .to raise_error(ArgumentError, /unknown algorithms/)
    end

    it 'rejects an empty algorithms list' do
      expect { described_class.call(bytes: [], algorithms: []) }
        .to raise_error(ArgumentError, /algorithms/)
    end
  end

  it 'emits no stdout chatter' do
    expect do
      described_class.call(bytes: Random.new(2).bytes(200).bytes)
    end.not_to output.to_stdout
  end

  describe 'on-disk format' do
    it 'encodes (parts - 4) in the high nibble of byte 0 and zero in the low nibble' do
      result = described_class.call(bytes: [0xAA] * 24, parts: 8)
      header = result.bytes.getbyte(0)
      expect((header >> 4) & 0x0F).to eq(8 - 4)
      expect(header & 0x0F).to eq(0)
    end

    it 'encodes (parts - 4) at the PARTS_RANGE boundaries' do
      [4, 16].each do |parts|
        bytes = Array.new(parts * 2, 0x00)
        result = described_class.call(bytes: bytes, parts: parts)
        expect((result.bytes.getbyte(0) >> 4) & 0x0F).to eq(parts - 4)
        expect(result.bytes.getbyte(0) & 0x0F).to eq(0)
      end
    end

    it 'starts each pass with (algorithm_id << 4) | (zlb - 4)' do
      # 0x00-only input gives at least one :eq pass with a known algorithm id.
      result = described_class.call(bytes: Array.new(240, 0x00), parts: 12)
      expect(result.passes).not_to be_empty

      stream = result.bytes
      cursor = pass_block_start(stream, result.parts, result.original_byte_count)
      result.passes.each do |pass|
        config = stream.getbyte(cursor)
        expect((config >> 4) & 0x0F).to eq(Bi2zip::Algorithms::ID.fetch(pass.name))
        expect((config & 0x0F) + 4).to eq(pass.zlb)
        cursor = skip_pass(stream, cursor)
      end
      expect(cursor).to eq(stream.bytesize)
    end

    # Helpers reach into the on-disk layout to confirm the spec geometry; if the
    # format changes again these need to move in lockstep.
    def pass_block_start(stream, parts, original_byte_count)
      cursor = 1
      _, cursor = read_varint(stream, cursor)
      stripe_bit_length, cursor = read_varint(stream, cursor)
      stripe_bytes = parts * ((stripe_bit_length + 7) / 8)
      cursor + stripe_bytes + (original_byte_count % parts)
    end

    def skip_pass(stream, cursor)
      cursor += 1
      bit_len, cursor = read_varint(stream, cursor)
      cursor + ((bit_len + 7) / 8)
    end

    def read_varint(stream, cursor)
      shift = 0
      value = 0
      loop do
        byte = stream.getbyte(cursor)
        cursor += 1
        value |= (byte & 0x7F) << shift
        break if (byte & 0x80).zero?

        shift += 7
      end
      [value, cursor]
    end
  end
end
