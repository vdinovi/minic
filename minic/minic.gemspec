# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'minic/version'

Gem::Specification.new do |spec|
  spec.name          = "minic"
  spec.version       = Minic::VERSION
  spec.authors       = ["vdinovi"]
  spec.email         = ["vito.dinovi@gmail.com"]

  spec.summary       = "A ruby compiler for the 'mini' programming language"
  spec.description   = "For CSC431 with Dr. Keen at Cal Poly SLO"
  spec.homepage      = ""

  spec.executables   = ["minic"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = '~> 2.0'

  spec.add_development_dependency "bundler", "~> 1.16"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "minitest", "~> 5.0"
end
