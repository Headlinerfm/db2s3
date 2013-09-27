Gem::Specification.new do |s|
  s.name              = "db2s3"
  s.version           = "0.0.1"
  s.summary           = "db2s3 provides rake tasks for backing up and restoring your DB to cloud storage providers"
  s.description       = "db2s3 provides rake tasks for backing up and restoring your DB to cloud storage providers"
  s.author            = "Bill Cromie"
  s.email             = ["cromie@headliner.fm"]
  s.homepage          = "http://github.com/cromulus/db2s3"
  s.has_rdoc          = true
  s.rdoc_options      << "--title" << "db2s3" << "--line-numbers"
  s.files             = Dir.glob("lib/**/*") + ["README.rdoc", "HISTORY"]
  s.required_rubygems_version = ">=1.3.2"
  s.required_ruby_version = ">=1.8.7"

  s.add_development_dependency("rake")
  s.add_development_dependency("mysql2")
  s.add_development_dependency("rspec", "~>2.6")
end
