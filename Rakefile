require "rake/testtask"

Rake::TestTask.new do |t|
  t.test_files = FileList["test/**/test_*.rb"]
  t.warning = false
end

desc "Run mutation tests"
task :mutant do
  sh "bundle exec mutant run"
end

task default: :test
