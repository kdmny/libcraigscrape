NAME = "libcraigscrape"
VERS = ENV['VERSION'] || "1.0"
PKG = "#{NAME}-#{VERS}"

RDOC_OPTS = ['--quiet', '--title', 'The libcraigscrape Reference', '--main', 'README', '--inline-source']
RDOC_FILES = ['README', "CHANGELOG", "COPYING","COPYING.LESSER", 'bin/craigwatch']
PKG_FILES = (%w(Rakefile) + RDOC_FILES + Dir.glob("{bin,test,lib}/**/*")).uniq.sort_by{|a,b| (a == 'lib/libcraigscrape.rb') ? -1 : 0 }

Gem::Specification.new do |s|
  s.name = NAME
  s.version = VERS
  s.platform = Gem::Platform::RUBY
  s.has_rdoc = true
  s.bindir = 'bin'
  s.executables = 'craigwatch'
  s.rdoc_options += RDOC_OPTS
  s.extra_rdoc_files = RDOC_FILES
  s.summary = "quick, easy, craigslist parsing library that takes the monotony out of working with craigslist posts and listings"
  s.description = s.summary
  s.author = "Chris DeRose, DeRose Technologies, Inc."
  s.email = 'cderose@derosetechnologies.com'
  s.homepage = 'http://www.derosetechnologies.com/community/libcraigscrape'
  s.rubyforge_project = 'libcraigwatch'
  s.files = PKG_FILES
  s.require_paths = ["lib"]
  s.test_files = FileList['test/test_*.rb']
  s.add_dependency 'nokogiri',     '>= 1.5.0'
  s.add_dependency 'htmlentities', '>= 4.0.0'
  s.add_dependency 'activesupport','>= 2.3.0', '< 3'
  s.add_dependency 'activerecord', '>= 2.3.0', '< 3'
  s.add_dependency 'actionmailer', '>= 2.3.0', '< 3'
  s.add_dependency 'kwalify', '>= 0.7.2'
  s.add_dependency 'sqlite3'
end