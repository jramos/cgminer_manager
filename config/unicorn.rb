listen 3000
timeout 30
worker_processes 4
preload_app true

GC.respond_to?(:copy_on_write_friendly=) and
  GC.copy_on_write_friendly = true
  
check_client_connection false