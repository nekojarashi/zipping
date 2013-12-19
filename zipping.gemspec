# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'zipping/version'

Gem::Specification.new do |spec|
  spec.name          = "zipping"
  spec.version       = Zipping::VERSION
  spec.authors       = ["Shuntaro Shitasako"]
  spec.email         = ["info@nekojarashi.com.com"]
  spec.description   = "This gem is for compressing files as a zip and outputting to a stream (or a stream-like interface object). The output to a stream proceeds little by little, as files are compressed."
  spec.summary       = "Compress files as a zip and output it to a stream."
  spec.homepage      = "http://www.nekojarashi.com"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"

  spec.add_dependency("rubyzip", [">= 1.0.0"])
  spec.add_dependency("zip-zip", ["~> 0.2"])
end
