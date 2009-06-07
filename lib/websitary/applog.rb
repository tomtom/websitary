# applog.rb
# @Last Change: 2007-09-11.
# Author::      Thomas Link (micathom AT gmail com)
# License::     GPL (see http://www.gnu.org/licenses/gpl.txt)
# Created::     2007-09-08.

require 'logger'


# A simple wrapper around Logger.
class Websitary::AppLog
    def initialize(output=nil)
        @output = output || $stdout
        $logger = Logger.new(@output, 'daily')
        $logger.progname = Websitary::APPNAME
        $logger.datetime_format = "%H:%M:%S"
        set_level
    end


    def set_level(level=:default)
        case level
        when :debug
            $logger.level = Logger::DEBUG
        when :verbose
            $logger.level = Logger::INFO
        when :quiet
            $logger.level = Logger::ERROR
        else
            $logger.level = Logger::WARN
        end
        $logger.debug "Set logger level: #{level}"
    end
end


# Local Variables:
# revisionRx: REVISION\s\+=\s\+\'
# End:
