# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Bi2zip::RLE do
  shared_examples 'round-trips' do |raw|
    it "round-trips #{raw.length}-bit input" do
      encoded = described_class.encode(raw, zero_len_bits: zero_len_bits)
      decoded = described_class.decode(encoded, zero_len_bits: zero_len_bits)
      expect(decoded).to eq(raw)
    end
  end

  [1, 4, 7, 12].each do |w|
    context "with zero_len_bits=#{w}" do
      let(:zero_len_bits) { w }
      let(:max_zero_run) { 1 << w }

      include_examples 'round-trips', ''
      include_examples 'round-trips', '1' * 50
      include_examples 'round-trips', '0' * 50
      include_examples 'round-trips', ('10' * 25)
      include_examples 'round-trips', ('01' * 25)

      it 'round-trips exactly 2**ZERO_LEN_BITS zeros (boundary)' do
        raw = '0' * (1 << w)
        encoded = described_class.encode(raw, zero_len_bits: w)
        expect(described_class.decode(encoded, zero_len_bits: w)).to eq(raw)
      end

      it 'round-trips 2**ZERO_LEN_BITS + 1 zeros (spans two chunks)' do
        raw = '0' * ((1 << w) + 1)
        encoded = described_class.encode(raw, zero_len_bits: w)
        expect(described_class.decode(encoded, zero_len_bits: w)).to eq(raw)
      end

      it 'round-trips a very long zero run spanning many chunks' do
        raw = ('0' * (max_zero_run * 3 + 5)) + ('1' * 4) + ('0' * (max_zero_run * 2))
        encoded = described_class.encode(raw, zero_len_bits: w)
        expect(described_class.decode(encoded, zero_len_bits: w)).to eq(raw)
      end

      it 'encodes a single zero as 1 + zero_len_bits bits' do
        encoded = described_class.encode('0', zero_len_bits: w)
        expect(encoded.length).to eq(1 + w)
        expect(encoded[0]).to eq('0')
      end

      it 'encodes runs of ones one-for-one' do
        expect(described_class.encode('1' * 17, zero_len_bits: w)).to eq('1' * 17)
      end
    end
  end

  it 'raises on a malformed bit other than 0/1' do
    expect { described_class.decode('1X', zero_len_bits: 4) }.to raise_error(ArgumentError, /invalid bit/)
  end

  it 'raises when a zero-run length field is truncated' do
    expect { described_class.decode('0011', zero_len_bits: 7) }.to raise_error(ArgumentError, /truncated/)
  end
end
