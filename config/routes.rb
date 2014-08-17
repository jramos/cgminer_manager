Rails.application.routes.draw do
  root 'manager#index'

  match 'manager/run', to: 'manager#run', via: [:post]
  match 'manager/manage_pools', to: 'manager#manage_pools', via: [:post]

  resources :miner, :only => [:show] do
    match 'run', to: 'miner#run', via: [:post]
    match 'manage_pools', to: 'miner#manage_pools', via: [:post]
  end

  namespace :api do
    namespace :v1 do
      get '/ping.(:format)' => 'ping#index'
    end
  end

  mount CgminerMonitor::Engine => '/'
end
