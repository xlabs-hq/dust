require "./dust/config"
require "./dust/output"
require "./dust/client/channel"
require "./dust/client/connection"
require "./dust/cli"

Dust::CLI.run(ARGV)
