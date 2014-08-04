listen 3000
timeout 120
worker_processes 4

GC.respond_to?(:copy_on_write_friendly=) and
  GC.copy_on_write_friendly = true
  
check_client_connection false