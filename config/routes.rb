Rails.application.routes.draw do
  root 'manager#index'
  resources :miner, :only => [:show]
end
