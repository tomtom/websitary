# configuration.rb
# @Last Change: 2010-04-24.
# Author::      Thomas Link (micathom AT gmail com)
# License::     GPL (see http://www.gnu.org/licenses/gpl.txt)
# Created::     2007-09-08.

require 'iconv'


# This class defines the scope in which profiles are evaluated. Most 
# of its methods are suitable for use in profiles.
class Websitary::Configuration
    # Hash (key = URL, value = Hash of options)
    attr_accessor :urls
    # Array of urls to be downloaded.
    attr_reader :todo
    # Array of downloaded urls.
    attr_accessor :done
    # The user configuration directory
    attr_accessor :cfgdir
    # What to do
    attr_accessor :execute
    # Global Options
    attr_accessor :options
    # Cached mtimes
    attr_accessor :mtimes
    # The name of the quicklist profile
    attr_accessor :quicklist_profile
    # attr_accessor :default_profiles
    # attr_accessor :cmd_edit


    def initialize(app, args=[])
        @logger = Websitary::AppLog.new
        $logger.debug "Configuration#initialize"
        @app    = app
        @cfgdir = ENV['HOME'] ? File.join(ENV['HOME'], '.websitary') : '.'
        [
            ENV['USERPROFILE'] && File.join(ENV['USERPROFILE'], 'websitary'),
            File.join(Config::CONFIG['sysconfdir'], 'websitary')
        ].each do |dir|
            if dir and File.exists?(dir)
                @cfgdir = dir
                break
            end
        end

        @cmd_edit          = 'vi "%s"'
        @execute           = 'downdiff'
        @quicklist_profile = 'quicklist'
        @view              = 'w3m "%s"'

        @allow             = {}
        @default_options   = {}
        @default_profiles  = [@quicklist_profile]
        @done              = []
        @mtimes            = Websitary::FileMTimes.new(self)
        @options           = {}
        @outfile           = {}
        @profiles          = []
        @robots            = {}
        @todo              = []
        @exclude           = [/^\s*(javascript|mailto):/]
        @urlencmap         = {}
        @urls              = {}

        @suffix = {
            'text' => 'txt'
            # 'rss'  => 'xml'
        }

        migrate
        initialize_options
        profile 'config.rb'
        parse_command_line_args(args)

        @output_format   ||= ['html']
        @output_title      = %{#{Websitary::APPNAME}: #{@profiles.join(", ")}}
    end


    def parse_command_line_args(args)
        $logger.debug "parse_command_line_args: #{args}"
        opts    = OptionParser.new do |opts|
            opts.banner =  "Usage: #{Websitary::APPNAME} [OPTIONS] [PROFILES] > [OUT]"
            opts.separator ''
            opts.separator "#{Websitary::APPNAME} is a free software with ABSOLUTELY NO WARRANTY under"
            opts.separator 'the terms of the GNU General Public License version 2 or newer.'
            opts.separator ''

            opts.separator 'General Options:'

            opts.on('-c', '--cfg=DIR', String, 'Configuration directory') do |value|
                @cfgdir = value
            end

            opts.on('-e', '--execute=COMMAND', String, 'Define what to do (default: downdiff)') do |value|
                @execute = value
            end

            # opts.on('-E', '--edit=PROFILE', String, 'Edit a profile') do |value|
            #   edit_profile value
            #   exit 0
            # end

            opts.on('-f', '--output-format=FORMAT', 'Output format (html, text, rss)') do |value|
                output_format(*value.split(/,/))
            end

            opts.on('--[no-]ignore-age', 'Ignore age limits') do |bool|
                set :ignore_age => bool
            end

            opts.on('--log=DESTINATION', String, 'Log destination') do |value|
                @logger = Websitary::AppLog.new(value != '-' && value)
            end

            opts.on('-o', '--output=FILENAME', String, 'Output') do |value|
                output_file(value)
            end

            opts.on('--purge=N', Integer, 'Remove files older than N (default = 365) days from the cache (requires the unix find utility)') do |value|
                global(:purge => value)
            end

            opts.on('-s', '--set=NAME=VAR', String, 'Set a default option') do |value|
                key, val = value.split(/=/, 2)
                set key.intern => eval(val)
            end

            opts.on('-t', '--timer=N', Numeric, 'Repeat every N seconds (never exit)') do |value|
                global(:timer => value)
            end

            opts.on('-x', '--exclude=N', Regexp, 'Exclude URLs matching this pattern') do |value|
                exclude(Regexp.new(value))
            end

            opts.separator ''
            opts.separator "Available commands (default: #@execute):"
            commands = @app.methods.map do |m|
                mt = m.match(/^execute_(.*)$/)
                mt && mt[1]
            end
            commands.compact!
            commands.sort!
            opts.separator commands.join(', ')

            opts.separator ''
            opts.separator 'Available profiles:'
            opts.separator Dir[File.join(@cfgdir, '*.rb')].map {|f| File.basename(f, '.*')}.join(', ')

            opts.separator ''
            opts.separator 'Other Options:'

            opts.on('--debug', 'Show debug messages') do |v|
                $VERBOSE = $DEBUG = true
                @logger.set_level(:debug)
            end

            opts.on('-q', '--quiet', 'Be mostly quiet') do |v|
                @logger.set_level(:quiet)
            end

            opts.on('-v', '--verbose', 'Run verbosely') do |v|
                $VERBOSE = true
                @logger.set_level(:verbose)
            end

            opts.on('--version', 'Run verbosely') do |v|
                puts Websitary::VERSION
                exit 1
            end

            opts.on_tail('-h', '--help', 'Show this message') do
                puts opts
                exit 1
            end
        end

        @profiles = opts.parse!(args)
        @profiles = @default_profiles if @profiles.empty?
        cla_handler = "cmdline_arg_#{@execute}"
        cla_handler = nil unless @app.respond_to?(cla_handler)
        for pn in @profiles
            if cla_handler
                @app.send(cla_handler, self, pn)
            else
                profile pn
            end
        end

        self
    end


    def url_set(url, items)
        opts = @urls[url] ||= {}
        opts.merge!(items)
    end


    # Retrieve an option for an url
    # url:: String
    # opt:: Symbol
    def url_get(url, opt, default=nil)
        opts = @urls[url]
        unless opts
            $logger.debug "Non-registered URL: #{url}"
            return default
        end
        $logger.debug "get: opts=#{opts.inspect}"
        case opt
        when :diffprocess, :format
            opt_ = opts.has_key?(opt) ? opt : :diff
        else
            opt_ = opt
        end

        $logger.debug "get: opt=#{opt} opt_=#{opt_}"
        $logger.debug "get: #{opts[opt_]} #{opts[:use]}" if opts
        if opts.has_key?(opt_)
            val = opts[opt_]
        elsif opts.has_key?(:use)
            val = opts[:use]
        else
            val = nil
        end

        case val
        when nil
        when Symbol
            $logger.debug "get: val=#{val}"
            success, rv = opt_get(opt, val)
            $logger.debug "get: #{success}, #{rv}"
            if success
                return rv
            end
        else
            $logger.debug "get: return val=#{val}"
            return val
        end
        unless default
            success, default1 = opt_get(opt, :default)
            default = default1 if success
        end

        $logger.debug "get: return default=#{default}"
        return default
    end


    def optval_get(opt, val, default=nil)
        case val
        when Symbol
            ok, val = opt_get(opt, val)
            if ok
                val
            else
                default
            end
        else
            val
        end
    end


    def opt_get(opt, val)
        vals = @options[opt]
        $logger.debug "val=#{val} vals=#{vals.inspect}"
        if vals and vals.has_key?(val)
            rv = vals[val]
            $logger.debug "opt_get ok: #{opt} => #{rv.inspect}"
            case rv
            when Symbol
                $logger.debug "opt_get re: #{rv}"
                return opt_get(opt, rv)
            else
                $logger.debug "opt_get true, #{rv}"
                return [true, rv]
            end
        else
            $logger.debug "opt_get no: #{opt} => #{val.inspect}"
            return [false, val]
        end
    end


    # Configuration command:
    # Set the default profiles
    def default(*profile_names)
        @default_profiles = profile_names
    end


    def quicklist(profile_name)
        @quicklist_profile = profile_name
    end


    # Configuration command:
    # Load a profile
    def profile(profile_name)
        case profile_name
        when '-'
            readlines.map! {|l| l.chomp}.each {|url| source url}
        when '__END__'
            $logger.debug "Profile: __END__"
            contents = DATA.read
            return eval_profile(contents)
        else
            fn = profile_filename(profile_name)
            if fn
                $logger.debug "Profile: #{fn}"
                contents = File.read(fn)
                return eval_profile(contents, fn)
            else
                $logger.error "Unknown profile: #{profile_name}"
            end
        end
        return false
    end


    # Define a options shortcut.
    def shortcut(symbol, args)
        ak = args.keys
        ok = @options.keys
        dk = ok - ak

        # :downloadprocess
        if !ak.include?(:delegate) and
            dk.any? {|e| [:download, :downloadformat, :diff, :format, :diffprocess].include?(e)}
            $logger.warn "Shortcut #{symbol}: Undefined fields: #{dk.inspect}"
        end

        if ak.include?(:delegate)
            dk.each do |field|
                @options[field][symbol] = args[:delegate]
            end
        end

        args.each do |field, val|
            @options[field][symbol] = val unless field == :delegate
        end
    end


    def to_do(url)
        @todo << url unless is_excluded?(url)
    end


    def is_excluded?(url)
        rv = @exclude.any? {|p| url =~ p}
        $logger.debug "is_excluded: #{url}: #{rv}"
        rv
    end


    # Set the output format.
    def output_format(*format)
        unless format.all? {|e| ['text', 'html', 'rss'].include?(e)}
            $logger.fatal "Unknown output format: #{format}"
            exit 5
        end
        @output_format = format
    end


    # Set the output file.
    def output_file(filename, outformat=nil)
        @outfile[outformat] = filename
    end


    # Configuration command:
    # Set global options.
    # type:: Symbol
    # options:: Hash
    def option(type, options)
        $logger.info "option #{type}: #{options.inspect}"
        o = @options[type]
        if o
            o.merge!(options)
        else
            $logger.error "Unknown option type: #{type} (#{options.inspect})"
        end
    end


    # Set a global option.
    def global(options)
        options.each do |type, value|
            @options[:global][type] = value
        end
    end


    # Configuration command:
    # Set the default value for source-options.
    def set(options)
        $logger.debug "set: #{options.inspect}"
        @default_options.merge!(options)
    end


    # Configuration command:
    # Unset a default source-option.
    def unset(*options)
        for option in options
            @default_options.delete(option)
        end
    end


    # Configuration command:
    # Define a source.
    # urls:: String
    def source(urls, opts={})
        urls.split("\n").flatten.compact.each do |url|
            url_set(url, @default_options.dup.update(opts))
            to_do url
        end
    end


    # Configuration command:
    # Set the default download processor. The block takes the 
    # downloaded text (STRING) as argument.
    def downloadprocess(&block)
        @options[:downloadprocess][:default] = block
    end


    # Configuration command:
    # Set the default diff processor. The block takes the 
    # diff text (STRING) as argument.
    def diffprocess(&block)
        @options[:diff][:default] = block
    end


    # Configuration command:
    # Set the editor.
    def edit(cmd)
        @cmd_edit = cmd
    end


    # Configuration command:
    # Add URL-exclusion patterns (REGEXPs or STRINGs).
    def exclude(*urls)
        @exclude += urls.map do |url|
            case url
            when Regexp
                url
            when String
                Regexp.new(Regexp.escape(url))
            else
                $logger.fatal "Must be regexp or string: #{url.inspect}"
                exit 5
            end
        end
    end


    # Configuration command:
    # Set the viewer.
    def view(view)
        @view = view
    end


    # Configuration command:
    # Set the default diff program.
    def diff(diff)
        @options[:diff][:default] = diff
    end


    # Configuration command:
    # Set the default dowloader.
    def download(download)
        @options[:download][:default] = download
    end


    def format_text(url, text, enc = nil)
        enc ||= url_get(url, :iconv)
        if enc
            denc = optval_get(:global, :encoding)
            if enc != denc
                begin
                    $logger.debug "IConv convert #{url}: #{enc} => #{denc}"
                    text = Iconv.conv(denc, enc, text)
                rescue Exception => e
                    $logger.error "IConv failed #{enc} => #{denc}: #{e}"
                end
            end
        end
        return text
    end


    # Format a diff according to URL's source options.
    def format(url, difftext)
        fmt  = url_get(url, :format)
        text = format_text(url, difftext)
        eval_arg(fmt, [text], text)
    end


    # Apply some arguments to a format.
    # format:: String or Proc
    # args:: Array of Arguments
    def eval_arg(format, args, default=nil, &process_string)
        case format
        when nil
            return default
        when Proc
            # $logger.debug "eval proc: #{format} #{args.inspect}" #DBG#
            $logger.debug "eval proc: #{format}/#{args.size}"
            return format.call(*args)
        else
            ca = format % args
            # $logger.debug "eval string: #{ca}" #DBG#
            if process_string
                return process_string.call(ca)
            else
                return ca
            end
        end
    end


    # Apply the argument to cmd (a format String or a Proc). If a 
    # String, execute the command.
    def call_cmd(cmd, cmdargs, args={})
        default = args[:default]
        url     = args[:url]
        timeout = url ? url_get(url, :timeout) : nil
        if timeout
            begin
                Timeout::timeout(timeout) do |timeout_length|
                    eval_arg(cmd, cmdargs, default) {|cmd| `#{cmd}`}
                end
            rescue Timeout::Error
                $logger.error "Timeout #{timeout}: #{url}"
                return default
            end
        else
            eval_arg(cmd, cmdargs, default) {|cmd| `#{cmd}`}
        end
    end


    # Generate & view the final output.
    # difftext:: Hash
    def show_output(difftext)
        if difftext.empty?
            msg = ['No news is good news']
            msg << "try again in #{@app.format_tdiff(@app.tdiff_min)}" if @app.tdiff_min
            $logger.warn msg.join('; ')
            return 0
        end

        @output_format.each do |outformat|
            meth = "get_output_#{outformat}"

            unless respond_to?(meth)
                $logger.fatal "Unknown output format: #{outformat}"
                exit 5
            end

            out = send(meth, difftext)
            if out
                outfile = get_outfile(outformat)
                case outfile
                when '-'
                    puts out
                else
                    write_file(outfile) {|io| io.puts out}
                    meth = "view_output_#{outformat}"
                    self.send(meth, outfile)
                end
            end
        end
        return 1
    end


    def get_output_text(difftext)
        difftext.map do |url, difftext|
            if difftext
                difftext = html_to_text(difftext) if is_html?(difftext)
                !difftext.empty? && [
                    eval_arg(url_get(url, :rewrite_link, '%s'), [url]), 
                    difftext_annotation(url), 
                    nil, 
                    difftext
                ].join("\n")
            end
        end.compact.join("\n\n#{('-' * 68)}\n\n")
    end


    def get_output_rss(difftext)
        success, rss_url = opt_get(:rss, :url)
        if success
            success, rss_version = opt_get(:rss, :version)
            # require "rss/#{rss_version}"

            rss         = RSS::Rss.new(rss_version)
            chan        = RSS::Rss::Channel.new
            chan.title  = @output_title
            [:description, :copyright, :category, :language, :image, :webMaster, :pubDate].each do |field|
                ok, val = opt_get(:rss, field)
                item.send(format_symbol(field, '%s='), val) if ok
            end
            chan.link   = rss_url
            rss.channel = chan

            cnt = difftext.map do |url, text|
                rss_format = url_get(url, :rss_format, 'plain_text')
                text = strip_tags(text, :format => rss_format)
                next if text.empty?

                item = RSS::Rss::Channel::Item.new
                item.date  = Time.now
                item.title = url_get(url, :title, File.basename(url))
                item.link  = eval_arg(url_get(url, :rewrite_link, '%s'), [url])
                [:author, :date, :enclosure, :category, :pubDate].each do |field|
                    val = url_get(url, format_symbol(field, 'rss_%s'))
                    item.send(format_symbol(field, '%s='), val) if val
                end

                annotation = difftext_annotation(url)
                annotation = "<pre>#{annotation}</pre>" if annotation
                case rss_format
                when 'plain_text'
                    item.description = %{#{annotation}<pre>#{text}</pre>}
                else
                    item.description = %{#{annotation}\n#{text}}
                end
                chan.items << item
            end

            return rss.to_s

        else

            $logger.fatal "Global option :rss[:url] not defined."
            exit 5

        end
    end


    def get_title(url)
        text = url_get(url, :title, File.basename(url))
        format_text(url, text, optval_get(:global, :config_encoding, optval_get(:global, :encoding)))
    end


    def get_output_html(difftext)
        difftext = difftext.map do |url, text|
            tags = url_get(url, :strip_tags)
            text = strip_tags(text, :tags => tags) if tags
            text.empty? ? nil : [url, text]
        end
        difftext.compact!
        sort_difftext!(difftext)

        toc = difftext.map do |url, text|
            ti  = get_title(url)
            tid = html_toc_id(url)
            bid = html_body_id(url)
            %{<li id="#{tid}" class="toc"><a class="toc" href="\##{bid}">#{ti}</a></li>}
        end.join("\n")

        idx = 0
        cnt = difftext.map do |url, text|
            idx += 1
            ti   = get_title(url)
            bid  = html_body_id(url)
            if (rewrite = url_get(url, :rewrite_link))
                urlr = eval_arg(rewrite, [url])
                ext  = ''
            else
                old  = %{<a class="old" href="#{file_url(oldname(url))}">old</a>}
                lst  = %{<a class="latest" href="#{file_url(latestname(url))}">latest</a>}
                ext  = %{ (#{old}, #{lst})}
                urlr = url
            end
            note    = difftext_annotation(url)
            onclick = optval_get(:global, :toggle_body) ? 'onclick="ToggleBody(this)"' : ''
            <<HTML
<div id="#{bid}" class="webpage" #{onclick}>
<div class="count">
#{idx}
</div>
<h1 class="diff">
<a class="external" href="#{urlr}">#{format_text(url, ti)}</a>#{ext}
</h1>
<div id="#{bid}_body">
<div class="annotation">
#{note && CGI::escapeHTML(note)}
</div>
<div class="diff,difftext">
#{format(url, text)}
</div>
</div>
</div>
HTML
        end.join(('<hr class="separator"/>') + "\n")

        success, template = opt_get(:page, :format)
        unless success
            success, template = opt_get(:page, :simple)
        end
        return eval_arg(template, [@output_title, toc, cnt])
    end


    # Get the diff filename.
    def diffname(url, ensure_dir=false)
        encoded_filename('diff', url, ensure_dir, 'md5')
    end


    # Get the backup filename.
    def oldname(url, ensure_dir=false, type=nil)
        encoded_filename('old', url, ensure_dir, type)
    end


    # Get the filename for the freshly downloaded copy.
    def latestname(url, ensure_dir=false, type=nil)
        encoded_filename('latest', url, ensure_dir, type)
    end


    def url_from_filename(filename)
        rv = @urlencmap[filename]
        if rv
            $logger.debug "Map filename: #{filename} -> #{rv}"
        else
            $logger.warn "Unmapped filename: #{filename}"
        end
        rv
    end


    def encoded_filename(dir, url, ensure_dir=false, type=nil)
        type ||= url_get(url, :cachetype, 'tree')
        $logger.debug "encoded_filename: type=#{type} url=#{url}"
        basename = url_get(url, :filename, encoded_basename(url, type))
        rv = File.join(@cfgdir, dir, basename)
        rd = File.dirname(rv)
        $logger.debug "encoded_filename: rv0=#{rv}"
        fm = optval_get(:global, :filename_size, 255)
        rdok = !ensure_dir || @app.ensure_dir(rd, false)
        if !rdok or rv.size > fm or File.directory?(rv)
            # $logger.debug "Filename too long (:global=>:filename_size = #{fm}), try md5 encoded filename instead: #{url}"
            $logger.info "Can't use filename, try 'md5' instead: #{url}"
            rv = File.join(@cfgdir, dir, encoded_basename(url, :md5))
            rd = File.dirname(rv)
        end
        @urlencmap[rv] = url
        return rv
    end


    def encoded_basename(url, type='tree')
        m = "encoded_basename_#{type}"
        if respond_to?(m)
            return send(m, url)
        else
            $logger.fatal "Unknown cache type: #{type}"
            exit 5
        end
    end


    def encoded_basename_tree(url)
        ensure_filename(encode(url, '/'))
    end


    def encoded_basename_flat(url)
        encode(url)
    end


    def encoded_basename_md5(url)
        Digest::MD5.hexdigest(url)
    end


    def urlextname(url)
        begin
            return File.extname(URI.parse(url).path)
        rescue Exception => e
        end
    end


    # Guess path's dirname.
    #   foo/bar     -> foo
    #   foo/bar.txt -> foo
    #   foo/bar/    -> foo/bar
    def guess_dir(path)
        path[-1..-1] == '/' ? path[0..-2] : File.dirname(path)
    end


    def save_dir(url, dir, title=nil)
        case dir
        when true
            title = url_get(url, :title) || encode(title)
            dir = attachment_dir(url, title)
        when Proc
            dir = dir.call(url)
        end
        @app.ensure_dir(dir) if dir
        return dir
    end


    def attachment_dir(url, title)
        File.join(url_get(url, :attachments) || File.join(@cfgdir, 'attachments'), title)
    end


    def clean_url(url)
        url && url.strip
    end


    # Strip the url's last part (after #).
    def canonic_url(url)
        url.sub(/#.*$/, '')
    end


    def strip_tags_default
        success, tags = opt_get(:strip_tags, :default)
        tags.dup if success
    end


    def strip_tags(doc, args={})
        tags = args[:tags] || strip_tags_default
        case doc
        when String
            doc = Hpricot(doc)
        end
        tags.each do |tag|
            doc.search(tag).remove
        end
        case args[:format]
        when :hpricot
            doc
        else
            doc.send("to_#{args[:format] || :html}")
        end
    end


    # Check whether path is eligible on the basis of url or path0.
    # This checks either for a :match option for url or the extensions 
    # of path0 and path.
    def eligible_path?(url, path0, path)
        rx = url_get(url, :match)
        if rx
            return path =~ rx
        else
            return File.extname(path0) == File.extname(path)
        end
    end


    # Scan hpricot document for hrefs and push the onto @todo if not 
    # already included.
    def push_hrefs(url, hpricot, &condition)
        begin
            $logger.debug "push_refs: #{url}"
            return if robots?(hpricot, 'nofollow') or is_excluded?(url)
            depth = url_get(url, :depth)
            return if depth and depth <= 0
            uri0  = URI.parse(url)
            # pn0   = Pathname.new(guess_dir(File.expand_path(uri0.path)))
            pn0   = Pathname.new(guess_dir(uri0.path))
            (hpricot / 'a').each do |a|
                next if a['rel'] == 'nofollow'
                href = clean_url(a['href'])
                next if href.nil? or href == url or is_excluded?(href)
                uri  = URI.parse(href)
                pn   = guess_dir(uri.path)
                href = rewrite_href(href, url, uri0, pn0, true)
                curl = canonic_url(href)
                next if !href or href.nil? or @done.include?(curl) or @todo.include?(curl)
                # pn   = Pathname.new(guess_dir(File.expand_path(uri.path)))
                uri  = URI.parse(href)
                pn   = Pathname.new(guess_dir(uri.path))
                next unless condition.call(uri0, pn0, uri, pn)
                next unless robots_allowed?(curl, uri)
                opts = @urls[url].dup
                # opts[:title] = File.basename(curl)
                opts[:title] = [opts[:title], File.basename(curl)].join(' - ')
                opts[:depth] = depth - 1 if depth and depth >= 0
                # opts[:sleep] = delay if delay
                url_set(curl, opts)
                to_do curl
            end
        rescue Exception => e
            # $logger.error e  #DBG#
            $logger.error e.message
            $logger.debug e.backtrace
        end
    end


    # Rewrite urls in doc
    # url:: String
    # doc:: Hpricot document
    def rewrite_urls(url, doc)
        uri = URI.parse(url)
        urd = guess_dir(uri.path)
        (doc / 'a').each do |a|
            href = clean_url(a['href'])
            if is_excluded?(href)
                comment_element(doc, a)
            else
                href = rewrite_href(href, url, uri, urd, true)
                a['href'] = href if href
            end
        end
        (doc / 'img').each do |a|
            href = clean_url(a['src'])
            if is_excluded?(href)
                comment_element(doc, a)
            else
                href = rewrite_href(href, url, uri, urd, false)
                a['src'] = href if href
            end
        end
        doc
    end


    def comment_element(doc, elt)
        doc.insert_before(elt, '<!-- WEBSITARY: ')
        doc.insert_after(elt, '-->')
    end


    # Try to make href an absolute url.
    def rewrite_href(href, url, uri=nil, urd=nil, local=false)
        begin
            return nil if !href or is_excluded?(href)
            uri ||= URI.parse(url)
            if href =~ /^\s*\//
                return uri.merge(href).to_s
            end
            urh   = URI.parse(href)
            urd ||= guess_dir(uri.path)
            rv    = nil

            # $logger.debug "DBG", uri, urh, #DBG#
            if href =~ /\w+:/
                # $logger.debug "DBG href=#$0" #DBG#
                rv = href
            elsif urh.relative?
                # $logger.debug "DBG urh relative" #DBG#
                if uri.relative?
                    # $logger.debug "DBG both relative" #DBG#
                    if uri.instance_of?(URI::Generic)
                        rv = File.join(urd, href)
                        # $logger.debug "DBG rv=#{rv}" #DBG#
                    end
                else
                    rv = uri.merge(href).to_s
                    # $logger.debug "DBG relativ rv=#{rv}" #DBG#
                    if local
                        hf = latestname(rv)
                        if @todo.include?(rv) or @done.include?(rv) or File.exist?(hf)
                            rv = hf
                            # $logger.debug "DBG relativ, local rv=#{rv}" #DBG#
                        end
                    end
                end
            elsif href[0..0] == '#'
                # $logger.debug "DBG anchor" #DBG#
                rv = url + href
            elsif uri.host == urh.host
                # $logger.debug "DBG merge" #DBG#
                rv = uri.merge(href).to_s
            else
                # $logger.debug "as is" #DBG#
                rv = href
            end

            case rv
            when String
                return rv
            when nil
            else
                $logger.error "Internal error: href=#{href}"
                $logger.debug caller.join("\n")
            end
            return
        rescue Exception => e
            # $logger.error e  #DBG#
            $logger.error e.message
            $logger.debug e.backtrace
        end
        return nil
    end


    # Return a Proc that takes an text as argument and highlight occurences of rx.
    # rx:: Regular expression
    # color:: A string, sets the class to highlight-color (default: "yellow")
    # group:: A number (default: 0)
    # tag:: The HTML tag to use (default: "span")
    def highlighter(rx, color=nil, group=nil, tag='span')
        lambda {|text| text.gsub(rx, %{<#{tag} class="highlight-#{color || 'red'}">\\#{group || 0}</#{tag}>})}
    end


    def view_output(outfile=nil)
        send("view_output_#{@output_format[0]}", outfile || get_outfile)
    end


    def edit_profile(profile=nil)
        profile ||= @profiles
        case profile
        when Array
            profile.each {|p| edit_profile p}
        else
            fn = profile_filename(profile)
            $logger.debug "edit: #{fn}"
            `#{@cmd_edit % fn}`
        end
    end


    def profile_filename(profile_name, check_file_exists=true)
        if File.extname(profile_name) != '.rb'
            profile_name = "#{profile_name}.rb"
        end
        filename = nil
        ['.', @cfgdir].each do |d|
            filename = File.join(d, profile_name)
            if File.exists?(filename)
                return filename
            end
        end
        return check_file_exists ? nil : filename
    end


    def write_file(filename, mode='w', &block)
        @app.ensure_dir(File.dirname(filename))
        File.open(filename, mode) {|io| block.call(io)}
        @mtimes.set(filename)
    end


    def canonic_filename(filename)
        call_cmd(optval_get(:global, :canonic_filename), [filename], :default => filename)
    end


    private
    def initialize_options
        @options = {
            :global => {
                :download_html => :openuri,
                :encoding => 'UTF-8',
                :toggle_body => false,
                :user_agent => "websitary/#{Websitary::VERSION}",
            },
        }

        @options[:diff] = {
            :default => :diff,

            :diff => lambda {|old, new, *args|
                opts, _  = args
                opts   ||= '-d -w'
                difftext = call_cmd('diff %s -U 2 "%s" "%s"', [opts, old, new])
                difftext = difftext.split("\n")[2..-1]
                difftext ? difftext.delete_if {|l| l =~ /^[^+]/}.map {|l| l[1..-1]}.join("\n") : ''
            },

            :binary => lambda {|old, new|
                call_cmd(optval_get(:diff, :diff), [old, new, '--binary -d -w'])
            },

            :new => lambda {|old, new|
                difftext = call_cmd(optval_get(:diff, :binary), [old, new])
                difftext.empty? ? '' : new
            },

            :raw => :new,

            :htmldiff => lambda {|old, new|
                url  = url_from_filename(new)
                args = {
                    :oldhtml => File.read(old),
                    :newhtml => File.read(new),
                    :ignore  => url_get(url, :ignore),
                }
                difftext = Websitary::Htmldiff.new(args).diff
                difftext
            },

            :webdiff => lambda {|old, new|
                oldhtml  = File.read(old)
                newhtml  = File.read(new)
                difftext = Websitary::Htmldiff.new(:highlight => 'highlight', :oldtext => oldhtml, :newtext => newhtml).diff
                difftext
            },

            :websec_webdiff => lambda {|old, new|
            # :webdiff => lambda {|old, new|
                $logger.debug "webdiff: #{File.basename(new)}"
                $logger.debug %{webdiff --hicolor=yellow -archive "#{old}" -current "#{new}" -out -}
                difftext = `webdiff --hicolor=yellow -archive "#{old}" -current "#{new}" -out -`
                $?.exitstatus == 1 ? difftext : ''
            },
        }

        @options[:format] = {
            :default => :diff,
            :diff    => %{<pre class="diff">\n%s\n</pre>},
            :webdiff => "%s\n",
            :raw     => lambda {|new| File.read(new)},
        }

        @options[:diffprocess] = {
            :default => :diff,
            :diff    => false,
            :webdiff => false,
            :raw     => false,
        }

        @options[:download] = {
            :default    => :w3m,
            :raw        => :openuri,
        }

        @options[:downloadformat] = {
            :w3m => 'text',
            :webdiff => 'html',
            :raw => '',
        }

        @options[:downloadprocess] = {
        }

        @options[:rss] = {
            :version => '2.0',
        }

        @options[:strip_tags] = {
            :default => ['script', 'object', 'form', 'input', 'select', 'iframe', 'head', 'meta', 'link'],
        }

        shortcut :w3m, :delegate => :diff,
            :download => 'w3m -S -F -dump "%s"'
            # :download => 'w3m -S -F -dump "%s" | iconv -t UTF-8'
            # :download => 'w3m -no-cookie -S -F -dump "%s"'

        shortcut :lynx, :delegate => :diff,
            :download => 'lynx -dump -nolist "%s" | iconv -t UTF-8'

        shortcut :links, :delegate => :diff,
            :download => 'links -dump "%s" | iconv -t UTF-8'

        shortcut :curl, :delegate => :webdiff,
            :download => 'curl --silent "%s" | iconv -t UTF-8'

        shortcut :wget, :delegate => :webdiff,
            :download => 'wget -q -O - "%s" | iconv -t UTF-8'

        shortcut :text, :delegate => :diff,
            :download => lambda {|url| doc_to_text(read_document(url))}

        shortcut :body_html, :delegate => :webdiff,
            :strip_tags => :default,
            :download => lambda {|url|
                begin
                    doc = read_document(url)
                    body_html(url, doc).to_s
                rescue Exception => e
                    # $logger.error e  #DBG#
                    $logger.error e.message
                    $logger.debug e.backtrace
                    break %{<pre class="error">\n#{e.message}\n</pre>}
                end
            }

        shortcut :openuri, :delegate => :webdiff,
            :download => lambda {|url|
                begin
                    read_url_openuri(url)
                rescue Exception => e
                    # $logger.error e  #DBG#
                    $logger.error e.message
                    $logger.debug e.backtrace
                    %{<pre class="error">\n#{e.to_s}\n</pre>}
                end
            }

        shortcut :mechanize, :delegate => :webdiff,
            :download => lambda {|url|
                require 'mechanize'
                agent = WWW::Mechanize.new
                proxy = get_proxy
                if proxy
                    agent.set_proxy(*proxy)
                end
                page = agent.get(url)
                process = url_get(url, :mechanize)
                if process
                    uri = URI.parse(url)
                    urd = guess_dir(uri.path)
                    page.links.each {|link|
                        href = link.node['href']
                        if href
                            href = rewrite_href(href, url, uri, urd, true)
                            link.node['href'] = href if href
                        end
                    }
                    process.call(url, agent, page)
                else
                    doc = url_document(url, page.content)
                    body_html(url, doc).to_s
                end
            }

        shortcut :rss,
            :delegate => :openuri,
            :diff => lambda {|old, new|
                success, rss_version = opt_get(:rss, :version)
                ro = RSS::Parser.parse(File.read(old), false)
                if ro
                    rh = {}
                    ro.items.each do |item|
                        rh[rss_item_id(item)] = item
                        rh[item.link] = item
                        rh[item.guid] = item if item.guid
                    end
                    rnew = []
                    rn = RSS::Parser.parse(File.read(new), false)
                    if rn
                        rn.items.each do |item|
                            rid = rss_item_id(item)
                            $logger.debug "rid = #{rid}"
                            $logger.debug "rh[rid] = #{rh[rid]}"
                            if !rh[rid]
                                idesc = item.description || ''
                                $logger.debug "idesc = #{idesc}"
                                $logger.debug "item.link = #{item.link}"
                                $logger.debug "item.guid = #{item.guid}"
                                $logger.debug "olditem = rh[item.link] = #{rh[item.link]}"
                                olditem = item.guid ? rh[item.guid] : rh[item.link]
                                if olditem
                                    odesc = olditem.description || ''
                                    rss_diff = Websitary::Htmldiff.new(:highlight => 'highlight', :oldtext => odesc, :newtext => idesc).process
                                    rnew << format_rss_item(item, rss_diff)
                                else
                                    enc = item.respond_to?(:enclosure) && item.enclosure
                                    url = url_from_filename(new)
                                    # if !enc and item.description
                                    if !enc
                                        ddoc = Hpricot(idesc)
                                        scanner = url_get(url, :rss_find_enclosure)
                                        if scanner
                                            enc  = scanner.call(item, ddoc)
                                            if enc
                                                def enc.url
                                                    self
                                                end
                                                $logger.debug "Embedded enclosure: #{enc}"
                                                $logger.info "Embedded enclosure url: #{enc.url}"
                                            else
                                                $logger.info "No embedded enclosure URL found: #{idesc}"
                                            end
                                        end
                                    end
                                    $logger.info "Enclosure: #{enc}"
                                    if enc and (curl = clean_url(enc.url))
                                        dir   = url_get(url, :rss_enclosure)
                                        curl  = rewrite_href(curl, url, nil, nil, true)
                                        next unless curl
                                        if dir
                                            $logger.debug "Enclosure basedir: #{dir}"
                                            dir = save_dir(url, dir, encode(rn.channel.title))
                                            $logger.debug "Enclosure dir: #{dir}"
                                            $logger.info "Enclosure: #{curl}"
                                            fpath = [dir]
                                            year = url_get(url, :year)
                                            fpath << year.to_s if year
                                            fpath << encode(File.basename(curl) || item.title || item.pubDate.to_s || Time.now.to_s)
                                            fname = File.join(*fpath)
                                            $logger.warn "Save enclosure: #{fname}"
                                            enc   = read_url(curl, 'rss_enclosure')
                                            write_file(fname, 'wb') {|io| io.puts enc}
                                            furl = file_url(fname)
                                            enclosure = rss_enclosure_local_copy(url, furl)
                                            if url_get(url, :rss_rewrite_enclosed_urls)
                                                idesc.gsub!(Regexp.new(Regexp.escape(curl))) {|t| furl}
                                            end
                                        else
                                            enclosure = %{<p class="enclosure"><a href="%s" class="enclosure" />Original Enclosure</a></p>} % curl
                                        end
                                    else
                                        enclosure = ''
                                    end
                                    rnew << format_rss_item(item, idesc, enclosure)
                                end
                            end
                        end
                        rnew.join("\n")
                    end
                end
            }

        shortcut :opml, :delegate => :rss,
            :download => lambda {|url|
                opml = open(url) {|io| io.read}
                if oplm
                    xml = Hpricot(opml)
                    # <+TBD+>Well, maybe would should search for outline[@type=rss]?
                    xml.search('//outline[@xmlurl]').each {|elt|
                        if elt['type'] =~ /rss/
                            curl = elt['xmlurl']
                            opts = @urls[url].dup
                            opts[:download] = :rss
                            opts[:title] = elt['title'] || elt['text'] || elt['htmlurl'] || curl
                            url_set(curl, opts)
                            to_do curl
                        else
                            $logger.warn "Unsupported type in OPML: #{elt.to_s}"
                        end
                    }
                end
                nil
            }

        shortcut :website, :delegate => :webdiff,
            :download => lambda {|url| get_website(:body_html, url)}

        shortcut :website_below, :delegate => :webdiff,
            :download => lambda {|url| get_website_below(:body_html, url)}

        shortcut :website_txt, :delegate => :default,
            :download => lambda {|url| html_to_text(get_website(url_get(url, :download_html, :openuri), url))}

        shortcut :website_txt_below, :delegate => :default,
            :download => lambda {|url| html_to_text(get_website_below(url_get(url, :download_html, :openuri), url))}

        shortcut :ftp, :delegate => :default,
            :download => lambda {|url| get_ftp(url).join("\n")}

        shortcut :ftp_recursive, :delegate => :default,
            :download => lambda {|url|
                list = get_ftp(url)
                depth = url_get(url, :depth)
                if !depth or depth >= 0
                    dirs = list.find_all {|e| e =~ /^d/}
                    dirs.each do |l|
                        sl = l.scan(/^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+ +\S+ +\S+)\s+(.+)$/)
                        perms, type, owner, group, size, date, dirname = sl[0]
                        curl = File.join(url, dirname, '')
                        opts = @urls[url].dup
                        opts[:title] = [opts[:title], File.basename(curl)].join(' - ')
                        opts[:depth] = depth - 1 if depth and depth >= 0
                        url_set(curl, opts)
                        to_do curl
                    end
                end
                list.join("\n")
            }

        shortcut :img, :delegate => :raw,
            :format => lambda {|new|
                file = file_url(new)
                %{<img src="#{file}" />}
            }

        @options[:page] = {
            :format => lambda {|ti, li, bd|
                template = <<OUT
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
<title>%s</title>
<meta http-equiv="Content-Type" content="text/html; charset=#{optval_get(:global, :encoding)}">
<link rel="stylesheet" href="websitary.css" type="text/css">
<link rel="alternate" href="websitary.rss" type="application/rss+xml" title="%s">
</head>
<script type="text/javascript">
function ToggleBody(Item) {
    var Body = document.getElementById(Item.id + "_body");
    if (Body.style.visibility == "collapse") {
        Body.style.visibility = "visible";
        Body.style.height = "";
        Item.style.background = "";
    } else {
        Body.style.visibility = "collapse";
        Body.style.height = "1px";
        Item.style.background = "#e0f0f0";
    }
    return '';
}
</script>
<body>
<ol class="toc">
%s
</ol>
<div class="contents">
%s
</div>
</body>
</html>
OUT
                template % [ti, ti, li, bd]
            },
            :css => <<CSS,
body {
    color: black;
    background-color: #f0f0f0;
}
a.external {
}
a.old {
}
a.latest {
}
a.toc {
}
ol.toc {
    float: left;
    width: 200px;
    height: 99%;
    overflow: scroll;
    position: fixed;
    padding: 0;
    margin: 0;
}
li.toc {
    list-style: none;
    border: 1px solid #e0e0e0;
    background-color: #fafafa;
    padding: 0.1em;
    font-size: 80%;
    font-family: Verdana, Myriad Web, Syntax, sans-serif;
}
li.toc:hover {
    background-color: #ffff8d;
}
div.contents {
    margin-left: 210px;
    min-width: 16em;
}
div.webpage {
    margin: 5px 0 5px 0;
    padding: 5px;
    border: 1px solid #e0e0e0;
    background-color: white;
}
div.count {
    text-align: right;
}
.enclosure {
    padding: 4px;
    margin: 4px 0 4px 0;
    background: #f9f9f9;
}
h1.diff {
    font-family: Verdana, Myriad Web, Syntax, sans-serif;
}
h2.rss {
    border-top: 10px solid #f0f0f0;
    padding-top: 10px;
}
div.diff {
    padding-left: 2em;
}
pre.diff {
    padding-left: 2em;
}
div.annotation {
    font-size: 80%;
}
hr.separator {
    width: 100%;
    visibility: hidden;
}
.error {
    color: yellow;
    background-color: red;
}
.highlight {
    background-color: #fac751;
}
.highlight-yellow {
    background-color: #ffc730;
}
.highlight-red {
    background-color: red;
}
.highlight-blue {
    background-color: blue;
}
.highlight-aqua {
    background-color: aqua;
}
CSS
        }
    end


    def migrate
        store = File.join(@cfgdir, 'version.yml')
        if File.exist?(store)
            version = YAML.load_file(store)
            return if version == Websitary::VERSION
        else
            version = '0.1.0'
        end
        va = version.split(/\./).map {|i| i.to_i}
        migrate_0_1_0 if (va <=> [0, 1, 0]) != 1
        write_file(store) {|f| YAML.dump(Websitary::VERSION, f)}
    end


    def migrate_0_1_0
        $logger.warn "Migrate data from version 0.1.0"
        ['latest', 'old'].each do |dir|
            files = Dir[File.join(@cfgdir, dir, '*')]
            files.each do |f|
                url = decode(File.basename(f))
                nfn = encoded_filename(dir, url, true)
                @app.move(f, nfn)
            end
        end
    end


    def eval_profile(contents, profile_file=nil)
        @current_profile = profile_file
        begin
            # self.instance_eval(contents, binding, __FILE__, __LINE__)
            eval(contents, binding, @current_profile)
            return true
        rescue Exception => e
            $logger.fatal "Error when reading profile: #{profile_file}\n#{e}\n#{e.backtrace[0..4].join("\n")}"
            exit 5
        ensure
            @current_profile = nil
        end
    end


    def get_website(download, url)
        html = call_cmd(optval_get(:download, download), [url], :url => url)
        if html
            doc = url_document(url, html)
            if doc
                return if robots?(doc, 'noindex')
                push_hrefs(url, doc) do |uri0, pn0, uri, pn|
                    eligible_path?(url, uri0.path, uri.path) &&
                        uri.host == uri0.host
                end
            end
        end
        html
    end


    def get_website_below(download, url)
        dwnl = optval_get(:download, download)
        html = call_cmd(dwnl, [url], :url => url)
        if html
            doc = url_document(url, html)
            if doc
                return if robots?(doc, 'noindex')
                push_hrefs(url, doc) do |uri0, pn0, uri, pn|
                    (uri.host || uri.is_a?(URI::Generic)) &&
                        (uri0.host || uri0.is_a?(URI::Generic)) &&
                        eligible_path?(url, uri0.path, uri.path) &&
                        uri.host == uri0.host &&
                        (pn.to_s == '.' || pn.relative_path_from(pn0).to_s == '.')
                end
            end
        end
        html
    end


    def get_ftp(url)
        uri = URI.parse(url)
        ftp = Net::FTP.new(uri.host)
        ftp.passive = true
        begin
            ftp.login
            ftp.chdir(uri.path)
            return ftp.list('*')
        rescue Exception => e
            $logger.error e
        ensure
            ftp.close
        end
    end


    def html_toc_id(url)
        't%s' % Digest::MD5.hexdigest(url)
    end


    def html_body_id(url)
        'b%s' % Digest::MD5.hexdigest(url)
    end


    def ensure_filename(filename)
        filename = filename.gsub(/[\/]{2,}/, File::SEPARATOR)
        # File.join(*File.split(filename))
        if filename =~ /#{Regexp.escape(File::SEPARATOR)}$/
            File.join(filename, '__WEBSITARY__')
        else
            parts = filename.split(/#{Regexp.escape(File::SEPARATOR)}/)
            if parts.size == 2 and parts[0] =~ /^\w+%3a$/
                File.join(filename, '__WEBSITARY__')
            else
                filename
            end
        end
    end


    def url_document(url, html)
        doc = html && Hpricot(html)
        if doc
            unless url_get(url, :title)
                ti = (doc / 'head > title').inner_html
                url_set(url, :title => ti) unless ti.empty?
            end
        end
        doc
    end


    def read_document(url)
        html = read_url(url, 'html')
        html && url_document(url, html)
    end


    def read_url(url, type='html')
        downloader = url_get(url, "download_#{type}".intern)
        if downloader
            call_cmd(downloader, [url], :url => url)
        else
            read_url_openuri(url)
        end
    end


    def read_url_openuri(url)
        if url.nil? or url.empty?
            $logger.fatal "Internal error: url is nil"
            puts caller.join("\n")
            exit 5
        end
        $logger.debug "Open URL: #{url}"
        uri = URI.parse(url)
        if uri.instance_of?(URI::Generic) or uri.scheme == 'file'
            open(url).read
        else
            args = {"User-Agent" => optval_get(:global, :user_agent)}
            args.merge!(url_get(url, :header, {}))
            # proxy = get_proxy
            # if proxy
            #     args[:proxy] = proxy[0,2].join(':')
            # end
            open(url, args).read
        end
    end


    def difftext_annotation(url)
        bak = oldname(url)
        lst = latestname(url)
        if File.exist?(bak) and File.exist?(lst)
            eval_arg(url_get(url, :format_annotation, '%s >>> %s'), [@mtimes.mtime(bak), @mtimes.mtime(lst)])
        end
    end


    def format_symbol(name, format_string)
        (format_string % name.to_s).intern
    end


    def rss_item_id(item)
        return Digest::MD5.hexdigest(item.to_s)
        # i = [item.author, item.title, item.link, item.description, item.enclosure].inspect
        # # p "DBG", i.inspect, Digest::MD5.hexdigest(i.inspect)
        # return Digest::MD5.hexdigest(i)
    end


    def rss_enclosure_local_copy(url, furl)
        t = url_get(url, :rss_format_local_copy) ||
            %{<p class="enclosure"><a href="%s" class="enclosure" />Enclosure (local copy)</a></p>}
        case t
        when Proc
            t.call(url, furl)
        when String
            t % furl
        else
            $logger.fatal 'Argument for :rss_format_local_copy must be String or Proc: %s' % t.inspect
            exit 5
        end
    end


    def format_rss_item(item, body, enclosure='')
        ti = rss_field(item, :title)
        au = rss_field(item, :author)
        hd = [ti]
        hd << " (#{au})" if au
        return <<EOT
<h2 class="rss"><a class="rss" href="#{rss_field(item, :link)}">#{hd.join} -- #{rss_field(item, :pubDate)}</a></h2>
<div class="rss">
#{body}
#{enclosure}
</div>
EOT
    end


    def rss_field(item, field, default=nil)
        if item.respond_to?(field)
            return item.send(field)
        else
            return default
        end
    end


    # Guess whether text is plain text or html.
    def is_html?(text)
        text =~ /<(div|a|span|body|html|script|p|table|td|tr|th|li|dt|br|hr|em|b)\b/
    end


    def get_proxy
        proxy = optval_get(:global, :proxy)
        if proxy
            case proxy
            when String
                proxy = proxy.split(':', 2)
                if proxy.size == 1
                    proxy << 8080
                else
                    proxy[1] = proxy[1].to_i
                end
            when Array
            else
                raise ArgumentError, 'proxy must be String or Array'
            end
        end
        proxy
    end


    def body_html(url, doc)
        doc &&= doc.at('body') || doc
        if doc
            doc  = rewrite_urls(url, doc)
            doc  = doc.inner_html
            if (tags = url_get(url, :strip_tags))
                doc = strip_tags(doc, :format => :hpricot, :tags => tags)
            end
        else
            $logger.warn 'inner html: No body'
        end
        doc
    end


    def doc_to_text(doc)
        doc && doc.to_plain_text
    end


    # Convert html to plain text using hpricot.
    def html_to_text(text)
        text && Hpricot(text).to_plain_text
    end


    # Retrieve any robots meta directives from the hpricot document.
    def robots?(hpricot, *what)
        meta(hpricot, 'robots').any? do |e|
            what.any? {|w| e['content'].split(/,\s*/).include?(w)}
        end
    end


    def meta(hpricot, name)
        hpricot / %{//meta[@name="#{name}"]}
    end


    # Check whether robots are allowed to retrieve an url.
    def robots_allowed?(url, uri)
        if @allow.has_key?(url)
            return @allow[url]
        end

        if defined?(RobotRules)
            host = uri.host

            unless (rules = @robots[host])
                rurl = robots_uri(uri).to_s
                return true if rurl.nil? or rurl.empty?
                begin
                    robots_txt = read_url(rurl, 'robots')
                    rules      = RobotRules.new(optval_get(:global, :user_agent))
                    rules.parse(rurl, robots_txt)
                    @robots[host] = rules
                    $logger.info "Loaded #{rurl} for #{optval_get(:global, :user_agent)}"
                    $logger.debug robots_txt
                rescue Exception => e
                    $logger.info "#{rurl}: #{e}"
                end
            end

            rv = if rules and !rules.allowed?(url)
                     $logger.info "Excluded url: #{url}"
                     false
                 else
                     true
                 end
            @allow[url] = rv
            return rv
        end

        unless @robots[:warning]
            $logger.warn 'robots.txt is ignored: Please install robot_rules.rb from http://blade.nagaokaut.ac.jp/cgi-bin/scat.rb/ruby/ruby-talk/177589 in $RUBYLIB'
            @robots[:warning] = true
        end
        @allow[url] = true
        return true
    end


    # Get the robots.txt uri for uri.
    def robots_uri(uri)
        unless uri.relative?
            # ruri = uri.dup
            # ruri.path = '/robots.txt'
            # ruri.query = nil
            # ruri
            uri.merge '/robots.txt'
        end
    end


    def sort_difftext!(difftext)
        difftext.sort! do |a, b|
            aa = a[0]
            bb = b[0]
            url_get(aa, :title, aa).downcase <=> url_get(bb, :title, bb).downcase
        end
    end


    def file_url(filename)
        # filename = File.join(File.basename(File.dirname(filename)), File.basename(filename))
        # "file://#{encode(filename, ':/')}"
        filename = call_cmd(optval_get(:global, :file_url), [filename], :default => filename)
        encode(filename, ':/')
    end


    def encode(text, chars='')
        text.gsub(/[^a-zA-Z0-9,._#{chars}-]/) {|t| '%%%02x' % t[0]}
    end


    def decode(text)
        text.gsub(/%(..)/) {|t| "%c" % $1.hex}
    end


    def output_suffix(outformat)
        outformat ||= @output_format[0]
        @suffix[outformat] || outformat
    end


    def output_basename
        @profiles.join(',')
    end


    def get_outfile(outformat=nil)
        @outfile[outformat] || File.join(@cfgdir, "#{output_basename}.#{output_suffix(outformat)}")
    end


    def view_output_general(outfile)
        if @view
            system((@view % outfile))
        end
    end
    alias :view_output_html :view_output_general
    alias :view_output_text :view_output_general
    alias :view_output_rss :view_output_general

end




# Local Variables:
# revisionRx: REVISION\s\+=\s\+\'
# End:
