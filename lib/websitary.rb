# websitary.rb
# @Last Change: 2010-04-17.
# Author::      Thomas Link (micathom AT gmail com)
# License::     GPL (see http://www.gnu.org/licenses/gpl.txt)
# Created::     2007-09-08.


require 'cgi'
require 'digest/md5'
# require 'ftools'
require 'fileutils'
require 'net/ftp'
require 'optparse'
require 'pathname'
require 'rbconfig'
require 'uri'
require 'open-uri'
require 'timeout'
require 'yaml'
require 'rss'

['hpricot', 'robot_rules'].each do |f|
    begin
        require f
    rescue Exception => e
        $stderr.puts <<EOT
#{e.message}
Library could not be loaded: #{f}
Please see the requirements section at: http://websitiary.rubyforge.org
EOT
    end
end


module Websitary
    APPNAME     = 'websitary'
    VERSION     = '0.6'
    REVISION    = '2476'
end

require 'websitary/applog'
require 'websitary/filemtimes'
require 'websitary/configuration'
require 'websitary/htmldiff'


# Basic usage:
#   Websitary::App.new(ARGV).process
class Websitary::App
    MINUTE_SECS = 60
    HOUR_SECS   = MINUTE_SECS * 60
    DAY_SECS    = HOUR_SECS * 24


    # Hash: The output of the diff commands for each url.
    attr_reader :difftext

    # The configurator
    attr_reader :configuration

    # Secs until next update.
    attr_reader :tdiff_min


    # args:: Array of command-line (like) arguments.
    def initialize(args=[])
        @configuration = Websitary::Configuration.new(self, args)
        @difftext      = {}
        @tdiff_min     = nil

        ensure_dir(@configuration.cfgdir)
        css = File.join(@configuration.cfgdir, 'websitary.css')
        unless File.exists?(css)
            $logger.info "Copying default css file: #{css}"
            @configuration.write_file(css, 'w') do |io|
                io.puts @configuration.opt_get(:page, :css)
            end
        end
    end


    # Run the command stored in @execute.
    def process
        begin
            m = "execute_#{@configuration.execute}"
            if respond_to?(m)
                exit_code = send(m)
            else
                $logger.fatal "Unknown command: #{@configuration.execute}"
                exit_code = 5
            end
        ensure
            @configuration.mtimes.swap_out
        end
        return exit_code
    end


    # Show the currently configured URLs
    def execute_configuration
        keys = @configuration.options.keys
        urls = @configuration.todo
        # urls = @configuration.todo..sort {|a,b| @configuration.url_get(a, :title, a) <=> @configuration.url_get(b, :title, b)}
        urls.each_with_index do |url, i|
            data = @configuration.urls[url]
            text = [
                "<b>URL</b><br/>#{url}<br/>",
                "<b>current</b><br/>#{CGI.escapeHTML(@configuration.latestname(url, true))}<br/>",
                "<b>backup</b><br/>#{CGI.escapeHTML(@configuration.oldname(url, true))}<br/>",
                *((data.keys | keys).map do |k|
                        v = @configuration.url_get(url, k).inspect
                  "<b>:#{k}</b><br/>#{CGI.escapeHTML(v)}<br/>"
                end)
            ]
            accumulate(url, text.join("<br/>"))
        end
        return show
    end


    def cmdline_arg_add(configuration, url)
        configuration.to_do url
    end


    def execute_add
        if @configuration.quicklist_profile
            quicklist = @configuration.profile_filename(@configuration.quicklist_profile, false)
            $logger.info "Use quicklist file: #{quicklist}"
            if quicklist
                @configuration.write_file(quicklist, 'a') do |io|
                    @configuration.todo.each do |url|
                        io.puts %{source #{url.inspect}}
                    end
                end
                return 0
            end
        end
        $logger.fatal 'No valid quick-list profile defined'
        exit 5
    end


    # Restore previous backups
    def execute_unroll
        @configuration.todo.each do |url|
            latest = @configuration.latestname(url, true)
            backup = @configuration.oldname(url, true)
            if File.exist?(backup)
                $logger.warn "Restore: #{url}"
                $logger.debug "Copy: #{backup} => #{latest}"
                copy(backup, latest)
            end
        end
        return 0
    end


    # Edit currently chosen profiles
    def execute_edit
        @configuration.edit_profile
        exit 0
    end


    # Show the latest report
    def execute_review
        @configuration.view_output
        0
    end


    # Show the current version of all urls
    def execute_latest
        @configuration.todo.each do |url|
            latest = @configuration.latestname(url)
            text   = File.read(latest)
            accumulate(url, text)
        end
        return show
    end


    # Rebuild the report from the already downloaded copies.
    def execute_rebuild
        execute_downdiff(true, true)
    end


    def execute_purge
        days = @configuration.optval_get(:global, :purge, 365)
        $logger.warn "Purge files older than #{days} days"
        dirs = []
        dirs << File.join(@configuration.cfgdir, 'latest')
        dirs << File.join(@configuration.cfgdir, 'old')
        for d in dirs
            $logger.info "find #{d.gsub(/[ \\]/, '\\\\\\0')} -mtime +#{days} -type f -print -delete"
            `find #{d.gsub(/[ \\]/, '\\\\\\0')} -mtime +#{days} -type f -print -delete`
            for d1 in `find #{d.gsub(/[ \\]/, '\\\\\\0')} -type d`.split(/\n/).reverse
                if `find #{d1.gsub(/[ \\]/, '\\\\\\0')} -type f`.empty?
                    $logger.warn "Delete #{d1}"
                    Dir.delete(d1)
                end
            end
        end
        return 0
    end


    # Aggregate data for later review (see #execute_show)
    def execute_aggregate
        rv = execute_downdiff(false) do |url, difftext, opts|
            if difftext and !difftext.empty?
                aggrbase = @configuration.encoded_filename('aggregate', url, true, 'md5')
                aggrext  = Digest::MD5.hexdigest(Time.now.to_s)
                aggrfile = [aggrbase, aggrext].join('_')
                @configuration.write_file(aggrfile) {|io| io.puts difftext}
            end
        end
        clean_diffs
        rv
    end


    def execute_ls
        rv = 0
        @configuration.todo.each do |url|
            opts = @configuration.urls[url]
            name = @configuration.url_get(url, :title, url)
            $logger.debug "Source: #{name}"
            aggrbase  = @configuration.encoded_filename('aggregate', url, true, 'md5')
            aggrfiles = Dir["#{aggrbase}_*"]
            aggrn     = aggrfiles.size
            if aggrn > 0
                puts "%3d - %s" % [aggrn, name]
                rv = 1
            end
        end
        rv
    end


    # Show data collected by #execute_aggregate
    def execute_show
        @configuration.todo.each do |url|
            opts = @configuration.urls[url]
            $logger.debug "Source: #{@configuration.url_get(url, :title, url)}"
            aggrbase  = @configuration.encoded_filename('aggregate', url, true, 'md5')
            difftext  = []
            aggrfiles = Dir["#{aggrbase}_*"]
            aggrfiles.each do |file|
                difftext << File.read(file)
            end
            difftext.compact!
            difftext.delete('')
            unless difftext.empty?
                joindiffs = @configuration.url_get(url, :joindiffs, lambda {|t| t.join("\n")})
                difftext  = @configuration.call_cmd(joindiffs, [difftext], :url => url) if joindiffs
                accumulate(url, difftext, opts)
            end
            aggrfiles.each do |file|
                File.delete(file)
            end
        end
        show
    end


    # Process the sources in @configuration.url as defined by profiles 
    # and command-line options. The differences are stored in @difftext (a Hash).
    # show_output:: If true, show the output with the defined viewer.
    def execute_downdiff(show_output=true, rebuild=false, &accumulator)
        if @configuration.todo.empty?
            $logger.error 'Nothing to do'
            return 5
        end
        @configuration.todo.each do |url|
            opts = @configuration.urls[url]
            $logger.debug "Source: #{@configuration.url_get(url, :title, url)}"

            diffed = @configuration.diffname(url, true)
            $logger.debug "diffname: #{diffed}"

            if File.exists?(diffed)
                $logger.warn "Reuse old diff: #{@configuration.url_get(url, :title, url)} => #{diffed}"
                difftext = File.read(diffed)
                accumulate(url, difftext, opts)
            else
                latest = @configuration.latestname(url, true)
                $logger.debug "latest: #{latest}"
                next unless rebuild or !skip_url?(url, latest, opts)

                older = @configuration.oldname(url, true)
                $logger.debug "older: #{older}"

                begin
                    if rebuild or download(url, opts, latest, older)
                        difftext = diff(url, opts, latest, older)
                        if difftext
                            @configuration.write_file(diffed, 'wb') {|io| io.puts difftext}
                            # $logger.debug "difftext: #{difftext}" #DBG#
                            if accumulator
                                accumulator.call(url, difftext, opts)
                            else
                                accumulate(url, difftext, opts)
                            end
                        end
                    end
                rescue Exception => e
                    $logger.error e.to_s
                    $logger.info e.backtrace.join("\n")
                end
            end
        end
        return show_output ? show : @difftext.empty? ? 0 : 1
    end


    def move(from, to)
        # copy_move(:rename, from, to) # ftools
        copy_move(:mv, from, to) # FileUtils
    end


    def copy(from, to)
        # copy_move(:copy, from, to)
        copy_move(:cp, from, to)
    end


    def copy_move(method, from, to)
        if File.exists?(from)
            $logger.debug "Overwrite: #{from} -> #{to}" if File.exists?(to)
            lst = File.lstat(from)
            FileUtils.send(method, from, to)
            File.utime(lst.atime, lst.mtime, to)
            @configuration.mtimes.set(from, lst.mtime)
            @configuration.mtimes.set(to, lst.mtime)
        end
    end


    def format_tdiff(secs)
        d = (secs / DAY_SECS).to_i
        if d > 0
            return "#{d}d"
        else
            d = (secs / HOUR_SECS).to_i
            return "#{d}h"
        end
    end


    def ensure_dir(dir, fatal_nondir=true)
        if File.exist?(dir)
            unless File.directory?(dir)
                if fatal_nondir
                    $logger.fatal "Not a directory: #{dir}"
                    exit 5
                else
                    $logger.info "Not a directory: #{dir}"
                    return false
                end
            end
        else
            parent = Pathname.new(dir).parent.to_s
            ensure_dir(parent, fatal_nondir) unless File.directory?(parent)
            Dir.mkdir(dir)
        end
        return true
    end


    private

    def download(url, opts, latest, older=nil)
        if @configuration.done.include?(url)
            $logger.info "Already downloaded: #{@configuration.url_get(url, :title, url).inspect}"
            return false
        end

        $logger.warn "Download: #{@configuration.url_get(url, :title, url).inspect}"
        @configuration.done << url
        text = @configuration.call_cmd(@configuration.url_get(url, :download), [url], :url => url)
        # $logger.debug text #DBG#
        unless text
            $logger.warn "no contents: #{@configuration.url_get(url, :title, url)}"
            return false
        end

        if opts
            if (sleepsecs = opts[:sleep])
                sleep sleepsecs
            end
            text = text.split("\n")
            if (range = opts[:lines])
                $logger.debug "download: lines=#{range}"
                text = text[range] || []
            end
            if (range = opts[:cols])
                $logger.debug "download: cols=#{range}"
                text.map! {|l| l[range]}
                text.compact!
            end
            if (o = opts[:sort])
                $logger.debug "download: sort=#{o}"
                case o
                when true
                    text.sort!
                when Proc
                    text.sort!(&o)
                end
            end
            if (o = opts[:strip])
                $logger.debug "download: strip!"
                text.delete_if {|l| l !~ /\S/}
            end
            text = text.join("\n")
        end

        pprc = @configuration.url_get(url, :downloadprocess)
        if pprc
            $logger.debug "download process: #{pprc}"
            text = @configuration.call_cmd(pprc, [text], :url => url)
            # $logger.debug text #DBG#
        end

        if text and !text.empty?
            if older
                if File.exist?(latest)
                    move(latest, older)
                elsif !File.exist?(older)
                    $logger.warn "Initial copy: #{latest.inspect}"
                end
            end
            @configuration.write_file(latest) {|io| io.puts(text)}
            return true
        else
            return false
        end
    end


    def diff(url, opts, new, old)
        if File.exists?(old)
            $logger.debug "diff: #{old} <-> #{new}"
            difftext = @configuration.call_cmd(@configuration.url_get(url, :diff), [old, new], :url => url)
            # $logger.debug "diff: #{difftext}" #DBG#

            if difftext =~ /\S/
                if (pprc = @configuration.url_get(url, :diffprocess))
                    $logger.debug "diff process: #{pprc}"
                    difftext = @configuration.call_cmd(pprc, [difftext], :url => url)
                end
                # $logger.debug "difftext: #{difftext}" #DBG#
                if difftext =~ /\S/
                    $logger.warn "Changed: #{@configuration.url_get(url, :title, url).inspect}"
                    return difftext
                end
            end

            $logger.debug "Unchanged: #{@configuration.url_get(url, :title, url).inspect}"

        elsif File.exist?(new) and
            (@configuration.url_get(url, :show_initial) or @configuration.optval_get(:global, :show_initial))

            return File.read(new)

        end
        return nil
    end


    def skip_url?(url, latest, opts)
        if File.exists?(latest) and !opts[:ignore_age]
            tn = Time.now
            tl = @configuration.mtimes.mtime(latest)
            td = tn - tl
            tdiff = tdiff_with(opts, tn, tl)
            $logger.debug "skip_url? url=#{url}, tdiff=#{tdiff}"
            case tdiff
            when nil, false
                $logger.debug "Age requirement fulfilled: #{@configuration.url_get(url, :title, url).inspect}: #{format_tdiff(td)} old"
                return false
            when :skip, true
                $logger.info "Skip #{@configuration.url_get(url, :title, url).inspect}: Only #{format_tdiff(td)} old"
                return true
            when Numeric
                if td < tdiff
                    tdd = tdiff - td
                    @tdiff_min = tdd if @tdiff_min.nil? or tdd < @tdiff_min
                    $logger.info "Skip #{@configuration.url_get(url, :title, url).inspect}: Only #{format_tdiff(td)} old (#{format_tdiff(tdiff)})"
                    return true
                end
            else
                $logger.fatal "Internal error: tdiff=#{tdiff.inspect}"
                exit 5
            end
        end
    end


    def tdiff_with(opts, tn, tl)
        if (hdiff = opts[:hours])
            tdiff = hdiff * HOUR_SECS
            $logger.debug "hours: #{hdiff} (#{tdiff}s)"
        elsif (daily = opts[:daily])
            tdiff = tl.year == tn.year && tl.yday == tn.yday
            $logger.debug "daily: #{tl} <=> #{tn} (#{tdiff})"
        elsif (dweek = opts[:days_of_week] || opts[:wdays])
            tdiff = tdiff_x_of_y(dweek, tn.wday, tn.yday / 7, tl.yday / 7)
            $logger.debug "wdays: #{dweek} (#{tdiff})"
        elsif (dmonth = opts[:days_of_month] || opts[:mdays])
            tdiff = tdiff_x_of_y(dmonth, tn.day, tn.month, tl.month)
            $logger.debug "mdays: #{dmonth} (#{tdiff})"
        elsif (ddiff = opts[:days])
            tdiff = ddiff * DAY_SECS
            $logger.debug "days: #{ddiff} (#{tdiff}s)"
        elsif (dmonth = opts[:months])
            tnowm = tn.month + 12 * (tn.year - tl.year)
            tlm   = tl.month
            tdiff = (tnowm - tlm) < dmonth
            $logger.debug "months: #{dmonth} (#{tdiff})"
        else
            tdiff = false
        end
        return tdiff
    end


    def tdiff_x_of_y(eligible, now, parent_eligible, parent_now)
        if parent_eligible == parent_now
            return true
        else
            case eligible
            when Array, Range
                return !eligible.include?(now)
            when Integer
                return eligible != now
            else
                $logger.error "#{@configuration.url_get(url, :title, url)}: Wrong type for :days_of_week=#{dweek.inspect}"
                return :skip
            end
        end
    end


    def accumulate(url, difftext, opts=nil)
        # opts ||= @configuration.urls[url]
        @difftext[url] = difftext
    end


    def show
        begin
            return @configuration.show_output(@difftext)
        ensure
            clean_diffs
        end
    end


    def clean_diffs
        Dir[File.join(@configuration.cfgdir, 'diff', '*')].each do |f|
            $logger.debug "Delete saved diff: #{f}"
            File.delete(f)
        end
    end

end



# Local Variables:
# revisionRx: REVISION\s\+=\s\+\'
# End:
