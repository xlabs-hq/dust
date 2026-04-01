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
        when "watch"      then not_yet("watch")
        when "log"        then not_yet("log")
        when "rollback"   then not_yet("rollback")
        when "increment"  then not_yet("increment")
        when "add"        then not_yet("add")
        when "remove"     then not_yet("remove")
        when "put-file"   then not_yet("put-file")
        when "fetch-file" then not_yet("fetch-file")
        when "token"      then not_yet("token")
        else
          STDERR.puts "Unknown command: #{command}"
          print_usage
          exit 1
        end
      end
    end

    private def self.not_yet(command : String)
      STDERR.puts "Command '#{command}' is not yet implemented."
      exit 1
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
