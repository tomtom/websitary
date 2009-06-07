# -*- ruby -*-

require 'rubygems'
require 'hoe'
load './lib/websitary.rb'

Hoe.new('websitary', Websitary::VERSION) do |p|
  p.rubyforge_name = 'websitiary'
  p.author = 'Tom Link'
  p.email = 'micathom at gmail com'
  p.summary = 'A unified website news, rss feed, podcast monitor'
  p.description = p.paragraphs_of('README.txt', 2..5).join("\n\n")
  p.url = p.paragraphs_of('README.txt', 0).first.split(/\n/)[1..-1]
  p.changes = p.paragraphs_of('History.txt', 0..1).join("\n\n")
  p.extra_deps << 'hpricot'
  # p.need_tgz = false
  p.need_zip = true
end

require 'rtagstask'
RTagsTask.new

task :ctags do
    puts `ctags --extra=+q --fields=+i+S -R bin lib`
end

task :files do
    puts `find bin lib -name "*.rb" > files.lst`
end

# vim: syntax=Ruby
