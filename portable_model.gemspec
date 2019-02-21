# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "portable_model/version"

Gem::Specification.new do |s|
  s.name        = "portable_model"
  s.version     = PortableModel::VERSION
  s.authors     = ["FutureAdvisor"]
  s.email       = ["core.platform@futureadvisor.com"]
  s.homepage    = %q{http://github.com/FutureAdvisor/portable_model}
  s.summary     = %q{Enables exporting and importing an ActiveRecord model's records.}
  s.description = %q{Enables exporting and importing an ActiveRecord model's records.}

  s.add_dependency('activerecord',  '>= 2.3.8')

  s.rubyforge_project = "portable_model"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
end
