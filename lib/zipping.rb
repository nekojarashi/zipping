# -*- encoding: utf-8 -*-
require "zipping/version"
require "zipping/dos_time"
require "zipping/deflater"

require "zlib"
require 'pathname'

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
    output_stream
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
      @size += data.bytesize
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
      @w = Writer.new output_stream, file_division_size
      @e = encoding
      @l = []
    end

    ### Attr controls

    def reset_state
      @pending_dirs = []
      @current_dir = {name: '', time: Time.now}
    end

    def has_dir?
      ! @pending_dirs.empty?
    end

    def next_dir
      @pending_dirs.shift
    end

    def postpone_dir(dir)
      queue_entity dir, @pending_dirs
    end

    def postpone_symlink(link)
      queue_entity link, @l
    end

    def queue_entity(entity, queue)
      entity[:abs_path] = abs_path_for entity[:name] || File.basename(entity[:path])
      queue << entity
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

    def current_dir_entity
      @current_dir
    end

    def abs_path_for(name)
      root_dir? ? name : (@current_dir[:abs_path] + '/' + name)
    end

    def abs_path_for_entity(entity)
      abs_path_for entity[:name] || File.basename(entity[:path])
    end

    ### Conversions

    # Get entities of files in dir
    def subdir_entities(dir = @current_dir)
      Dir.glob(dir[:path].gsub(/[*?\\\[\]{}]/, '\\\\\0') + '/*').map!{|path| {path: path, time: File.mtime(path), name: File.basename(path)}}
    end

    # Fix an entity: time -> DOSTime object, name -> abs path in zip & encoded
    def fix_entity(entity)
      {
        path: entity[:path],
        filetime: DOSTime.new(entity[:time] || File.mtime(entity[:path])),
        binary_name: string_to_bytes(abs_path_for_entity(entity)),
        zip_path: abs_path_for_entity(entity)
      }
    end

    def fix_current_dir_entity
      fix_entity(@current_dir).merge!(
        {
          binary_name: string_to_bytes(@current_dir[:abs_path] + '/'),
          zip_path: @current_dir[:abs_path]
        }
      )
    end

    # Create ASCII-8bits string. Also convert encoding if needed.
    def string_to_bytes(str)
      unless @e.nil? || @e == :utf8
        if @e == :shift_jis
          begin
            str = str.gsub /[\\:*?"<>|\uff5e]/, '？'
            str.encode! 'Shift_JIS', :invalid => :replace, :undef => :replace, :replace => '？'
          rescue => e
          end
        end
      end
      [str].pack('a*')
    end

    ### Compression operations

    # Pack file and directory entities and output to stream.
    def pack(files)
      entities = Entity.entities_from files
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
      pack_current_directory_entity
      pack_entities subdir_entities
    end

    # Pack symlinks if its link path exists in zip
    def pack_symlinks
      reset_state
      @l.each do |link|
        if @w.path_exists? Entity.linked_path(link[:abs_path], File.readlink(link[:path]))
          link[:name] = link[:abs_path]
          pack_symbolic_link_entity link
        end
      end
    end

    # Create central directories
    def close
      pack_symlinks
      @w.close
    end

    # Pack file entities. Directory entities are queued, not packed in this method.
    def pack_entities(entities)
      entities.each do |entity|
        # ignore bad entities
        next unless entity.is_a?(Hash) && entity[:path]

        path = entity[:path]
        if File.symlink? path
          postpone_symlink entity
        elsif File.directory? path
          postpone_dir entity
        elsif File.file? path
          pack_file_entity entity
        end
      end
    end

    def pack_file_entity(entity)
      pack_entity entity do
        @w.write_file_entry
      end
    end

    def pack_symbolic_link_entity(entity)
      pack_entity entity do
        @w.write_symbolic_link_entry
      end
    end

    def pack_current_directory_entity
      @w.load_entity fix_current_dir_entity
      @w.write_directory_entry
    end

    def pack_entity(entity)
      @w.load_entity fix_entity entity
      yield
    end
  end

  class Writer

    def initialize(output_stream, file_division_size)
      @output_stream = output_stream
      raise Error, 'Specified output stream does not support `<<\' method.' unless @output_stream.respond_to? :<<
      @o = StreamMeter.new output_stream
      @s = file_division_size
      raise Error, 'Bad file_division_size' unless @s.is_a?(Integer) && @s > 0
      @dps = []
      @entries = []
    end

    ### Data interface

    def load_entity(entity)
      @fixed_entity = entity
      @entries << entity[:zip_path]
    end

    def path_exists?(abs_path)
      @entries.include? abs_path
    end

    ### Write operations

    def write_file_entry
      write_entry do |path, filetime, name|
        write PKHeader.pk0304(filetime, name.length, true).pack('VvvvvvVVVvv'), name
        ret = deflate_file path
        write PKHeader.pk0708(ret[:crc], ret[:complen], ret[:uncomplen]).pack('VVVV')
        ret
      end
    end

    def write_directory_entry
      write_entry_without_compress '', :dir
    end

    def write_symbolic_link_entry
      write_entry_without_compress File.readlink(@fixed_entity[:path]), :symlink
    end

    def close
      # start of central directories
      @header_offset = current_position
      write_central_dir_headers

      # total size of central directories
      @header_size = current_position - @header_offset
      write_end_central_dir_header
    end

    ### Internal methods
    private

    def write(*args)
      args.each do |content|
        @o << content
      end
    end

    def current_position
      @o.size
    end

    def pipe_little_by_little(o, i)
      o << i.read(@s) until i.eof?
    end

    def deflate_file(path)
      meter = StreamMeter.new @o
      deflater = Deflater.new meter
      File.open(path, 'rb'){|f| pipe_little_by_little deflater, f}
      deflater.finish
      {
        crc: deflater.crc,
        complen: meter.size,
        uncomplen: deflater.size,
        deflated: true
      }
    end

    def write_entry_without_compress(data, type)
      write_entry do |path, filetime, name|
        crc = Zlib.crc32 data
        write PKHeader.pk0304(filetime, name.length, false, crc, data.size, data.size).pack('VvvvvvVVVvv'), name, data
        {
          type: type,
          crc: crc,
          complen: data.size,
          uncomplen: data.size
        }
      end
    end

    def write_entry
      remember_entry_info current_position, yield(@fixed_entity[:path], @fixed_entity[:filetime], @fixed_entity[:binary_name])
    end

    def remember_entry_info(offset, write_result)
      @dps << @fixed_entity.merge!(write_result).merge!({offset: offset})
    end

    def write_central_dir_headers
      @dps.each do |dp|
        write PKHeader.pk0102(dp).pack('VvvvvvvVVVvvvvvVV'), dp[:binary_name]
      end
    end

    def write_end_central_dir_header
      write PKHeader.pk0506(@dps.length, @header_size, @header_offset).pack('VvvvvVVv')
    end
  end

  class Entity
    def self.entities_from(files)
      if files.is_a? Array
        entities_from_array files
      else
        [entity_from(files)]
      end
    end

    # Create an entity Hash with a path String
    def self.entity_from(ent)
      if ent.is_a?(Hash) && File.exists?(ent[:path])
        ent
      elsif ent.is_a?(String) && File.exists?(ent)
        entity_from_path ent
      end
    end

    def self.entities_from_array(arr)
      arr.map{|ent| entity_from ent}.delete_if(&:nil?)
    end

    def self.entity_from_path(path)
      {
        :path => path,
        :name => File.basename(path),
        :time => File.mtime(path)
      }
    end

    def self.linked_path(abs_path, link)
      (Pathname.new(abs_path).parent + link).expand_path('/').to_s[1..-1]
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
        dp[:filetime].dos_time,
        dp[:filetime].dos_date,
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
        filetime.dos_time,
        filetime.dos_date,
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
