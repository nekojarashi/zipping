require 'rubygems'
require 'zip/zip'

module Zipping
  def self.get_binary_fname(str, usesjis)
    if usesjis
      begin
        str = str.encode 'Shift_JIS', :invalid => :replace, :replace => '??'
      rescue => e
      end
    end
    return [str].pack('a*')
  end

  class StreamMeter
    def initialize(outputStream)
      @outputStream = outputStream
      @size = 0
    end
    def << (data)
      @size += data.length
      @outputStream << data
    end
    attr_reader :size
  end

  def self.directory_to_zip(o, entry_real_path, usesjis = true)
    begin
      c_pk0102        = 0x02014b50
      c_pk0304        = 0x04034b50
      c_pk0506        = 0x06054b50
      c_pk0708        = 0x08074b50
      c_ver_dir       = 0x000a
      c_ver_file      = 0x0014
      c_ver_made      = 0x0315
      c_opt_none      = 0x0000
      c_opt_nosize    = 0x0008
      c_comp_deflate  = 0x0008
      c_int2_zero     = 0x0000
      c_int4_zero     = 0x00000000

      c_oattr_dir     = 0x41ed4000
      c_oattr_file    = 0x81a44000

      data_positions = []
      pk0102_length = 0
      current_pos = 0

      file_division_size = 1048576

      dirs = [[entry_real_path, File.basename(entry_real_path)]]

      while dirs.length > 0 do
        current_directory = dirs.shift
        realdir = current_directory[0]
        dir = current_directory[1]
        dir << '/'
        bdir = self.get_binary_fname(dir, usesjis)

        data_offset = current_pos
        filetime = Zip::DOSTime.at(File.mtime(realdir))
        filesize = 0
        pk = [
          c_pk0304,
          c_ver_dir,
          c_opt_none,
          c_comp_deflate,
          filetime.to_binary_dos_time,
          filetime.to_binary_dos_date,
          c_int4_zero,
          c_int4_zero,
          c_int4_zero,
          bdir.length,
          c_int2_zero
        ]
        bin = pk.pack('VvvvvvVVVvv')
        current_pos += bin.length
        o << bin
        bin = bdir
        current_pos += bin.length
        o << bin
        data_positions << {
          :folder => true,
          :file => dir,
          :binary_fname => bdir,
          :offset => data_offset,
          :crc => c_int4_zero,
          :complen => c_int4_zero,
          :uncomplen => c_int4_zero
        }

        files = Dir.glob(realdir << '/*')
      
        files.each do |f|
          if File.directory? f
            dirs << [f, dir.clone << File.basename(f)]
            next
          end
          next unless File.file? f
          data_offset = current_pos
          realfile = f
          file = dir.clone << File.basename(realfile)
          bfile = self.get_binary_fname(file, usesjis)
          filetime = Zip::DOSTime.at(File.mtime(realfile))
          filesize = File.size(realfile)
          pk = [
            c_pk0304,
            c_ver_file,
            c_opt_nosize,
            c_comp_deflate,
            filetime.to_binary_dos_time,
            filetime.to_binary_dos_date,
            c_int4_zero,
            c_int4_zero,
            c_int4_zero,
            bfile.length,
            c_int2_zero
          ]
          bin = pk.pack('VvvvvvVVVvv')
          current_pos += bin.length
          o << bin
          bin = bfile
          current_pos += bin.length
          o << bin

          ofile = StreamMeter.new(o)
          d = Zip::Deflater.new(ofile)
          File.open(realfile) do |f|
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
          current_pos += ofile.size

          pk = [
            c_pk0708,
            d.crc,
            ofile.size,
            d.size
          ]
          bin = pk.pack('VVVV')
          current_pos += bin.length
          o << bin
          data_positions << {
            :folder => false,
            :file => file,
            :binary_fname => bfile,
            :offset => data_offset,
            :crc => d.crc,
            :complen => ofile.size,
            :uncomplen => d.size
          }
        end

      end

      pk0102_offset = current_pos

      data_positions.each do |dp|
        pk = [
          c_pk0102,
          c_ver_made,
          (dp[:folder] ? c_ver_dir : c_ver_file),
          c_opt_nosize,
          c_comp_deflate,
          filetime.to_binary_dos_time,
          filetime.to_binary_dos_date,
          dp[:crc],
          dp[:complen],
          dp[:uncomplen],
          dp[:binary_fname].length,
          c_int2_zero,
          c_int2_zero,
          c_int2_zero,
          c_int2_zero,
          (dp[:folder] ? c_oattr_dir : c_oattr_file),
          dp[:offset]
        ]
        bin = pk.pack('VvvvvvvVVVvvvvvVV')
        pk0102_length += bin.length
        current_pos += bin.length
        o << bin
        bin = dp[:binary_fname]
        pk0102_length += bin.length
        current_pos += bin.length
        o << bin
      end

      pk = [
        c_pk0506,
        c_int2_zero,
        c_int2_zero,
        data_positions.length,
        data_positions.length,
        pk0102_length,
        pk0102_offset,
        c_int2_zero
      ]
      o << pk.pack('VvvvvVVv')
    rescue => e
      logger.debug "------------ERROE:ArchivedFolder---" << entry_real_path.clone << ' detail:' << e.message
      #o << "------------ERROE:ArchivedFolder---" << entry_real_path.clone << ' detail:' << e.message
    end
  end

  def self.file_to_zip(o, entry_real_path, usesjis = false)
    begin
      c_pk0102        = 0x02014b50
      c_pk0304        = 0x04034b50
      c_pk0506        = 0x06054b50
      c_pk0708        = 0x08074b50
      c_ver_file      = 0x0014
      c_ver_made      = 0x0315
      c_opt_none      = 0x0000
      c_opt_nosize    = 0x0008
      c_comp_deflate  = 0x0008
      c_int2_zero     = 0x0000
      c_int4_zero     = 0x00000000

      c_oattr_file    = 0x81a44000

      data_positions = []
      pk0102_length = 0
      current_pos = 0

      file_division_size = 1048576

      f = entry_real_path

      data_offset = current_pos
      realfile = f
      file = File.basename(realfile)
      bfile = self.get_binary_fname(file, usesjis)
      filetime = Zip::DOSTime.at(File.mtime(realfile))
      filesize = File.size(realfile)
      pk = [
        c_pk0304,
        c_ver_file,
        c_opt_nosize,
        c_comp_deflate,
        filetime.to_binary_dos_time,
        filetime.to_binary_dos_date,
        c_int4_zero,
        c_int4_zero,
        c_int4_zero,
        bfile.length,
        c_int2_zero
      ]
      bin = pk.pack('VvvvvvVVVvv')
      current_pos += bin.length
      o << bin
      bin = bfile
      current_pos += bin.length
      o << bin

      ofile = StreamMeter.new(o)
      d = Zip::Deflater.new(ofile)
      File.open(realfile) do |f|
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
      current_pos += ofile.size

      pk = [
        c_pk0708,
        d.crc,
        ofile.size,
        d.size
      ]
      bin = pk.pack('VVVV')
      current_pos += bin.length
      o << bin
      data_positions << {
        :folder => false,
        :file => file,
        :binary_fname => bfile,
        :offset => data_offset,
        :crc => d.crc,
        :complen => ofile.size,
        :uncomplen => d.size
      }

      pk0102_offset = current_pos

      data_positions.each do |dp|
        pk = [
          c_pk0102,
          c_ver_made,
          (dp[:folder] ? c_ver_dir : c_ver_file),
          c_opt_nosize,
          c_comp_deflate,
          filetime.to_binary_dos_time,
          filetime.to_binary_dos_date,
          dp[:crc],
          dp[:complen],
          dp[:uncomplen],
          dp[:binary_fname].length,
          c_int2_zero,
          c_int2_zero,
          c_int2_zero,
          c_int2_zero,
          (dp[:folder] ? c_oattr_dir : c_oattr_file),
          dp[:offset]
        ]
        bin = pk.pack('VvvvvvvVVVvvvvvVV')
        pk0102_length += bin.length
        current_pos += bin.length
        o << bin
        bin = dp[:binary_fname]
        pk0102_length += bin.length
        current_pos += bin.length
        o << bin
      end

      pk = [
        c_pk0506,
        c_int2_zero,
        c_int2_zero,
        data_positions.length,
        data_positions.length,
        pk0102_length,
        pk0102_offset,
        c_int2_zero
      ]
      o << pk.pack('VvvvvVVv')
    rescue => e
      #logger.debug "------------ERROE:ArchivedFolder---" << entry_real_path.clone << ' detail:' << e.message
      #o << "------------ERROE:ArchivedFolder---" << entry_real_path.clone << ' detail:' << e.message
    end
  end
end