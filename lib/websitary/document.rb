# xml.rb
# @Author:      Tom Link (micathom AT gmail com)
# @License:     GPL (see http://www.gnu.org/licenses/gpl.txt)
# @Created:     2010-10-24.
# @Last Change: 2010-10-25.
# @Revision:    0.0.31

begin
#     require 'nokogiri'
#     Websitary::Document = Nokogiri
#     Websitary::Document::Comment = Nokogiri::XML::Comment
#     Websitary::Document::Text = Nokogiri::XML::Text
#     def Document(*args, &block)
#         Nokogiri(*args, &block)
#     end
#     # puts "Use nokogiri"
# rescue LoadError => e
    require 'hpricot'
    Websitary::Document = Hpricot
    def Document(*args, &block)
        Hpricot(*args, &block)
    end
    # puts "Use hpricot"
end

