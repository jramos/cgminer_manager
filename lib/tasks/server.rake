desc "Precompile assets and run the application in production mode"
task :server do
  new_rake_secret = %x( rake secret ).strip
  `env RAILS_ENV=production rake assets:clobber`
  `env RAILS_ENV=production rake assets:precompile`
  exec("env SECRET_KEY_BASE=#{new_rake_secret} bundle exec rails server thin -e production --binding=127.0.0.1")
end