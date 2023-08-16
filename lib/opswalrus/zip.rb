require 'zip'

module OpsWalrus
  class DirZipper

    # Zip the input directory.
    # returns output_file
    def self.zip(input_dir, output_file)
      entries = Dir.entries(input_dir) - %w[. ..]

      ::Zip::File.open(output_file, create: true) do |zipfile|
        write_entries(input_dir, entries, '', zipfile)
      end

      output_file
    end

    # returns output_dir
    def self.unzip(input_file, output_dir)
      if !File.exist?(output_dir) || File.directory?(output_dir)
        FileUtils.mkdir_p(output_dir)
        ::Zip::File.foreach(input_file) do |entry|
          path = File.join(output_dir, entry.name)
          entry.extract(path) unless File.exist?(path)
        end
      else
        raise Error, "#{output_dir} is not a directory"
      end

      output_dir
    end

    def self.write_entries(input_dir, entries, path, zipfile)
      entries.each do |e|
        zipfile_path = path == '' ? e : File.join(path, e)
        disk_file_path = File.join(input_dir, zipfile_path)

        if File.directory?(disk_file_path)
          zipfile.mkdir(zipfile_path)
          subdir = Dir.entries(disk_file_path) - %w[. ..]
          write_entries(input_dir, subdir, zipfile_path, zipfile)
        else
          zipfile.add(zipfile_path, disk_file_path)
        end
      end
    end

  end
end

# this is just to test the zip function
def main
  OpsWalrus::DirZipper.zip("../example/davidinfra", "test.zip")
  OpsWalrus::DirZipper.unzip("test.zip", "test")
end

main if __FILE__ == $0
