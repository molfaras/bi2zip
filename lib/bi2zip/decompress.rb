# frozen_string_literal: true

require_relative 'algorithms'
require_relative 'rle'
require_relative 'varint'

module Bi2zip
  # Inverse of Bi2zip::Compress. Parses the single-file .bi2zip stream end to
  # end, replays the per-pass rule streams in reverse order on the stored
  # stripes, then de-interleaves into the original byte stream and appends the
  # leftover bytes.
  module Decompress
    # Mirrors Bi2zip::Compress::PARTS_RANGE / ZLB_RANGE. Keep them in sync.
    PARTS_RANGE = (4..16).freeze
    ZLB_RANGE = (4..16).freeze

    module_function

    def call(bytes:)
      stream = bytes.b
      parts, original_byte_count, stripe_bit_length, stripes, leftover, cursor =
        parse_header_and_stripes(stream)
      passes = parse_passes(stream, cursor)

      passes.reverse_each do |entry|
        raw_rules = RLE.decode(entry[:encoded_rules], zero_len_bits: entry[:zlb])
        stripes, stripe_bit_length = reverse_pass(
          stripes, stripe_bit_length, raw_rules, entry[:name], parts,
        )
      end

      deinterleave(stripes, parts, original_byte_count, leftover)
    end

    def from_path(path:)
      call(bytes: File.binread(path))
    end

    def parse_header_and_stripes(stream)
      raise ArgumentError, 'stream too short: empty input' if stream.empty?

      byte0 = stream.getbyte(0)
      raise ArgumentError, 'header reserved bits must be zero' unless (byte0 & 0x0F).zero?

      parts = ((byte0 >> 4) & 0x0F) + 4
      raise ArgumentError, "header parts out of range: #{parts}" unless PARTS_RANGE.include?(parts)

      original_byte_count, cursor = Varint.decode(stream, 1)
      stripe_bit_length, cursor = Varint.decode(stream, cursor)

      leftover_count = original_byte_count % parts
      expected_full_chunk_bits = (original_byte_count / parts) * 8
      if stripe_bit_length > expected_full_chunk_bits
        raise ArgumentError,
              "header inconsistent: stripe_bit_length=#{stripe_bit_length} " \
              "exceeds uncompressed stripe length #{expected_full_chunk_bits}"
      end

      stripe_byte_size = (stripe_bit_length + 7) / 8
      stripes_block_size = parts * stripe_byte_size
      need = cursor + stripes_block_size + leftover_count
      if stream.bytesize < need
        raise ArgumentError, "stream truncated: need #{need} bytes, got #{stream.bytesize}"
      end

      stripes = Array.new(parts) do |j|
        offset = cursor + (j * stripe_byte_size)
        unpack_bits(stream[offset, stripe_byte_size], stripe_bit_length)
      end
      leftover = stream[cursor + stripes_block_size, leftover_count].bytes

      [parts, original_byte_count, stripe_bit_length, stripes, leftover, need]
    end

    def parse_passes(stream, cursor)
      passes = []
      while cursor < stream.bytesize
        passes << parse_pass(stream, cursor)
        cursor = passes.last[:end]
      end
      passes
    end

    def parse_pass(stream, cursor)
      config = stream.getbyte(cursor)
      raise ArgumentError, 'stream truncated: missing pass header byte' if config.nil?

      cursor += 1
      algo_id = (config >> 4) & 0x0F
      zlb = (config & 0x0F) + 4
      name = Algorithms::BY_ID[algo_id]
      raise ArgumentError, "unknown algorithm id: #{algo_id}" if name.nil?
      raise ArgumentError, "pass zlb out of range: #{zlb}" unless ZLB_RANGE.include?(zlb)

      rule_bit_length, cursor = Varint.decode(stream, cursor)
      need_bytes = (rule_bit_length + 7) / 8
      finish = cursor + need_bytes
      if stream.bytesize < finish
        raise ArgumentError,
              "pass payload truncated: declared #{rule_bit_length} bits " \
              "(#{need_bytes} bytes), payload has #{stream.bytesize - cursor} bytes"
      end

      encoded = unpack_bits(stream[cursor, need_bytes], rule_bit_length)
      { name: name, zlb: zlb, encoded_rules: encoded, end: finish }
    end

    # Replays one pass in reverse: each '0' rule copies a kept column from the
    # current stripes; each '1' rule emits two columns — reverse(name, kept)
    # then kept. After the rule walk, a remaining trailing column (the one the
    # pass never inspected) is copied through.
    def reverse_pass(stripes, stripe_bit_length, raw_rules, name, parts)
      out = Array.new(parts) { +'' }
      ptr = 0
      i = 0
      while i < raw_rules.length
        case raw_rules[i]
        when '0'
          col = column_of(stripes, ptr, parts)
          append_column(out, col, parts)
          ptr += 1
        when '1'
          col = column_of(stripes, ptr, parts)
          append_column(out, Algorithms.reverse(name, col), parts)
          append_column(out, col, parts)
          ptr += 1
        else
          raise ArgumentError, "invalid rule bit at #{i}: #{raw_rules[i].inspect}"
        end
        i += 1
      end

      if ptr == stripe_bit_length - 1
        append_column(out, column_of(stripes, ptr, parts), parts)
      elsif ptr != stripe_bit_length
        raise ArgumentError,
              "rule walk left ptr=#{ptr} but stripe_bit_length=#{stripe_bit_length}"
      end

      [out, out.first&.length || 0]
    end

    def column_of(stripes, index, parts)
      buf = +''
      parts.times { |j| buf << stripes[j][index] }
      buf
    end

    def append_column(out, column_bits, parts)
      parts.times { |j| out[j] << column_bits[j] }
    end

    def deinterleave(stripes, parts, original_byte_count, leftover)
      stripe_len = stripes.first&.length || 0
      num_full_chunks = stripe_len / 8
      buf = String.new(capacity: original_byte_count, encoding: Encoding::ASCII_8BIT)
      num_full_chunks.times do |c|
        parts.times do |j|
          buf << stripes[j][c * 8, 8].to_i(2)
        end
      end
      leftover.each { |b| buf << b }
      buf
    end

    def unpack_bits(byte_string, bit_count)
      return ''.b.force_encoding(Encoding::US_ASCII) if bit_count.zero?

      bits = byte_string.unpack1('B*')
      bits[0, bit_count]
    end
  end
end
