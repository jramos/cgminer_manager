Rails.application.routes.draw do
  root 'manager#index'
  resources :miner, :only => [:show] do
    match 'run', to: 'miner#run', via: [:post]
  end
end
