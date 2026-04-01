require "./dust/config"
require "./dust/output"
require "./dust/glob"
require "./dust/cache/sqlite"
require "./dust/client/channel"
require "./dust/client/connection"
require "./dust/commands/auth"
require "./dust/commands/store"
require "./dust/commands/data"
require "./dust/cli"

Dust::CLI.run(ARGV)
