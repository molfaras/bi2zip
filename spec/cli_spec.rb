# frozen_string_literal: true

require_relative 'spec_helper'
require 'bi2zip/cli'
require 'fileutils'
require 'stringio'
require 'tmpdir'

RSpec.describe Bi2zip::CLI do
  def run(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    code = described_class.run(argv, stdout: stdout, stderr: stderr)
    [stdout.string, stderr.string, code]
  end

  describe 'top-level --help' do
    it 'exits 0 and mentions both modes and the compress flags' do
      stdout, stderr, code = run('--help')
      expect(code).to eq(Bi2zip::CLI::EXIT_OK)
      expect(stderr).to eq('')
      expect(stdout).to include('compress')
      expect(stdout).to include('decompress')
      expect(stdout).to include('.bi2zip')
      expect(stdout).to include('--algorithms')
      expect(stdout).to include('--zlb')
      expect(stdout).to include('--max-passes')
      expect(stdout).to include('Exit codes:')
    end
  end

  describe 'top-level --version' do
    it 'prints the version' do
      stdout, _, code = run('--version')
      expect(code).to eq(Bi2zip::CLI::EXIT_OK)
      expect(stdout.strip).to eq("bi2zip #{Bi2zip::VERSION}")
    end
  end

  describe 'no arguments' do
    it 'exits 1 with a usage hint' do
      _, stderr, code = run
      expect(code).to eq(Bi2zip::CLI::EXIT_USAGE)
      expect(stderr).to include('missing input path')
    end
  end

  describe 'compress' do
    it 'writes a single .bi2zip file and no sidecars' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'sample.bin')
        File.binwrite(input, ("\x00" * 500).b)

        stdout, stderr, code = run(input)
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expect(stderr).to eq('')

        data_path = "#{input}.bi2zip"
        expect(File.file?(data_path)).to be(true)
        # No sidecars: the only path matching the input prefix is the input
        # itself plus the single .bi2zip output.
        expect(Dir.glob("#{input}*")).to contain_exactly(input, data_path)

        expect(stdout).to include('wrote ')
        expect(stdout).to include('passes=')
        expect(stdout).to include('ratio=')
      end
    end

    it 'exits 2 when the input file is missing' do
      stdout, stderr, code = run('/no/such/path/123')
      expect(code).to eq(Bi2zip::CLI::EXIT_INPUT)
      expect(stdout).to eq('')
      expect(stderr).to include('no such file')
    end

    it 'rejects out-of-range --parts via the validator' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'in.bin')
        File.binwrite(input, 'hi')
        _, stderr, code = run('--parts', '0', input)
        expect(code).to eq(Bi2zip::CLI::EXIT_INPUT)
        # validator message now mentions :auto since parts accepts it
        expect(stderr).to match(/parts must be :auto or an integer in 4\.\.16/)
      end
    end

    it 'rejects out-of-range --zlb via the validator' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'in.bin')
        File.binwrite(input, 'hi')
        _, stderr, code = run('--zlb', '17', input)
        expect(code).to eq(Bi2zip::CLI::EXIT_INPUT)
        expect(stderr).to match(/zlb/)
      end
    end

    it 'exits 1 on unknown option' do
      _, stderr, code = run('--bogus')
      expect(code).to eq(Bi2zip::CLI::EXIT_USAGE)
      expect(stderr).to include('invalid option')
    end

    it 'exits 1 on non-integer --zlb' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'in.bin')
        File.binwrite(input, 'hi')
        _, stderr, code = run('--zlb', 'pony', input)
        expect(code).to eq(Bi2zip::CLI::EXIT_USAGE)
        expect(stderr).to match(/invalid argument/)
      end
    end

    it 'aborts (no files written, exit 0, stderr message) when output would not shrink the input' do
      Dir.mktmpdir do |dir|
        # Random noise + tiny input: the global header alone exceeds the input,
        # so total output is guaranteed to be >= raw.bytesize.
        input = File.join(dir, 'noise.bin')
        File.binwrite(input, Random.new(99).bytes(8))

        stdout, stderr, code = run(input)
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expect(stderr).to match(/abort|would expand|not write/i)
        expect(stdout).to eq('')
        expect(Dir.glob("#{input}.bi2zip*")).to be_empty
      end
    end
  end

  describe 'compress + decompress round-trip' do
    it 'reproduces bytes exactly with defaults' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'payload.bin')
        original = ("\x00" * 1000).b
        File.binwrite(input, original)

        _, _, code = run(input)
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)

        stdout, stderr, code = run("#{input}.bi2zip")
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expect(stderr).to eq('')

        out_path = stdout.strip
        expect(File.binread(out_path)).to eq(original)
      end
    end

    it 'reproduces bytes with --algorithms eq,lgray' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'payload.bin')
        original = ("\x00" * 400).b
        File.binwrite(input, original)

        _, _, code = run('--algorithms', 'eq,lgray', input)
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)

        explicit_out = File.join(dir, 'restored.bin')
        _, _, code = run("#{input}.bi2zip", explicit_out)
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expect(File.binread(explicit_out)).to eq(original)
      end
    end

    it 'reproduces bytes with --zlb 5 --parts 8' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'payload.bin')
        original = ("\x00" * 300).b
        File.binwrite(input, original)

        _, _, code = run('--zlb', '5', '--parts', '8', input)
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)

        explicit_out = File.join(dir, 'restored.bin')
        _, _, code = run("#{input}.bi2zip", explicit_out)
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expect(File.binread(explicit_out)).to eq(original)
      end
    end
  end

  describe 'decompress (.bi2zip input)' do
    it 'writes to the original filename (trailing .bi2zip stripped) when nothing exists there' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'payload.bin')
        File.binwrite(input, ("\x00" * 200).b)
        run(input)
        # Remove the original so the default target is free.
        File.delete(input)

        stdout, _, code = run("#{input}.bi2zip")
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expect(stdout.strip).to eq(input)
        expect(File.file?(input)).to be(true)
      end
    end

    it 'inserts " (1)" before the last extension when the default target exists' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'payload.bin')
        File.binwrite(input, ("\x00" * 200).b)
        run(input)
        # `payload.bin` still exists, so the default target collides.

        stdout, _, code = run("#{input}.bi2zip")
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expected = File.join(dir, 'payload (1).bin')
        expect(stdout.strip).to eq(expected)
        expect(File.file?(expected)).to be(true)
      end
    end

    it 'increments to " (2)" when both the base and (1) variant exist' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'payload.bin')
        File.binwrite(input, ("\x00" * 200).b)
        run(input)
        File.binwrite(File.join(dir, 'payload (1).bin'), 'occupied')

        stdout, _, code = run("#{input}.bi2zip")
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expected = File.join(dir, 'payload (2).bin')
        expect(stdout.strip).to eq(expected)
        expect(File.file?(expected)).to be(true)
      end
    end

    it 'appends " (N)" to the whole basename when the stripped name has no extension' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'archive')
        File.binwrite(input, ("\x00" * 200).b)
        run(input)
        # `archive` still exists, forcing conflict resolution.

        stdout, _, code = run("#{input}.bi2zip")
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expected = File.join(dir, 'archive (1)')
        expect(stdout.strip).to eq(expected)
        expect(File.file?(expected)).to be(true)
      end
    end

    it 'inserts " (N)" before the last extension for multi-extension basenames' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'data.tar.gz')
        File.binwrite(input, ("\x00" * 200).b)
        run(input)
        # `data.tar.gz` still exists, forcing conflict resolution.

        stdout, _, code = run("#{input}.bi2zip")
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expected = File.join(dir, 'data.tar (1).gz')
        expect(stdout.strip).to eq(expected)
        expect(File.file?(expected)).to be(true)
      end
    end

    it 'uses an explicit output path as-is without conflict resolution' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'payload.bin')
        File.binwrite(input, ("\x00" * 200).b)
        run(input)

        explicit = File.join(dir, 'restored.bin')
        File.binwrite(explicit, 'will-be-overwritten')

        stdout, _, code = run("#{input}.bi2zip", explicit)
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expect(stdout.strip).to eq(explicit)
        expect(File.binread(explicit)).to eq(("\x00" * 200).b)
      end
    end

    it 'exits 2 cleanly when the input is just ".bi2zip"' do
      Dir.mktmpdir do |dir|
        seed = File.join(dir, 'x.bin')
        File.binwrite(seed, ("\x00" * 200).b)
        run(seed)
        data_path = File.join(dir, '.bi2zip')
        FileUtils.cp("#{seed}.bi2zip", data_path)
        _, stderr, code = run(data_path)
        expect(code).to eq(Bi2zip::CLI::EXIT_INPUT)
        expect(stderr).to match(/no name before/)
      end
    end

    it 'exits 2 when no data file is found' do
      Dir.mktmpdir do |dir|
        data_path = File.join(dir, 'nothing.bi2zip')
        _, stderr, code = run(data_path)
        expect(code).to eq(Bi2zip::CLI::EXIT_INPUT)
        expect(stderr).to include('no such file')
      end
    end

    it 'succeeds on incompressible input (zero passes)' do
      Dir.mktmpdir do |dir|
        # Compose a valid single-file artifact directly so we exercise the
        # zero-pass branch end-to-end on disk.
        original = Random.new(99).bytes(1000).bytes
        result = Bi2zip::Compress.call(bytes: original)
        expect(result.passes).to be_empty
        data_path = File.join(dir, 'noisy.bin.bi2zip')
        File.binwrite(data_path, result.bytes)

        _, _, code = run(data_path)
        expect(code).to eq(Bi2zip::CLI::EXIT_OK)
        expect(File.binread(File.join(dir, 'noisy.bin'))).to eq(original.pack('C*'))
      end
    end

    it 'exits 2 when the header reserved bits are non-zero' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'payload.bin')
        File.binwrite(input, ("\x00" * 240).b)
        run(input)

        data_path = "#{input}.bi2zip"
        bytes = File.binread(data_path).b
        bytes.setbyte(0, bytes.getbyte(0) | 0x01)
        File.binwrite(data_path, bytes)

        _, stderr, code = run(data_path)
        expect(code).to eq(Bi2zip::CLI::EXIT_INPUT)
        expect(stderr).to match(/reserved bits/)
      end
    end

    it 'refuses to overwrite the input file' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'payload.bin')
        File.binwrite(input, ("\x00" * 120).b)
        run(input)
        data_path = "#{input}.bi2zip"
        _, stderr, code = run(data_path, data_path)
        expect(code).to eq(Bi2zip::CLI::EXIT_INPUT)
        expect(stderr).to include('refusing to overwrite')
      end
    end
  end
end
