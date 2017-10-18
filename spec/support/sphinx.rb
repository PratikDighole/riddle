# frozen_string_literal: true

require 'erb'
require 'yaml'
require 'tempfile'

if RUBY_PLATFORM == 'java'
  require 'java'
  require 'jdbc/mysql'
  Jdbc::MySQL.load_driver
end

if ENV["TRAVIS"] == "true"
  FIXTURE_COMMAND = "LOAD DATA INFILE"
else
  FIXTURE_COMMAND = "LOAD DATA LOCAL INFILE"
end

class Sphinx
  attr_accessor :host, :username, :password

  def initialize
    self.host     = 'localhost'
    self.username = 'root'
    self.password = ''

    if File.exist?('spec/fixtures/sql/conf.yml')
      config    = YAML.load(File.open('spec/fixtures/sql/conf.yml'))
      self.host     = config['host']
      self.username = config['username']
      self.password = config['password']
    end
  end

  def setup_mysql
    return setup_mysql_on_jruby if RUBY_PLATFORM == 'java'

    client = Mysql2::Client.new(
      :host     => host,
      :username => username,
      :password => password
    )

    databases = client.query('SHOW DATABASES', :as => :array).to_a.flatten
    unless databases.include?('riddle')
      client.query 'CREATE DATABASE riddle'
    end

    client.query 'USE riddle'

    structure = File.open('spec/fixtures/sql/structure.sql') { |f| f.read }
    structure.split(/;/).each { |sql| client.query sql }
    sql_file 'data.tsv' do |path|
      client.query <<-SQL
        #{FIXTURE_COMMAND} '#{path}' INTO TABLE
        `riddle`.`people` FIELDS TERMINATED BY ',' ENCLOSED BY "'" (gender,
        first_name, middle_initial, last_name, street_address, city, state,
        postcode, email, birthday)
      SQL
    end

    client.close
  end

  def setup_mysql_on_jruby
    address    = "jdbc:mysql://#{host}"
    properties = Java::JavaUtil::Properties.new
    properties.setProperty "user", username     if username
    properties.setProperty "password", password if password

    client = Java::ComMysqlJdbc::Driver.new.connect address, properties

    set       = client.createStatement.executeQuery('SHOW DATABASES')
    databases = []
    databases << set.getString(1) while set.next

    unless databases.include?('riddle')
      client.createStatement.execute 'CREATE DATABASE riddle'
    end

    client.createStatement.execute 'USE riddle'

    structure = File.open('spec/fixtures/sql/structure.sql') { |f| f.read }
    structure.split(/;/).each { |sql| client.createStatement.execute sql }
    sql_file 'data.tsv' do |path|
      client.createStatement.execute <<-SQL
        #{FIXTURE_COMMAND} '#{path}' INTO TABLE
        `riddle`.`people` FIELDS TERMINATED BY ',' ENCLOSED BY "'" (gender,
        first_name, middle_initial, last_name, street_address, city, state,
        postcode, email, birthday)
      SQL
    end
  end

  def generate_configuration
    template = File.open('spec/fixtures/sphinx/configuration.erb') { |f| f.read }
    File.open('spec/fixtures/sphinx/spec.conf', 'w') { |f|
      f.puts ERB.new(template).result(binding)
    }

    FileUtils.mkdir_p "spec/fixtures/sphinx/binlog"
  end

  def index
    cmd = "#{bin_path}indexer --config #{fixtures_path}/sphinx/spec.conf --all"
    cmd << ' --rotate' if running?
    `#{cmd}`
  end

  def start
    return if running?

    `#{bin_path}searchd --config #{fixtures_path}/sphinx/spec.conf`

    sleep(1)

    unless running?
      puts 'Failed to start searchd daemon. Check fixtures/sphinx/searchd.log.'
    end
  end

  def stop
    return unless running?

    stop_flag = '--stopwait'
    stop_flag = '--stop' if Riddle.loaded_version.to_i < 1
    `#{bin_path}searchd --config #{fixtures_path}/sphinx/spec.conf #{stop_flag}`
  end

  private

  def bin_path
    @bin_path ||= begin
      path = (ENV['SPHINX_BIN'] || '').dup
      path.insert -1, '/' if path.length > 0 && path[/\/$/].nil?
      path
    end
  end

  def fixtures_path
    File.expand_path File.join(File.dirname(__FILE__), '..', 'fixtures')
  end

  def pid
    if File.exists?("#{fixtures_path}/sphinx/searchd.pid")
      `cat #{fixtures_path}/sphinx/searchd.pid`[/\d+/]
    else
      nil
    end
  end

  def running?
    pid && `ps #{pid} | wc -l`.to_i > 1
  end

  def sql_file(name, &block)
    file = Tempfile.new(name)
    file.write File.read("#{fixtures_path}/sql/#{name}")
    `chmod +r #{file.path}`
    file.flush

    block.call file.path

    file.close
    file.unlink
  end
end
