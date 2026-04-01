module Dust
  class CLI
    VERSION = "0.1.0"

    def self.run(args : Array(String))
      if args.empty?
        print_usage
        return
      end

      command = args[0]
      rest = args[1..]

      case command
      when "help", "--help", "-h"
        print_usage
      when "version", "--version"
        puts "dust #{VERSION}"
      else
        # Commands that require config
        config = Config.new

        case command
        when "login"      then Commands::Auth.login(config, rest)
        when "logout"     then Commands::Auth.logout(config, rest)
        when "create"     then Commands::Store.create(config, rest)
        when "stores"     then Commands::Store.list(config, rest)
        when "status"     then Commands::Store.status(config, rest)
        when "put"        then Commands::Data.put(config, rest)
        when "get"        then Commands::Data.get(config, rest)
        when "merge"      then Commands::Data.merge(config, rest)
        when "delete"     then Commands::Data.delete(config, rest)
        when "enum"       then Commands::Data.enum(config, rest)
        when "watch"      then Commands::Watch.watch(config, rest)
        when "log"        then Commands::Log.log(config, rest)
        when "rollback"   then Commands::Log.rollback(config, rest)
        when "increment"  then Commands::Types.increment(config, rest)
        when "add"        then Commands::Types.add(config, rest)
        when "remove"     then Commands::Types.remove(config, rest)
        when "put-file"   then Commands::Files.put_file(config, rest)
        when "fetch-file" then Commands::Files.fetch_file(config, rest)
        when "token"      then Commands::Token.token(config, rest)
        else
          STDERR.puts "Unknown command: #{command}"
          print_usage
          exit 1
        end
      end
    end

    def self.print_usage
      puts <<-USAGE
      dust — reactive global map CLI

      Usage: dust <command> [arguments]

      Commands:
        login                         Authenticate with Dust
        logout                        Clear credentials
        create <store>                Create a store
        stores                        List stores
        status [store]                Show sync status

        put <store> <path> <json>     Set a value
        get <store> <path>            Read a value
        merge <store> <path> <json>   Merge keys
        delete <store> <path>         Delete a path
        enum <store> <pattern>        List matching entries

        increment <store> <path> [n]  Increment counter
        add <store> <path> <member>   Add to set
        remove <store> <path> <member> Remove from set

        put-file <store> <path> <file> Upload file
        fetch-file <store> <path> <dest> Download file

        watch <store> <pattern>       Stream changes
        log <store> [options]         Audit log
        rollback <store> [options]    Rollback

        token create|list|revoke      Manage tokens

      Options:
        --version                     Show version
        --help, -h                    Show this help

      USAGE
    end
  end
end
