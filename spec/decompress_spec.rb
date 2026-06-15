# frozen_string_literal: true

require_relative 'spec_helper'
require_relative 'support/round_trip'
require 'tmpdir'

RSpec.describe Bi2zip::Decompress do
  describe 'in-memory round-trip on the standard fixture set' do
    Bi2zipSupport::RoundTrip.fixtures.each do |name, bytes|
      it "round-trips #{name}" do
        _, restored = Bi2zipSupport::RoundTrip.round_trip(bytes)
        expect(restored.bytes).to eq(bytes)
      end
    end
  end

  # A fixture that compresses to multiple passes so the mutation tests below
  # have something to corrupt. Highly redundant input + a small inv-shaped
  # tail force at least an :eq pass and one alternative algorithm.
  let(:fixture_bytes) { Array.new(120, 0x00) + Array.new(120, 0x55) }
  let(:compressed) { Bi2zip::Compress.call(bytes: fixture_bytes) }

  it 'round-trips the multi-pass fixture' do
    restored = described_class.call(bytes: compressed.bytes)
    expect(restored.bytes).to eq(fixture_bytes)
  end

  it 'raises on an empty stream' do
    expect { described_class.call(bytes: ''.b) }
      .to raise_error(ArgumentError, /truncated|too short/)
  end

  it 'raises when the reserved nibble in byte 0 is non-zero' do
    mutated = compressed.bytes.b
    mutated.setbyte(0, mutated.getbyte(0) | 0x01)
    expect { described_class.call(bytes: mutated) }
      .to raise_error(ArgumentError, /reserved bits must be zero/)
  end

  it 'raises when a varint runs off the end of the stream' do
    # First byte = 0, then a varint byte with continuation bit set and no more
    # input. Catches truncated original_byte_count.
    expect { described_class.call(bytes: "\x00\x80".b) }
      .to raise_error(ArgumentError, /truncated varint/)
  end

  it 'raises when the stripes block is truncated' do
    # Keep only the global header so the declared stripes block lies beyond
    # the end of the stream.
    truncated = compressed.bytes[0, 5]
    expect { described_class.call(bytes: truncated) }
      .to raise_error(ArgumentError, /truncated|too short/)
  end

  it 'raises when a pass payload is truncated' do
    mutated = compressed.bytes.b[0..-2]
    expect { described_class.call(bytes: mutated) }
      .to raise_error(ArgumentError, /truncated|too short/)
  end

  it 'raises when the decoded PARTS value is out of range' do
    # Encoded PARTS = 13 -> decoded 17, outside 4..16.
    mutated = compressed.bytes.b
    mutated.setbyte(0, 13 << 4)
    expect { described_class.call(bytes: mutated) }
      .to raise_error(ArgumentError, /parts/)
  end

  it 'raises on an unknown algorithm id in a pass header' do
    mutated = mutate_first_pass_byte(compressed.bytes) { |b| (15 << 4) | (b & 0x0F) }
    expect { described_class.call(bytes: mutated) }
      .to raise_error(ArgumentError, /unknown algorithm/)
  end

  it 'raises when a pass ZLB value is out of range' do
    # ZLB nibble = 13 -> decoded 17, outside 4..16.
    mutated = mutate_first_pass_byte(compressed.bytes) { |b| (b & 0xF0) | 13 }
    expect { described_class.call(bytes: mutated) }
      .to raise_error(ArgumentError, /zlb/)
  end

  describe '.from_path' do
    it 'round-trips through a binary file on disk' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'x.bi2zip')
        File.binwrite(path, compressed.bytes)
        expect(described_class.from_path(path: path).bytes).to eq(fixture_bytes)
      end
    end

    Bi2zipSupport::RoundTrip.fixtures.each do |name, bytes|
      it "round-trips #{name} on disk" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'x.bi2zip')
          File.binwrite(path, Bi2zip::Compress.call(bytes: bytes).bytes)
          expect(described_class.from_path(path: path).bytes).to eq(bytes)
        end
      end
    end

    it 'raises ArgumentError (not NoMethodError) on an empty file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'x.bi2zip')
        File.binwrite(path, '')
        expect { described_class.from_path(path: path) }
          .to raise_error(ArgumentError, /truncated|too short/)
      end
    end
  end

  def first_pass_offset(stream, parts, original_byte_count)
    cursor = 1
    _, cursor = read_varint(stream, cursor)
    stripe_bit_length, cursor = read_varint(stream, cursor)
    stripe_bytes = parts * ((stripe_bit_length + 7) / 8)
    cursor + stripe_bytes + (original_byte_count % parts)
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

  def mutate_first_pass_byte(stream)
    mutated = stream.b
    offset = first_pass_offset(mutated, compressed.parts, compressed.original_byte_count)
    mutated.setbyte(offset, yield(mutated.getbyte(offset)))
    mutated
  end
end
