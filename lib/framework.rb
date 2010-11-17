=begin
                  Arachni
  Copyright (c) 2010 Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>

  This is free software; you can copy and distribute and modify
  this program under the term of the GPL v2.0 License
  (See LICENSE file for details)

=end


require 'rubygems'

require File.expand_path( File.dirname( __FILE__ ) ) + '/options'
opts = Arachni::Options.instance

require opts.dir['lib'] + 'ruby'
require opts.dir['lib'] + 'exceptions'
require opts.dir['lib'] + 'spider'
require opts.dir['lib'] + 'parser'
require opts.dir['lib'] + 'audit_store'
require opts.dir['lib'] + 'vulnerability'
require opts.dir['lib'] + 'module'
require opts.dir['lib'] + 'plugin'
require opts.dir['lib'] + 'http'
require opts.dir['lib'] + 'report'
require opts.dir['lib'] + 'component_manager'
require 'yaml'
require 'ap'
require 'pp'


module Arachni

    #
    # Resets the Framework providing a clean slate.
    #
    # This is useful to user interfaces that require the framework to be reused.
    #
    def self.reset
        Element::Auditable.reset
        Module::Manager.reset
        Report::Manager.reset
        Arachni::HTTP.instance.reset
    end

#
# Arachni::Framework class
#
# The Framework class ties together all the components.<br/>
# It should be wrapped by a UI class.
#
# It's the brains of the operation, it bosses the rest of the classes around.<br/>
# It runs the audit, loads modules and reports and runs them according to
# user options.
#
# @author: Tasos "Zapotek" Laskos
#                                      <tasos.laskos@gmail.com>
#                                      <zapotek@segfault.gr>
# @version: 0.2
#
class Framework

    #
    # include the output interface but try to use it as little as possible
    #
    # the UI classes should take care of communicating with the user
    #
    include Arachni::UI::Output
    include Arachni::Module::Utilities

    # the universal system version
    VERSION      = '0.2.1'

    # the version of *this* class
    REVISION     = '0.2'

    #
    # Instance options
    #
    # @return [Options]
    #
    attr_reader :opts

    #
    # @return   [Arachni::Report::Manager]   report manager
    #
    attr_reader :reports

    #
    # @return   [Arachni::Module::Manager]   module manager
    #
    attr_reader :modules

    #
    # @return   [Arachni::Plugin::Manager]   plugin manager
    #
    attr_reader :plugins

    #
    # @return   [Arachni::Spider]   spider
    #
    attr_reader :spider

    #
    # @return   [Arachni::HTTP]
    #
    attr_reader :http

    #
    # Holds candidate pages to be audited.
    #
    # Pages in the queue are pushed in by the trainer, the queue doesn't hold
    # pages returned by the spider.
    #
    # Plug-ins can push their own pages to be audited if they wish to...
    #
    # @return   [Queue<Arachni::Parser::Page>]   page queue
    #
    attr_reader :page_queue


    #
    # Initializes system components.
    #
    # @param    [Options]    opts
    #
    def initialize( opts )

        Encoding.default_external = "BINARY"
        Encoding.default_internal = "BINARY"

        @opts = opts

        @modules = Arachni::Module::Manager.new( @opts )
        @reports = Arachni::Report::Manager.new( @opts )
        @plugins = Arachni::Plugin::Manager.new( self )

        @page_queue = Queue.new

        prepare_cookie_jar( )
        prepare_user_agent( )

        # deep clone the redundancy rules to preserve their counter
        # for the reports
        @orig_redundant = @opts.redundant.deep_clone

        @running = false

    end

    def http
        Arachni::HTTP.instance
    end

    #
    # Runs the system
    #
    # It parses the instanse options and runs the audit
    #
    def run
        @running = true

        @spider = Arachni::Spider.new( @opts )

        @opts.start_datetime = Time.now

        # run all plugins
        @plugins.run

        # catch exceptions so that if something breaks down or the user opted to
        # exit the reports will still run with whatever results
        # Arachni managed to gather
        begin
            # start the audit
            audit( )
        rescue Exception

        end

        @opts.finish_datetime = Time.now
        @opts.delta_time = @opts.finish_datetime - @opts.start_datetime

        # make sure this is disabled or it'll break report output
        @@only_positives = false

        @running = false

        # wait for the plugins to finish
        @plugins.block!

        # a plug-in may have updated the page queue, rock it!
        audit_queue

        # refresh the audit store
        audit_store( true )

        # run reports
        if( @opts.reports )
            exception_jail{ @reports.run( audit_store( ) ) }
        end

        # save the AuditStore in a file
        if( @opts.repsave && !@opts.repload )
            exception_jail{ audit_store_save( @opts.repsave ) }
        end

        return true
    end

    def stats( )
        req_cnt = http.request_count
        res_cnt = http.response_count

        return {
            :requests   => req_cnt,
            :responses  => res_cnt,
            :time       => audit_store.delta_time,
            :avg        => ( req_cnt / @opts.delta_time ).to_i.to_s
        }
    end

    #
    # Audits the site.
    #
    # Runs the spider, analyzes each page as it appears and passes it
    # to (#run_mods} to be audited.
    #
    def audit

        # initiates the crawl
        @sitemap = @spider.run {
            | page |

            exception_jail{
                run_mods( page )
            }
        }

        if( @opts.http_harvest_last )
            harvest_http_responses( )
        end

    end

    def audit_queue

        # this will run until no new elements appear for the given page
        while( !@page_queue.empty? && page = @page_queue.pop )

            # audit the page
            run_mods( page )

            # run all the queued HTTP requests and harvest the responses
            http.run

            # check to see if the page was updated
            page = http.trainer.page
            # and push it in the queue to be audited as well
            @page_queue << page if page

        end
    end


    #
    # Returns the results of the audit as an {AuditStore} instance
    #
    # @see AuditStore
    #
    # @return    [AuditStore]
    #
    def audit_store( fresh = false )

        # restore the original redundacy rules and their counters
        @opts.redundant = @orig_redundant
        opts = @opts.to_h
        opts['mods'] = @modules.keys

        if( !fresh && @store )
            return @store
        else
            return @store = AuditStore.new( {
                :version  => VERSION,
                :revision => REVISION,
                :options  => opts,
                :sitemap  => @sitemap ? @sitemap.sort : ['N/A'],
                :vulns    => @modules.results( ).deep_clone
            } )
         end
    end


    #
    # Saves an AuditStore instance in 'file'
    #
    # @param    [String]    file
    #
    def audit_store_save( file )

        file += @reports.extension

        print_line( )
        print_status( 'Dumping audit results in \'' + file  + '\'.' )

        audit_store.save( file )

        print_status( 'Done!' )
    end

    #
    # Returns an array of hashes with information
    # about all available modules
    #
    # @return    [Array<Hash>]
    #
    def lsmod

        mod_info = []
        @modules.available( ).each {
            |name|

            path = @modules.name_to_path( name )
            next if !lsmod_match?( path )

            info = @modules[name].info( )

            info[:mod_name]    = name
            info[:name]        = info[:name].strip
            info[:description] = info[:description].strip

            if( !info[:dependencies] )
                info[:dependencies] = []
            end

            info[:author]    = info[:author].strip
            info[:version]   = info[:version].strip
            info[:path]      = path.strip

            mod_info << info
        }

        # unload all modules
        @modules.clear( )

        return mod_info

    end

    #
    # Returns an array of hashes with information
    # about all available reports
    #
    # @return    [Array<Hash>]
    #
    def lsrep

        rep_info = []
        @reports.available( ).each {
            |report|

            info = @reports[report].info

            info[:rep_name]    = report
            info[:path]        = @reports.name_to_path( report )

            rep_info << info
        }
        @reports.clear( )

        return rep_info
    end

    #
    # Returns an array of hashes with information
    # about all available reports
    #
    # @return    [Array<Hash>]
    #
    def lsplug

        plug_info = []

        @plugins.available( ).each {
            |plugin|

            info = @plugins[plugin].info

            info[:plug_name]   = plugin
            info[:path]        = @plugins.name_to_path( plugin )

            plug_info << info
        }

        @plugins.clear( )

        return plug_info
    end

    def running?
        @running
    end

    def paused?
        @paused || false
    end

    def pause!
        @paused = true
    end

    def resume!
        @paused = false
    end

    #
    # Returns the version of the framework
    #
    # @return    [String]
    #
    def version
        VERSION
    end

    #
    # Returns the revision of the {Framework} (this) class
    #
    # @return    [String]
    #
    def revision
        REVISION
    end

    private

    #
    # Prepares the user agent to be used throughout the system.
    #
    def prepare_user_agent
        if( !@opts.user_agent )
            @opts.user_agent = 'Arachni/' + VERSION
        end

        if( @opts.authed_by )
            authed_by         = " (Scan authorized by: #{@opts.authed_by})"
            @opts.user_agent += authed_by
        end

    end

    def prepare_cookie_jar(  )
        return if !@opts.cookie_jar || !@opts.cookie_jar.is_a?( String )

        # make sure that the provided cookie-jar file exists
        if !File.exist?( @opts.cookie_jar )
            raise( Arachni::Exceptions::NoCookieJar,
                'Cookie-jar \'' + @opts.cookie_jar + '\' doesn\'t exist.' )
        else
            @opts.cookies = http.class.parse_cookiejar( @opts.cookie_jar )
        end

    end


    #
    # Takes care of page audit and module execution
    #
    # It will audit one page at a time as discovered by the spider <br/>
    # and recursively check for new elements that may have <br/>
    # appeared during the audit.
    #
    # When no new elements appear the recursion will stop and a new page<br/>
    # will be accepted.
    #
    # @see Page
    #
    # @param    [Page]    page
    #
    def run_mods( page )
        return if !page

        @modules.each_pair {
            |name, mod|

            while( paused? )
                ::IO::select( nil, nil, nil, 1 )
            end

            run_mod( mod, page.deep_clone )
        }

        if( !@opts.http_harvest_last )
            harvest_http_responses( )
        end

    end

    def harvest_http_responses

       print_status( 'Harvesting HTTP responses...' )
       print_info( 'Depending on server responsiveness and network' +
        ' conditions this may take a while.' )

       # run all the queued HTTP requests and harvest the responses
       http.run

       # try to get an updated page from the Trainer
       page = http.trainer.page

       # if there was an updated page push it in the queue
       @page_queue << page if page
       audit_queue
    end

    #
    # Passes a page to the module and runs it.<br/>
    # It also handles any exceptions thrown by the module at runtime.
    #
    # @see Page
    #
    # @param    [Class]   mod      the module to run
    # @param    [Page]    page
    #
    def run_mod( mod, page )
        return if !run_mod?( mod, page )

        begin

            # instantiate the module
            mod_new = mod.new( page )

            mod_new.prepare
            mod_new.run
            mod_new.clean_up
        rescue Exception => e
            print_error( 'Error in ' + mod.to_s + ': ' + e.to_s )
            print_debug_backtrace( e )
        end
    end

    #
    # Determines whether or not to run the module against the given page
    # depending on which elements exist in the page, which elements the module
    # is configured to audit and user options.
    #
    # @param    [Class]   mod      the module to run
    # @param    [Page]    page
    #
    # @return   [Bool]
    #
    def run_mod?( mod, page )
        return true if( !mod.info[:elements] || mod.info[:elements].empty? )

        elems = {
            Vulnerability::Element::LINK => page.links && page.links.size > 0 && @opts.audit_links,
            Vulnerability::Element::FORM => page.forms && page.forms.size > 0 && @opts.audit_forms,
            Vulnerability::Element::COOKIE => page.cookies && page.cookies.size > 0 && @opts.audit_cookies,
            Vulnerability::Element::HEADER => page.headers && page.headers.size > 0 && @opts.audit_headers,
        }

        elems.each_pair {
            |elem, expr|
            return true if mod.info[:elements].include?( elem ) && expr
        }

        return false
    end

    def lsmod_match?( path )
        cnt = 0
        @opts.lsmod.each {
            |filter|
            cnt += 1 if path =~ filter
        }
        return true if cnt == @opts.lsmod.size
    end

end

end
