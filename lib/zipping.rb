# -*- encoding: utf-8 -*-
require "zipping/version"
require 'zip'

module Zipping


  #
  # Constants
  #

  ZS_c_pk0102        = 0x02014b50
  ZS_c_pk0304        = 0x04034b50
  ZS_c_pk0506        = 0x06054b50
  ZS_c_pk0708        = 0x08074b50
  ZS_c_ver_dir       = 0x000a
  ZS_c_ver_file      = 0x0014
  ZS_c_ver_made      = 0x0315
  ZS_c_opt_none      = 0x0000
  ZS_c_opt_nosize    = 0x0008
  ZS_c_comp_deflate  = 0x0008
  ZS_c_int2_zero     = 0x0000
  ZS_c_int4_zero     = 0x00000000

  ZS_c_oattr_dir     = 0x41ed4000
  ZS_c_oattr_file    = 0x81a44000



  #
  # API methods
  #

  def self.files_to_zip(output_stream, files, encoding = :utf8, file_division_size = 1048576)
    builder = ZipBuilder.new output_stream, files, encoding, file_division_size
    builder.pack
  end

  # Deprecated.
  # Recommended to use 'files_to_zip' instead.
  def self.directory_to_zip(output_stream, target_path, usesjis = true, file_division_size = 1048576)
    self.create_zip_file_with_files_and_directories(output_stream, target_path, usesjis, file_division_size)
  end

  # Deprecated.
  # Recommended to use 'files_to_zip' instead.
  def self.file_to_zip(output_stream, target_path, usesjis = false, file_division_size = 1048576)
    self.create_zip_file_with_files_and_directories(output_stream, target_path, usesjis, file_division_size)
  end



  #
  # Internal Classes
  #

  # Output stream wrapper that measures size of stream passing through.
  class StreamMeter
    def initialize(output_stream)
      @output_stream = output_stream
      @size = 0
    end
    def << (data)
      @size += data.length
      @output_stream << data
    end
    attr_reader :size
  end

  class ZipBuilder

    # Initialize ZipBuilder.
    # 'files' must be a String(file or directory path), a Hash(entity), or an Array of Strings and/or Hashes.
    def initialize(output_stream, files, encoding = :utf8, file_division_size = 1048576)
      @o = output_stream
      @f = ZipBuilder.to_entities files
      @e = encoding
      @s = file_division_size
    end

    # Create an Array of entity Hashes.
    def self.to_entities(files)
      if files.is_a? Hash
        ret = [files]
      elsif files.is_a? String
        entity = ZipBuilder.to_entity(files)
        ret = entity.nil? ? [] : [entity]
      elsif files.is_a? Array
        ret = []
        files.each do |f|
          entity = ZipBuilder.to_entity(f)
          ret << entity unless entity.nil?
        end
      else
        ret = []
      end
      ret
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

    # Create ASCII-8bits string. Also convert encoding if needed.
    def self.to_bytes(str, encoding = :utf8)
      unless encoding.nil? || encoding == :utf8
        case encoding
        when :shift_jis
          begin
            str = str.encode 'Shift_JIS', :invalid => :replace, :undef => :replace, :replace => '??'
          rescue => e
          end
        end
      end
      [str].pack('a*')
    end

    # Pack file and directory entities and output to stream.
    def pack
      return if @f.empty?

      # directory entities found but not packed
      @pending_dirs = []

      # current directory
      @current_dir = ''
      @current_dir_created_at = Time.now

      # data of positions necessary to create headers
      @dp = []

      o = StreamMeter.new @o

      # pack file entities, store directory entities into @pending_dirs
      pack_file_entities o

      # retrieve and pack stored directories
      until @pending_dirs.empty? do

        current_dir = @pending_dirs.shift
        @current_dir = current_dir[:name] << '/'
        @current_dir_created_at = current_dir[:time]

        # write directory entry
        pack_directory o, current_dir[:time]

        begin
          # get files in the directory
          files = Dir.glob(current_dir[:path] + '/*')

          # pack files, store directories as entities into @pending_dirs
          pack_files o, files, current_dir
        rescue => e
        end
      end

      # prepare to create headers
      @header_offset = o.size
      o = StreamMeter.new(@o)

      # write headers
      write_central_dir_headers o
      @header_size = o.size
      write_end_central_dir_header
    end

    # Pack file entities and output to stream. Directory entities are not packed but stored.
    def pack_file_entities(o = @o, files = @f, dir = @current_dir, dirs = @pending_dirs, data_positions = @dp, encoding = @e, file_division_size = @s)
      files.each do |file|
        next unless file.is_a?(Hash) && file[:path]

        f = file[:path]
        if File.directory? f
          dirs << file
          next
        end
        next unless File.file? f
        data_offset = o.size
        file_path = f
        fname = dir.clone << (file[:name] || File.basename(file_path))
        bfname = ZipBuilder.to_bytes(fname, encoding)
        filetime = Zip::DOSTime.at(file[:time] || File.mtime(file_path))
        filesize = File.size(file_path)
        pk = [
          ZS_c_pk0304,
          ZS_c_ver_file,
          ZS_c_opt_nosize,
          ZS_c_comp_deflate,
          filetime.to_binary_dos_time,
          filetime.to_binary_dos_date,
          ZS_c_int4_zero,
          ZS_c_int4_zero,
          ZS_c_int4_zero,
          bfname.length,
          ZS_c_int2_zero
        ]
        bin = pk.pack('VvvvvvVVVvv')
        o << bin
        bin = bfname
        o << bin

        m = StreamMeter.new(o)
        d = Zip::Deflater.new(m)
        File.open(file_path) do |f|
          cur_filesize = filesize
          while cur_filesize > 0
            if cur_filesize >= file_division_size
              d << f.read(file_division_size)
              cur_filesize -= file_division_size
            else
              d << f.read(cur_filesize)
              cur_filesize = 0
            end
          end
        end
        d.finish

        pk = [
          ZS_c_pk0708,
          d.crc,
          m.size,
          d.size
        ]
        bin = pk.pack('VVVV')
        o << bin
        data_positions << {
          :folder => false,
          :file => fname,
          :file_dos_time => filetime.to_binary_dos_time,
          :file_dos_date => filetime.to_binary_dos_date,
          :binary_fname => bfname,
          :offset => data_offset,
          :crc => d.crc,
          :complen => m.size,
          :uncomplen => d.size
        }
      end
    end

    # Pack directory and output to stream.
    def pack_directory(o = @o, time_created_at = @current_dir_created_at, dir = @current_dir, data_positions = @dp, encoding = @e)
      bdir = ZipBuilder.to_bytes(dir, encoding)
      data_offset = o.size
      filetime = Zip::DOSTime.at(time_created_at);
      filesize = 0
      pk = [
        ZS_c_pk0304,
        ZS_c_ver_dir,
        ZS_c_opt_none,
        ZS_c_comp_deflate,
        filetime.to_binary_dos_time,
        filetime.to_binary_dos_date,
        ZS_c_int4_zero,
        ZS_c_int4_zero,
        ZS_c_int4_zero,
        bdir.length,
        ZS_c_int2_zero
      ]
      bin = pk.pack('VvvvvvVVVvv')
      o << bin
      bin = bdir
      o << bin
      data_positions << {
        :folder => true,
        :file => dir,
        :file_dos_time => filetime.to_binary_dos_time,
        :file_dos_date => filetime.to_binary_dos_date,
        :binary_fname => bdir,
        :offset => data_offset,
        :crc => ZS_c_int4_zero,
        :complen => ZS_c_int4_zero,
        :uncomplen => ZS_c_int4_zero
      }
    end

    # Pack files and output to stream. Directories are not packed but stored.
    def pack_files(o, files, dir, dirs = @pending_dirs, data_positions = @dp, encoding = @e, file_division_size = @s)
      files.each do |f|
        if File.directory? f
          dirs << {
            :path => f,
            :name => dir[:name] + File.basename(f),
            :time => dir[:time]
          }
          next
        end
        next unless File.file? f
        data_offset = o.size
        file_path = f
        file = dir[:name] + File.basename(file_path)
        bfile = ZipBuilder.to_bytes(file, encoding)
        filetime = Zip::DOSTime.at(dir[:time] || File.mtime(file_path))
        filesize = File.size(file_path)
        pk = [
          ZS_c_pk0304,
          ZS_c_ver_file,
          ZS_c_opt_nosize,
          ZS_c_comp_deflate,
          filetime.to_binary_dos_time,
          filetime.to_binary_dos_date,
          ZS_c_int4_zero,
          ZS_c_int4_zero,
          ZS_c_int4_zero,
          bfile.length,
          ZS_c_int2_zero
        ]
        bin = pk.pack('VvvvvvVVVvv')
        o << bin
        bin = bfile
        o << bin

        m = StreamMeter.new(o)
        d = Zip::Deflater.new(m)
        File.open(file_path) do |f|
          cur_filesize = filesize
          while cur_filesize > 0
            if cur_filesize >= file_division_size
              d << f.read(file_division_size)
              cur_filesize -= file_division_size
            else
              d << f.read(cur_filesize)
              cur_filesize = 0
            end
          end
        end
        d.finish

        pk = [
          ZS_c_pk0708,
          d.crc,
          m.size,
          d.size
        ]
        bin = pk.pack('VVVV')
        o << bin
        data_positions << {
          :folder => false,
          :file => file,
          :file_dos_time => filetime.to_binary_dos_time,
          :file_dos_date => filetime.to_binary_dos_date,
          :binary_fname => bfile,
          :offset => data_offset,
          :crc => d.crc,
          :complen => m.size,
          :uncomplen => d.size
        }
      end
    end

    # Write central directories.
    def write_central_dir_headers(o = @o, data_positions = @dp)
      data_positions.each do |dp|
        pk = [
          ZS_c_pk0102,
          ZS_c_ver_made,
          (dp[:folder] ? ZS_c_ver_dir : ZS_c_ver_file),
          ZS_c_opt_nosize,
          ZS_c_comp_deflate,
          dp[:file_dos_time],
          dp[:file_dos_date],
          dp[:crc],
          dp[:complen],
          dp[:uncomplen],
          dp[:binary_fname].length,
          ZS_c_int2_zero,
          ZS_c_int2_zero,
          ZS_c_int2_zero,
          ZS_c_int2_zero,
          (dp[:folder] ? ZS_c_oattr_dir : ZS_c_oattr_file),
          dp[:offset]
        ]
        bin = pk.pack('VvvvvvvVVVvvvvvVV')
        o << bin
        bin = dp[:binary_fname]
        o << bin
      end
    end

    # Write end of central directory.
    def write_end_central_dir_header(o = @o, entry_count = @dp.length, dirsize = @header_size, offset = @header_offset)
      pk = [
        ZS_c_pk0506,
        ZS_c_int2_zero,
        ZS_c_int2_zero,
        entry_count,
        entry_count,
        dirsize,
        offset,
        ZS_c_int2_zero
      ]
      o << pk.pack('VvvvvVVv')
    end
  end


  #
  # Internal method
  #

  # Pack files into zip.
  # You must pass an entity Hash (or Array of them) consists of :path(path of file to pack into zip) and :name(file path inside zip) to this method as 'target_files'.
  # Optionally, you may add :time(time created at) to the entity Hashes.
  def self.create_zip_file_with_file_entities(outputStream, target_files, usesjis = true, file_division_size = 1048576)
    begin

      # prepare entry list for zip
      target_files = [target_files] unless target_files.instance_of? Array
      entries = []
      target_files.each do |file|
        if file.is_a? String
          begin
            entry = {
              :path => file,
              :name => File.basename(file),
              :time => File.mtime(file)
            }
          rescue => e
            next
          end
        elsif file.is_a? Hash
          next unless file[:path] && file[:path].is_a?(String)
          entry = file
          path = entry[:path]
          entry[:name] = File.basename(path) unless entry[:name] && entry[:name].is_a?(String)
          entry[:time] = File.mtime(path) unless entry[:time] && entry[:time].is_a?(Time)
        else
          next
        end
        entries << entry
      end
      return if entries.empty?

      # prepare to measure stream size
      o = StreamMeter.new(outputStream)

      # container to collect header info
      data_positions = []

      # compress entries
      self.compress_entries(o, entries, data_positions, usesjis, file_division_size)

      # measure stream size
      pk0102_offset = o.size

      # prepare to measure header size
      m = StreamMeter.new(o)

      # write headers
      self.create_central_dir_headers(m, data_positions)

      # measure header size
      pk0102_size = m.size

      # write tail header
      self.create_end_cent_dir_header(o, data_positions.length, pk0102_size, pk0102_offset)
    rescue => e
    end
  end

  # Pack files and folders into zip.
  # All files in folders are also packed into zip, and the structure inside folders are conserved.
  def self.create_zip_file_with_files_and_directories(outputStream, target_files, usesjis = true, file_division_size = 1048576)
    begin

      target_files = [target_files] unless target_files.instance_of? Array
      return if target_files.empty?

      dirs = []
      o = StreamMeter.new(outputStream)
      data_positions = []

      self.compress_file_list(o, target_files, "", dirs, data_positions, usesjis, file_division_size)

      while dirs.length > 0 do
        current_directory = dirs.shift
        dir_path = current_directory[0]
        dir = current_directory[1]
        dir << '/'
        self.create_directory_entry(o, dir_path, dir, data_positions, usesjis, file_division_size)

        files = Dir.glob(dir_path << '/*')
        self.compress_file_list(o, files, dir, dirs, data_positions, usesjis, file_division_size)

      end

      pk0102_offset = o.size
      m = StreamMeter.new(o)
      self.create_central_dir_headers(m, data_positions)

      self.create_end_cent_dir_header(o, data_positions.length, m.size, pk0102_offset)
    rescue => e
    end
  end

  # Get file name as ASCII-8bits.
  # If needed, also convert encoding.
  def self.get_binary_fname(str, usesjis)
    if usesjis
      begin
        str = str.encode 'Shift_JIS', :invalid => :replace, :replace => '??'
      rescue => e
      end
    end
    return [str].pack('a*')
  end

  # Write directory entry.
  #
  def self.create_directory_entry(o, dir_path, dir, data_positions, usesjis = false, file_division_size = 1048576)
    bdir = self.get_binary_fname(dir, usesjis)
    data_offset = o.size
    filetime = Zip::DOSTime.at(File.mtime(dir_path))
    filesize = 0
    pk = [
      ZS_c_pk0304,
      ZS_c_ver_dir,
      ZS_c_opt_none,
      ZS_c_comp_deflate,
      filetime.to_binary_dos_time,
      filetime.to_binary_dos_date,
      ZS_c_int4_zero,
      ZS_c_int4_zero,
      ZS_c_int4_zero,
      bdir.length,
      ZS_c_int2_zero
    ]
    bin = pk.pack('VvvvvvVVVvv')
    o << bin
    bin = bdir
    o << bin
    data_positions << {
      :folder => true,
      :file => dir,
      :file_dos_time => filetime.to_binary_dos_time,
      :file_dos_date => filetime.to_binary_dos_date,
      :binary_fname => bdir,
      :offset => data_offset,
      :crc => ZS_c_int4_zero,
      :complen => ZS_c_int4_zero,
      :uncomplen => ZS_c_int4_zero
    }
  end

  def self.compress_entries(o, entries, data_positions, usesjis = false, file_division_size = 1048576)
    # `o' must be an output stream which has `size' method

    entries.each do |entry|
      path = entry[:path]
      name = entry[:name]
      mtime = entry[:time]

      next if File.directory? path
      next unless File.file? path
      data_offset = o.size
      b_name = self.get_binary_fname(name, usesjis)
      filesize = File.size(path)
      pk = [
        ZS_c_pk0304,
        ZS_c_ver_file,
        ZS_c_opt_nosize,
        ZS_c_comp_deflate,
        mtime.to_binary_dos_time,
        mtime.to_binary_dos_date,
        ZS_c_int4_zero,
        ZS_c_int4_zero,
        ZS_c_int4_zero,
        b_name.length,
        ZS_c_int2_zero
      ]
      bin = pk.pack('VvvvvvVVVvv')
      o << bin
      bin = b_name
      o << bin

      m = StreamMeter.new(o)
      d = Zip::Deflater.new(m)
      File.open(path) do |f|
        cur_filesize = filesize
        while cur_filesize > 0
          if cur_filesize >= file_division_size
            d << f.read(file_division_size)
            cur_filesize -= file_division_size
          else
            d << f.read(cur_filesize)
            cur_filesize = 0
          end
        end
      end
      d.finish

      pk = [
        ZS_c_pk0708,
        d.crc,
        m.size,
        d.size
      ]
      bin = pk.pack('VVVV')
      o << bin
      data_positions << {
        :folder => false,
        :file => name,
        :file_dos_time => filetime.to_binary_dos_time,
        :file_dos_date => filetime.to_binary_dos_date,
        :binary_fname => b_name,
        :offset => data_offset,
        :crc => d.crc,
        :complen => m.size,
        :uncomplen => d.size
      }
    end

  end

  def self.compress_file_list(o, files, dir, dirs, data_positions, usesjis = false, file_division_size = 1048576)
    files.each do |f|
      if File.directory? f
        dirs << [f, dir.clone << File.basename(f)]
        next
      end
      next unless File.file? f
      data_offset = o.size
      file_path = f
      file = dir.clone << File.basename(file_path)
      bfile = self.get_binary_fname(file, usesjis)
      filetime = Zip::DOSTime.at(File.mtime(file_path))
      filesize = File.size(file_path)
      pk = [
        ZS_c_pk0304,
        ZS_c_ver_file,
        ZS_c_opt_nosize,
        ZS_c_comp_deflate,
        filetime.to_binary_dos_time,
        filetime.to_binary_dos_date,
        ZS_c_int4_zero,
        ZS_c_int4_zero,
        ZS_c_int4_zero,
        bfile.length,
        ZS_c_int2_zero
      ]
      bin = pk.pack('VvvvvvVVVvv')
      o << bin
      bin = bfile
      o << bin

      m = StreamMeter.new(o)
      d = Zip::Deflater.new(m)
      File.open(file_path) do |f|
        cur_filesize = filesize
        while cur_filesize > 0
          if cur_filesize >= file_division_size
            d << f.read(file_division_size)
            cur_filesize -= file_division_size
          else
            d << f.read(cur_filesize)
            cur_filesize = 0
          end
        end
      end
      d.finish

      pk = [
        ZS_c_pk0708,
        d.crc,
        m.size,
        d.size
      ]
      bin = pk.pack('VVVV')
      o << bin
      data_positions << {
        :folder => false,
        :file => file,
        :file_dos_time => filetime.to_binary_dos_time,
        :file_dos_date => filetime.to_binary_dos_date,
        :binary_fname => bfile,
        :offset => data_offset,
        :crc => d.crc,
        :complen => m.size,
        :uncomplen => d.size
      }
    end

  end

  def self.create_central_dir_headers(o, data_positions)
      data_positions.each do |dp|
        pk = [
          ZS_c_pk0102,
          ZS_c_ver_made,
          (dp[:folder] ? ZS_c_ver_dir : ZS_c_ver_file),
          ZS_c_opt_nosize,
          ZS_c_comp_deflate,
          dp[:file_dos_time],
          dp[:file_dos_date],
          dp[:crc],
          dp[:complen],
          dp[:uncomplen],
          dp[:binary_fname].length,
          ZS_c_int2_zero,
          ZS_c_int2_zero,
          ZS_c_int2_zero,
          ZS_c_int2_zero,
          (dp[:folder] ? ZS_c_oattr_dir : ZS_c_oattr_file),
          dp[:offset]
        ]
        bin = pk.pack('VvvvvvvVVVvvvvvVV')
        o << bin
        bin = dp[:binary_fname]
        o << bin
      end
  end

  def self.create_end_cent_dir_header(o, entry_count, dirsize, offset)
      pk = [
        ZS_c_pk0506,
        ZS_c_int2_zero,
        ZS_c_int2_zero,
        entry_count,
        entry_count,
        dirsize,
        offset,
        ZS_c_int2_zero
      ]
      o << pk.pack('VvvvvVVv')
  end
end