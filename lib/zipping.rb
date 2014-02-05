# -*- encoding: utf-8 -*-
require "zipping/version"
require 'zip'

module Zipping


  #
  # Constants
  #

  # header signatures
  ZS_c_pk0102        = 0x02014b50
  ZS_c_pk0304        = 0x04034b50
  ZS_c_pk0506        = 0x06054b50
  ZS_c_pk0708        = 0x08074b50

  # values for zip version
  ZS_c_ver_nocomp    = 0x000a
  ZS_c_ver_deflate   = 0x0014
  ZS_c_ver_made      = 0x0315

  # values for option
  ZS_c_opt_none      = 0x0000
  ZS_c_opt_0708      = 0x0008

  # compression types
  ZS_c_comp_deflate  = 0x0008
  ZS_c_comp_none     = 0x0000

  # empty values
  ZS_c_int2_zero     = 0x0000
  ZS_c_int4_zero     = 0x00000000

  # OS-specific attributes (OS X)
  ZS_c_oattr_dir     = 0x41ed4000
  ZS_c_oattr_file    = 0x81a44000
  ZS_c_oattr_symlink = 0xa1ed4000



  #
  # API methods
  #

  def self.files_to_zip(output_stream, files, file_division_size = 1048576, encoding = :utf8)
    builder = ZipBuilder.new output_stream, file_division_size, encoding
    builder.pack files
    builder.close
  end

  # use if you need to make File directly.
  def self.files_to_zipfile(path, files, encoding = :utf8)
    File.open(path, 'wb'){|f| files_to_zip f, files, 1048576, encoding}
  end

  # use if you need to make binary String directly.
  def self.files_to_zipdata(files, encoding = :utf8)
    files_to_zip ''.force_encoding('ASCII-8bit'), files, 1048576, encoding
  end



  #
  # Internal Classes
  #

  # Errors
  class Error < StandardError
  end

  # Output stream wrapper that measures size of stream passing through.
  class StreamMeter
    def initialize(output_stream)
      @output_stream = output_stream
      @size = 0
      @crc = Zlib.crc32
    end
    def << (data)
      @size += data.length
      @crc = Zlib.crc32 data, @crc
      @output_stream << data
    end
    attr_reader :size
    attr_reader :crc
  end

  class ZipBuilder

    # Initialize ZipBuilder.
    # 'files' must be a String(file or directory path), a Hash(entity), or an Array of Strings and/or Hashes.
    def initialize(output_stream, file_division_size = 1048576, encoding = :utf8)
      @output_stream = output_stream
      raise Error, 'Specified output stream does not support `<<\' method.' unless @output_stream.respond_to? :<<
      @o = StreamMeter.new output_stream
      @e = encoding
      @s = file_division_size
      raise Error, 'Bad file_division_size' unless @s.is_a?(Integer) && @s > 0
    end

    ### Attr controls

    def reset_state
      @pending_dirs = []
      @current_dir = {name: '', time: Time.now}
      @dp = []
    end

    def has_dir?
      ! @pending_dirs.empty?
    end

    def next_dir
      @pending_dirs.shift
    end

    def postpone_dir(dir)
      dir[:abs_path] = abs_path_for dir[:name] || File.basename(dir[:path])
      @pending_dirs << dir
    end

    def cd(dir)
      @current_dir = dir
    end

    def root_dir?
      @current_dir.nil? || @current_dir[:abs_path].nil?
    end

    def current_dir
      root_dir? ? '' : @current_dir[:abs_path]
    end

    def abs_path_for(name)
      root_dir? ? name : (@current_dir[:abs_path] + '/' + name)
    end

    def reset_stream_meter
      @o = StreamMeter.new @output_stream
    end

    def current_position
      @o.size
    end

    def remember_entry_info(dp = nil)
      @dp << (dp || @fixed_entity.merge(@write_result))

      ## fixed_entity
      # :filetime => Zip::DOSTime,
      # :binary_name => String,

      ## write_result
      # :offset => Integer,
      # :crc => Integer,
      # :complen => Integer,
      # :uncomplen => Integer
    end

    def each_entry_info
      @dp.each{|dp| yield dp} if block_given?
    end

    ### Conversions

    # Create an Array of entity Hashes.
    def self.to_entities(files)
      if files.is_a? Hash
        [files]
      elsif files.is_a? String
        [ZipBuilder.to_entity(files)].delete_if &:nil?
      elsif files.is_a? Array
        ret = []
        files.each{|f| ret << ZipBuilder.to_entity(f)}
        ret.delete_if &:nil?
      else
        []
      end
    end

    # Create an entity Hash with a path String
    def self.to_entity(path)
      return path if path.is_a?(Hash)
      return nil unless path.is_a?(String) && File.exists?(path)
      ret = {
        :path => path,
        :name => File.basename(path),
        :time => Time.now
      }
    end

    # Get entities of files in dir
    def subdir_entities(dir = @current_dir)
      Dir.glob(dir[:path] + '/*').map!{|path| {path: path, time: File.mtime(path), name: File.basename(path)}}
    end

    # Fix an entity: time -> DOSTime object, name -> abs path in zip & encoded
    def fix_entity(entity)
      @fixed_entity = {
        path: entity[:path],
        filetime: Zip::DOSTime.at(entity[:time] || File.mtime(entity[:path])),
        binary_name: string_to_bytes(abs_path_for(entity[:name] || File.basename(entity[:path])))
      }
    end

    # Create ASCII-8bits string. Also convert encoding if needed.
    def string_to_bytes(str)
      unless @e.nil? || @e == :utf8
        if @e == :shift_jis
          begin
            str = str.encode 'Shift_JIS', :invalid => :replace, :undef => :replace, :replace => '??'
          rescue => e
          end
        end
      end
      [str].pack('a*')
    end

    ### Compression operations

    # Pack file and directory entities and output to stream.
    def pack(files)
      entities = ZipBuilder.to_entities files
      return if entities.empty?

      reset_state
      pack_entities entities
      while has_dir?
        cd next_dir
        pack_current_dir
      end
    end

    # Pack a directory
    def pack_current_dir
      pack_entities subdir_entities
    end

    # Create central directories
    def close
      # start of central directories
      @header_offset = current_position
      write_central_dir_headers

      # total size of central directories
      @header_size = current_position - @header_offset
      write_end_central_dir_header
    end

    # Pack file entities. Directory entities are queued, not packed in this method.
    def pack_entities(entities)
      entities.each do |entity|
        # ignore bad entities
        next unless entity.is_a?(Hash) && entity[:path]

        path = entity[:path]
        if File.symlink? path
          pack_symbolic_link_entity entity
        elsif File.directory? path
          postpone_dir entity
        elsif File.file? path
          pack_file_entity entity
        end
      end
    end

    def pack_file_entity(entity)
      pack_entity entity do
        write_file_entry
      end
    end

    def pack_symbolic_link_entity(entity)
      pack_entity entity do
        write_symbolic_link_entry
      end
    end

    def pack_directory_entity(entity)
      pack_entity entity do
        write_directory_entry
      end
    end

    def pack_entity(entity)
      fix_entity entity
      yield
      remember_entry_info
    end


    ## Write methods

    # Write file entry
    def write_file_entry
      write_entry do |path, filetime, name|

        # write header
        @o << PKHeader.pk0304(filetime, name.length, true).pack('VvvvvvVVVvv')
        @o << name

        # write deflated data
        meter = StreamMeter.new @o
        deflater = Zip::Deflater.new meter
        File.open(path, 'rb'){|f| pipe_little_by_little deflater, f}
        deflater.finish

        # write trailer
        @o << PKHeader.pk0708(deflater.crc, meter.size, deflater.size).pack('VVVV')

        {
          crc: deflater.crc,
          complen: meter.size,
          uncomplen: deflater.size,
          deflated: true
        }
      end
    end

    # Write dir entry
    def write_directory_entry
      write_entry_without_compress '', :dir
    end

    # Write symbolic link entry
    def write_symbolic_link_entry
      write_entry_without_compress File.readlink(@fixed_entity[:path]), :symlink
    end

    def pipe_little_by_little(o, i)
      o << i.read(@s) until i.eof?
    end

    def write_entry_without_compress(data, type)
      write_entry do |path, filetime, name|
        crc = Zlib.crc32 data
        @o << PKHeader.pk0304(filetime, name.length, false, crc, data.size, data.size).pack('VvvvvvVVVvv')
        @o << name
        @o << data
        {
          type: type,
          crc: crc,
          complen: data.size,
          uncomplen: data.size
        }
      end
    end

    def write_entry
      offset = current_position
      write_result = yield @fixed_entity[:path], @fixed_entity[:filetime], @fixed_entity[:binary_name] if block_given?
      @write_result = write_result.merge({offset: offset, binary_name: @fixed_entity[:binary_name]})
    end

    # Write central directories.
    def write_central_dir_headers(o = @o, data_positions = @dp)
      data_positions.each do |dp|
        o << PKHeader.pk0102(dp).pack('VvvvvvvVVVvvvvvVV')
        o << dp[:binary_name]
      end
    end

    # Write end of central directory.
    def write_end_central_dir_header(o = @o, entry_count = @dp.length, dirsize = @header_size, offset = @header_offset)
      o << PKHeader.pk0506(entry_count, dirsize, offset).pack('VvvvvVVv')
    end
  end

  module PKHeader
    # 0102: central directory
    def self.pk0102(dp)
      # dp: info of an entry
      [
        ZS_c_pk0102,
        ZS_c_ver_made,
        (dp[:deflated] ? ZS_c_ver_nocomp : ZS_c_ver_deflate),
        (dp[:deflated] ? ZS_c_opt_0708 : ZS_c_opt_none),
        (dp[:deflated] ? ZS_c_comp_deflate : ZS_c_comp_none),
        dp[:filetime].to_binary_dos_time,
        dp[:filetime].to_binary_dos_date,
        dp[:crc],
        dp[:complen],
        dp[:uncomplen],
        dp[:binary_name].length,
        ZS_c_int2_zero,
        ZS_c_int2_zero,
        ZS_c_int2_zero,
        ZS_c_int2_zero,
        (dp[:type] == :symlink ? ZS_c_oattr_symlink : dp[:type] == :dir ? ZS_c_oattr_dir : ZS_c_oattr_file),
        dp[:offset]
      ]
    end

    # 0304: header of entries
    def self.pk0304(filetime, namelen, deflated, crc = nil, compsize = nil, uncompsize = nil)
      [
        ZS_c_pk0304,
        (deflated ? ZS_c_ver_deflate : ZS_c_ver_nocomp),
        (deflated ? ZS_c_opt_0708 : ZS_c_opt_none),
        (deflated ? ZS_c_comp_deflate : ZS_c_comp_none),
        filetime.to_binary_dos_time,
        filetime.to_binary_dos_date,
        (crc || ZS_c_int4_zero),
        (compsize || ZS_c_int4_zero),
        (uncompsize || ZS_c_int4_zero),
        namelen,
        ZS_c_int2_zero
      ]
    end

    # 0506: end of central directory
    def self.pk0506(entry_count, dirsize, offset)
      # entry_count: count of entries in zip
      # dirsize: sum of central directory sizes
      # offset: byte offset of the first central directory
      [
        ZS_c_pk0506,
        ZS_c_int2_zero,
        ZS_c_int2_zero,
        entry_count,
        entry_count,
        dirsize,
        offset,
        ZS_c_int2_zero
      ]
    end

    # 0708: optional trailer of entries
    def self.pk0708(crc, compsize, uncompsize)
      # crc: CRC32 for uncompressed data
      # compsize: size of compressed data
      # uncompsize: size of uncompressed data
      [
        ZS_c_pk0708,
        crc,
        compsize,
        uncompsize
      ]
    end
  end
end
