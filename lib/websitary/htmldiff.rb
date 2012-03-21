#!/usr/bin/env ruby
# htmldiff.rb
# @Last Change: 2010-10-25.
# Author::      Thomas Link (micathom at gmail com)
# License::     GPL (see http://www.gnu.org/licenses/gpl.txt)
# Created::     2007-08-17.
# 
# == Basic Use
#   htmldiff OLD NEW [HIGHLIGHT-COLOR] > DIFF

module Websitary
end


require 'websitary/document'


module Websitary
    # A simple class to generate diffs for html files using hpricot. 
    # It's quite likely that it will miss certain details and yields 
    # wrong results (especially wrong-negative) in certain occasions.
    class Htmldiff
        VERSION  = '0.1'
        REVISION = '180'
       
        # args:: A hash
        # Fields:
        # :oldtext:: The old version
        # :newtext:: The new version
        # :highlight:: Don't strip old content but highlight new one with this color
        # :args::    Command-line arguments
        def initialize(args)
            @args = args
            @high = args[:highlight] || args[:highlightcolor]
            @old  = explode(args[:olddoc] || Document(args[:oldtext] || File.read(args[:oldfile])))
            @new  =         args[:newdoc] || Document(args[:newtext] || File.read(args[:newfile]))
            @ignore  = args[:ignore]
            if @ignore and !@ignore.kind_of?(Enumerable)
                die "Ignore must be of kind Enumerable: #{ignore.inspect}"
            end
            @changed = false
        end


        # Do the diff. Return an empty string if nothing has changed.
        def diff
            rv = process.to_s
            @changed ? rv : ''
        end


        # It goes like this: if a node isn't in the list of old nodes either 
        # the node or its content has changed. If the content is a single 
        # node, the whole node has changed. If only some sub-nodes have 
        # changed, collect those.
        def process(node=@new)
            acc = []
            node.each_child do |child|
                ch = child.to_html.strip
                next if ch.nil? or ch.empty?
                if @old.include?(ch) or ignore(child, ch)
                    if @high
                        acc << child
                    end
                else
                    if child.respond_to?(:each_child)
                        acc << process(child)
                    else
                        acc << highlight(child).to_s
                        acc << '<br />' unless @high
                    end
                end
            end
            replace_inner(node, acc.join("\n"))
        end


        def ignore(node, node_as_string)
            return @ignore && @ignore.any? do |i|
                case i
                when Regexp
                    node_as_string =~ i
                when Proc
                    l.call(node)
                else
                    die "Unknown type for ignore expression: #{i.inspect}"
                end
            end
        end


        # Collect all nodes and subnodes in a hpricot document.
        def explode(node)
            if node.respond_to?(:each_child)
                acc = [node.to_html.strip]
                node.each_child do |child|
                    acc += explode(child)
                end
                acc
            else
                [node.to_html.strip]
            end
        end


        def highlight(child)
            @changed = true
            if @high
                if child.respond_to?(:each_child)
                    acc = []
                    child.each_child do |ch|
                        acc << replace_inner(ch, highlight(ch).to_s)
                    end
                    replace_inner(child, acc.join("\n"))
                else
                    case @args[:highlight]
                    when String
                        opts = %{class="#{@args[:highlight]}"}
                    when true, Numeric
                        opts = %{class="highlight"}
                    else
                        opts = %{style="background-color: #{@args[:highlightcolor]};"}
                    end
                    ihtml = %{<span #{opts}>#{child.to_s}</span>}
                    replace_inner(child, ihtml)
                end
            else
                child
            end
        end


        def replace_inner(child, ihtml)
            case child
            when Document::Comment
                child
            when Document::Text
                Document(ihtml)
            else
                child.inner_html = ihtml
                child
            end
        end

    end
end


if __FILE__ == $0
    old, new, aargs = ARGV
    if old and new
        args = {:args => aargs, :oldfile => old, :newfile => new}
        args[:highlightcolor], _ = aargs
        acc = Websitary::Htmldiff.new(args).diff
        puts acc
    else
        puts "#{File.basename($0)} OLD NEW [HIGHLIGHT-COLOR] > DIFF"
    end
end


# Local Variables:
# revisionRx: REVISION\s\+=\s\+\'
# End:
