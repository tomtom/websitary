# filemtimes.rb
# @Last Change: 2007-09-16.
# Author::      Thomas Link (micathom AT gmail com)
# License::     GPL (see http://www.gnu.org/licenses/gpl.txt)
# Created::     2007-09-08.


# require 'ftools'
require 'yaml'


class Websitary::FileMTimes
    def initialize(configuration)
        @configuration = configuration
        @store = File.join(@configuration.cfgdir, 'mtime.yml')
        @data  = {}
        swap_in
    end

    def swap_in
        if File.exist?(@store)
            @data = YAML.load_file(@store)
            case @data
            when Hash
            else
                $logger.error 'mtime.yml stored malformed data'
                @data = {}
            end
            File.delete(@store)
        end
    end

    def swap_out
        File.open(@store, 'w') {|f| YAML.dump(@data, f)}
    end

    def mtime(filename)
        filenamec = @configuration.canonic_filename(filename)
        @data[filenamec] ||= set(filename)
    end

    def set(filename, mtime=nil)
        if File.exist?(filename)
            mtime ||= File.mtime(filename)
            filenamec = @configuration.canonic_filename(filename)
            @data[filenamec] = mtime
            $logger.debug "Set mtime: #{filename} -> #{mtime.to_s}"
            mtime
        else
            nil
        end
    end
end


# Local Variables:
# revisionRx: REVISION\s\+=\s\+\'
# End:
