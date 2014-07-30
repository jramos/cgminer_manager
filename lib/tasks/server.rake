task :server do
  new_rake_secret = %x( rake secret ).strip
  exec("env SECRET_KEY_BASE=#{new_rake_secret} bundle exec rails server --binding=127.0.0.1 -e production")
end