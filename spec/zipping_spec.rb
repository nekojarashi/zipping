require File.expand_path(File.dirname(__FILE__) + '/spec_helper')
require 'fileutils'

describe "zipping" do
  let(:zip_output_dir){ '__zipping_test_out_tmp__/' }
  let(:zip_output_path){ '__zipping_test_out_tmp__/out.zip' }

  let(:zip_target_path){ '__zipping_test_tmp__/' }
  let(:dir_1_path)     { '__zipping_test_tmp__/dir' }
  let(:file_1_path)    { '__zipping_test_tmp__/file1' }
  let(:file_2_path)    { '__zipping_test_tmp__/dir/file2' }

  let(:file_1_data){ [*'A'..'Z', *'a'..'z'].shuffle!.join }
  let(:file_2_data){ [*'A'..'Z', *'a'..'z'].shuffle!.join }

  before :each do
    FileUtils.rm_rf zip_output_dir
    Dir.mkdir zip_output_dir

    FileUtils.rm_rf zip_target_path
    FileUtils.mkdir_p dir_1_path
    File.write file_1_path, file_1_data
    File.write file_2_path, file_2_data
  end

  after do
    FileUtils.rm_rf zip_output_dir
    FileUtils.rm_rf zip_target_path
  end

  it "create zip file" do
    if unzip_unavailable?
      pending "`unzip` command not available"
    end

    File.open zip_output_path, "wb" do |f|
      writer = SimpleWriter.new f
      Zipping.files_to_zip writer, zip_target_path
    end

    system "unzip", zip_output_path, "-d", zip_output_dir, out: "/dev/null", err: "/dev/null"
    expect(Dir.exist? zip_output_dir + dir_1_path).to be true
    expect(File.exist? zip_output_dir + file_1_path).to be true
    expect(File.exist? zip_output_dir + file_2_path).to be true
    expect(File.read zip_output_dir + file_1_path).to eq file_1_data
    expect(File.read zip_output_dir + file_2_path).to eq file_2_data
  end
end
