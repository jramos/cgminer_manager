# CgminerManager

A web manager for cgminer written in Ruby on Rails. It allows for remote management and monitoring of a multiple cgminer instances. Features include:

* Pool and miner summary pages
* Hashrate, temperature and error rate graphs via [cgminer_monitor](https://github.com/jramos/cgminer_monitor)
* Breakdown of miner performance and configuration
* Audio notifications when things go awry
* Quick updates to mining pool configuration
* Multi-command support; send API commands or raw payloads in bulk

## Dependencies

* [Ruby](https://www.ruby-lang.org) (~> 2.0.0, ~> 2.1.0)
* [bundler](http://bundler.io/) (~> 1.6.0)
* [mongodb](http://www.mongodb.org/) (~> 2.6)
* [jramos/cgminer\_api\_client](https://github.com/jramos/cgminer_api_client) (~> 0.2)
* [jramos/cgminer\_monitor](https://github.com/jramos/cgminer_monitor) (~> 0.2)

## Screenshots

### Pool Summary
![Summary](public/screenshots/summary.png)

### Pool Detail
![Miner Pool](public/screenshots/miner-pool.png)

### Miner Detail
![Miner](public/screenshots/miner.png)

## Installation

    git clone git@github.com:jramos/cgminer_manager.git
    cd cgminer_manager
    bundle install

## Configuration

### cgminer\_api\_client

Copy [``config/miners.yml.example``](https://github.com/jramos/cgminer_manager/blob/master/config/miners.yml.example) to ``config/miners.yml`` and update with the IP addresses (and optional ports and timeouts) of your cgminer instances. E.g.

    # connect to localhost on the default port (4028) with the default timeout (5 seconds)
    - host: 127.0.0.1
    # connect to 192.168.1.1 on a non-standard port (1234) with a custom timeout (1 second)
    - host: 192.168.1.1
      port: 1234
      timeout: 1

See [cgminer\_api\_client](https://github.com/jramos/cgminer_api_client#configuration) for more information.

### cgminer\_monitor

Copy [``config/mongoid.yml.example``](https://github.com/jramos/cgminer_manager/blob/master/config/mongoid.yml.example) to ``config/mongoid.yml`` and update as necessary.

    production:
      sessions:
        default:
          database: cgminer_monitor
          hosts:
            - localhost:27017

See [cgminer\_monitor](https://github.com/jramos/cgminer_monitor#configuration) for more information.

### UI Options

You can adjust these options by editing `app/assets/javascripts/config.js`.

#### Page Refreshing

The data on each page of the site will refresh every minute (60 seconds) by default. You can adjust this via `reload_interval`. Change to 0 to disable refreshing.

    var config = {
      // data reload interval in seconds
      reload_interval : 300,  // 5 minutes
    
      // Enable audio notifications
      enable_audio: true,
    
      // misc UI options
      show_github_ribbon: true
    }

#### Disable Audio Notifications

By default, audio is played when a warning is triggered, such as when a miner becomes unavailable or an ASC reports a bad chip. This can be disabled via the `enable_audio` configuration option. Set it to false if you don't want to hear audio notifications. You can toggle this setting in the UI, as well.

    var config = {
      // data reload interval in seconds
      reload_interval : 60,  // 1 minute
    
      // Enable audio notifications
      enable_audio: false,
    
      // misc UI options
      show_github_ribbon: true
    }

#### Disable Fork Ribbon

To hide the "Fork Me" ribbon on the top right, change `show_github_ribbon` to false.

    var config = {
      // data reload interval in seconds
      reload_interval : 60,  // 1 minute
    
      // Enable audio notifications
      enable_audio: false,
    
      // misc UI options
      show_github_ribbon: false
    }

## Running

### Note

This application is designed to be used on a secure local network. By default, it will only allow access from 127.0.0.1. Allowing access from other IP addresses is discouraged, since it would allow anyone on your local network and possibly the internet at large to run arbirary commands on your mining pool.

### Automatically

    rake server

### Manually

    env RAILS_ENV=production rake assets:clobber
    env RAILS_ENV=production rake assets:precompile
    env SECRET_KEY_BASE=`rake secret` bundle exec rails server thin -e production --binding=127.0.0.1

Connect to [http://127.0.0.1:3000/](http://127.0.0.1:3000/) in your browser.

## Updating

    git pull
    bundle install

## Contributing

1. Fork it ( https://github.com/jramos/cgminer_manager/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Donating

If you find this application useful, please consider donating.

BTC: ``18HFFqZv2KJMHPNwPes839PJd5GZc4cT3U``

## License

Code released under [the MIT license](LICENSE.txt).
