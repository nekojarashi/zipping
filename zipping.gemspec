# encoding: utf-8
lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)

Gem::Specification.new do |s|
  s.name        = "zipping"
  s.version     = "0.2.1"
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Shuntaro Shitasako"]
  s.email       = ["info@nekojarashi.com.com"]
  s.homepage    = "http://www.nekojarashi.com"
  s.summary     = "Compress files as a zip and output it to a stream."
  s.description = "This gem is for compressing files as a zip and outputting to a stream (or a stream-like interface object). The output to a stream proceeds little by little, as files are compressed."
  s.license     = "MIT"

  s.add_dependency("rubyzip", [">= 1.0.0"])
  s.add_dependency("zip-zip", ["~> 0.2"])

  s.files        = Dir.glob("lib/**/*") + %w(LICENSE README.md Rakefile)
  s.test_files   = Dir.glob("spec/**/*")
  s.require_path = 'lib'
end